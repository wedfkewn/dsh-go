# iOS 后台执行源码审计

审计基线：dsh-Go `47886bdd`；Fish Pocket `a2519ebb24701cc43003ad9ae3a053520216c8a7`（工作区外只读参考）。日期：2026-11-13。本文是源码审计与最小实现记录，**不是任务续跑已完成的验收报告，未在真机验证**。

## 状态所有者与现有路径

| 层 | 源码与行为 | 后台相关边界 |
| --- | --- | --- |
| Flutter | `app/lib/app.dart` 的 `didChangeAppLifecycleState`；resumed 调 `resumeFromNative`，运行中则使本地连接失效并重新认证；其他事件经 `appLifecycle` 发给原生 | 页面状态不等于进程状态；恢复查询不能证明离屏期间任务连续执行 |
| iOS | `AppDelegate.swift` 注册 ShellBox、通知、桌宠插件；`SceneDelegate.swift` 接通知及会话深链 | 原先未管理后台授权对象；本次通过 UIKit 进程通知记录前后台，不依赖 Flutter 回调 |
| ShellBox | `ShellBoxPlugin.m` 的主线程静态状态、串行 kernelQueue、runtimeOwner、runtimeInstanceID | 状态与资源归属跨 Flutter engine 保留；不得为后台事件重建 service |
| stop | `ShellBoxSession.h`、`ShellBoxPlugin.m` 的 stop 与 markStopBlocked 路径 | 5 秒 UI 超时不代表 worker 已退出；StopBlocked 留存资源；sb_can_initialize 拒绝重复初始化；Phase B 文件读取不能保证取消及时 |
| 通道 | 现有 `dsh/shellbox`；Dart `ShellBoxRuntimeBridge` 与 `ShellBoxRuntimeService` | 原生仍是运行时状态源；现有一秒串行查询用于 UI/日志，不提供后台授权 |
| DSH | Flutter `state/sessions_state.dart`、通知/会话 reducer 与连接状态；原生管理 DSH 服务进程 | 服务 running 不等于用户任务 running；原生尚无权威任务 ID、用户发起标记、进度、任务取消确认 |
| 桌宠 | `PetLiveActivityPlugin.swift`、`Shared/PetActivityAttributes.swift`、Widget Extension、`notify/pet_live_activity.dart` | 已有 thinking/working/waitingApproval/completed/error 与会话深链；非 local-pet 内容 300 秒后 stale；ActivityKit 不提供保活授权 |
| 工程 | Runner Info.plist 无 audio 模式、无 BGTaskScheduler 标识；Runner entitlement 为 App Group | 不应在未接通任务执行链前声明后台能力 |

Runner 工程级 deployment target 为 15.0，PetLiveActivity target 为 16.2，Podfile 的设置还须在云 Mac 解析构建配置时核实。现有 `ios-check.yml` 选择 Xcode 26.0.1，使用 macos-15；不代表本次已在该 SDK 编译。它目前只允许旧 feature 分支及其目标 PR，不能直接手动运行当前未推送分支。

## Fish Pocket 机制对照

- `DshIOSApp.swift` 将 scenePhase 同时交给 BackgroundKeeper 与 LiveActivityController。active 时停止后台刷新、音频并结束 grace；inactive 时在仍处前台的窗口提交续跑，并异步刷新会话；background 时开始 UIKit grace、可选音频与十秒刷新。
- `AppModel.refreshSessions()` 调 `session/list`，合并 runningStatus 后调用 reportRunning；后者汇总 running 会话标题及 remote.attention。因此参考实现不是仅凭 Node 存活决定申请。远程 attention 不能照搬为本机 Linux 的续跑依据。
- `startContinued()` 要求 iOS 26、开关打开、非空任务、无既有对象或提交、非 halted。按 UUID 注册具体 handler，plist 允许 bundle.task.*。请求采用 `.fail`；系统拒绝后 halted，直到 idle 才清除，避免循环重提。
- handler 安装 expirationHandler，校验当前对象身份；到期清对象、置 halted、向系统报告失败，不自行停止 Linux。空任务集合完成/取消 pending request。
- `tick()` 把事件数 n 映射到 n/(n+10)，不是可量化的任务完成率，**不得移植**。未知工作量应采用明确的不确定进度，不能把刷新次数当完成进度。
- SilentAudio 配置 mixWithOthers playback，循环零值 PCM。收到 interruption ended 或 engine configuration change 后 restart；此逻辑不代表来电期间能继续执行。
- 返回 active 仅结束 grace/poll/audio；实际会话刷新仍由 AppModel 连接与 UI 路径负责，不能把前台事件当运行正常证明。

## 可借鉴与重写边界

直接借鉴设计：原生持有系统任务对象、前台提交、拒绝/到期后不自动反复重提、对象身份防旧回调、真实任务结束后完成系统任务。本文实现未复制参考代码。

必须重写：任务源（区分 local/remote、运行中/等待审批、用户发起/自动任务）、实例与任务 generation 绑定、进度、取消与 checkpoint。仅 `runtimeInstanceId` 不足以区别同实例中的下一回合；还需要任务 ID。系统取消应走 DSH 任务取消 API，并明确记录结果，不能改用 ShellBox stop。

不适用：静音音频保活、十秒轮询作为后台支撑、固定约三十秒假设、把 session list 刷新当进度、把远程 attention 当本地执行任务。

## 本次最小实现及未实现部分

复用 `ShellBoxPlugin.m` 的进程生命周期 owner，订阅 UIApplication 后台/active 通知，去重同事件与实例组合。后台设 suspendedOrUnknown；前台记录 resuming 后设 foreground。foreground 只表示可见，现有 Dart 恢复路径重新查询运行时和认证连接。记录只包含固定事件、PID、实例信息，无凭据。

新增同一通道只读方法：

- `getBackgroundExecutionState`：state、runtimeInstanceId、observedRuntimeInstanceId、runtimePhase、appPid、dshPid、authorizationActive。
- `getBackgroundCapabilities`：iOS 26 版本能力与实际 enabled 分开，返回尚缺任务/进度/取消集成原因。OSSupported 不是系统调度一定接受的承诺。

没有申请授权，不新增 timer，不改 sessionPhase、kernelQueue、service、stop 或初始化门禁。重复 Flutter 注册不重复订阅通知。observedRuntimeInstanceId 表示最近原生生命周期事件的实例，可与当前实例不同；查询不得用旧观察覆盖当前运行时。

**尚未实现**：BGContinuedProcessingTask 注册/提交/到期、UIKit 有界 checkpoint grace、任务事件桥、设置 UI、桌宠后台状态映射。不可将本次代码发布为后台续跑功能。

## 官方模型与后续最短实现

[Apple continued processing](https://developer.apple.com/documentation/backgroundtasks/bgcontinuedprocessingtask) 要求报告进度，系统可因资源压力结束授权，用户可在系统界面取消；它不是常驻服务许可。

先接通权威任务快照（runtimeInstanceId + taskId + 本地用户发起 + 状态）与 DSH 取消/完成事件。然后在前台提交单任务 `.fail` 请求，原生保有对象，回调检查实例和任务身份；拒绝保留结构化错误并降级，任务完成才报告成功；取消/expiration 保存有界元数据并请求任务级取消，不等待可能阻塞的 ShellBox stop，不标记运行时 stopped。未知量采用不确定进度，不随时间增加百分比。

[Apple UIKit 收尾](https://developer.apple.com/documentation/uikit/extending-your-app-s-background-execution-time) 仅用于确有待完成工作的短延时。先定义可有界完成的会话 checkpoint，再 beginBackgroundTask；completion 与 expiration 共同走幂等 end。不要为了获得时间创建空 checkpoint，也不要把 stop 放入收尾等待链。

后台授权结束时桌宠应变为授权结束/等待恢复，保留任务自身最后事实；恢复查询真实会话后再更新，不能延续 working 标签。现有本地宠物、Deepy/鲸娘资源和会话链接须保留。
