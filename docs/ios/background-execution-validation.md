# 后台执行验证与已知限制

2026-11-13：**未在真机验证**。本次仅实现原生生命周期观测及只读能力接口，不具备任务续跑功能。没有云 Mac 编译日志、IPA 或实机测试结果；不得据本文宣称完成后台适配。

环境：Linux；PATH 未提供 flutter、dart、swift、xcodebuild。尚无可用 iPhone 连接信息及既有云 Mac 连接入口。现有 GitHub Actions 需已推送 ref，且 ios-check workflow 限定旧分支；遵照未验证不提交/推送约束，本次未触发构建。Android 构建未运行，Android 源码未改。

## 真机矩阵（全部未运行）

| 场景 | 必须确认 |
| --- | --- |
| 前台 DSH 任务 | 模型/工具输出和真实完成事件 |
| 后台 30 秒、2 分钟、10 分钟 | 时间仅为观测点，不能作为后台保证 |
| 锁屏、DeepSeek API 请求 | 实际结果与系统授权状态分别记录 |
| 后台文件读、写 | 结果完整性；读阻塞不能触发资源释放 |
| 网络切换、来电 | 重连、音频中断影响、任务是否重复执行 |
| 回前台、快速切换 | 原生查询与连接恢复幂等，无重复实例 |
| 系统拒绝、expiration | 授权失败不改为 stopped，无自动无限重提 |
| 启动中、工具中、StopBlocked 时切后台 | 同实例资源保持，禁止重复初始化 |
| 授权到期但 Linux 线程仍运行 | 无取消线程、free、destroy 或等待 stop |
| 系统挂起/终止后重开 | 不把旧实例状态当新进程任务，不自动重放用户操作 |
| iOS 26+ continued processing | 实际注册、提交、系统取消、真实进度/不确定进度，当前尚未实现 |

每次记录 iOS 版本、设备型号、App PID、runtimeInstanceId、DSH PID、taskId、时间、原生/Flutter 生命周期、授权状态、expiration 时间、完成结果、内存/CPU/异常日志。不得保存 API key、cookie 或完整会话内容；对外发日志先人工检查。模拟器不能替代本表真机结论。

已知限制：系统授权、App 进程、ShellBox、DSH 会话、Flutter 页面五类状态仍需分别验证。本次 suspendedOrUnknown 不推断已挂起或已停止；authorizationActive 恒 false。没有 checkpoint 可保证 guest 内存任务在进程终止后恢复。现有 ActivityKit stale 时间不是授权到期同步，后续仍需接入。

## 本机检查记录

- `git diff --check`：通过。
- `python3 runtime/shellbox/tests/lifecycle-probes.py`：未执行到探针，入口要求 ShellBox upstream checkout 参数，缺参产生 IndexError；不计为通过。这组探针验证底层补丁，不能验证 UIKit 新增代码。
- Flutter analyze/test、iOS 无签名编译、Android 构建：未运行，当前 PATH 缺工具链。
- 未提交、未推送、未触发云构建；工作分支 feature/ios-background-execution。

变更清单：ShellBoxPlugin.m 的原生只读观测与通道分发；shellbox_runtime_bridge.dart 的查询适配；background-execution-audit.md、silent-audio-evaluation.md 与本文。没有改 ShellBox 内核、运行时补丁、Node、Android 或桌宠资源。

## 第二轮实现记录（2026-11-13，未在真机验证）

以上第一轮记录保留作历史基线；以下描述当前工作树。分支仍为
`feature/ios-background-execution`，未切分支、未提交、未推送。已 fetch origin/main，
保留第一轮的未提交内容。没有访问云 Mac、没有 SSH，也没有修改静音音频报告。

### 当前已写入源码的路径（不等于验收通过）

- 在现有 `ShellBoxPlugin.m` 内扩展进程生命周期管理，原生拥有授权对象、请求标识、
  实例/会话/回合身份、错误原因及有界 checkpoint。复用 `dsh/shellbox`，不新增通道。
  原生 UIApplication 通知驱动 foreground/resuming/backgroundGrace/
  continuedProcessing/suspendedOrUnknown/expired/failed 状态，完成与异常单独记录。
  foreground 仅表示 App 可见；恢复时重新查询原生 status，并沿用原有 Flutter 重新认证与会话同步。
- iOS 26+ 为每个实际任务生成独立请求标识，动态注册 handler，使用 `.fail` 策略提交。
  Info.plist 声明 bundle 下的 `dsh.continued.*`，工程链接 BackgroundTasks.framework。
  动态注册遵循 [Apple WWDC25/227](https://developer.apple.com/videos/play/wwdc2025/227/)
  对 continued processing 的说明，区别于普通后台刷新必须在启动完成前注册的要求。
  handler 捕获原任务身份，旧请求启动/到期回调不能接管新请求。
- Flutter 显式用户发送入口标记 userInitiated；自动调用默认 false。只有本地会话中
  本次发送 requestId 的真实 human echo 和 turn/start 对应的回合才发布任务。
  身份为 runtimeInstanceId + sessionId + turn/start 序号，不以 Node/服务存活作为任务依据。
  完成、异常、审批及断线未知状态来自既有 transcript/reducer，不新增后台轮询。
- 同一实例中的同一回合最多申请一次，生命周期、网络恢复、设置切换均不清除尝试记录。
  系统拒绝返回稳定原因代码并进入 failed；系统决定何时授予、拒绝或提前结束执行时间。
  未知工作量使用 NSProgress 不确定进度和明确字幕，不按时间、token、事件数量生成百分比。
  仅收到真实完成状态时向系统报告成功；需要 Mac/真机确认系统对不确定进度的实际展示与到期策略。
- 系统取消与 expiration 共用幂等结束路径，先结束授权、保存元数据，再经现有通道请求
  DSH `session/cancel`，校验当前连接、实例、会话和回合。取消 RPC 有 3 秒确认上限，
  原生记录 cancellation_requested 或 cancellation_unconfirmed；accepted 不等于回合已经结束。
  没有调用 ShellBox stop、取消 Linux 线程或释放 guest 资源。
- UIKit beginBackgroundTask 只用于确有脏恢复元数据时的短时写入；expiration、完成与
  3 秒应用层写入截止时间共同幂等 end。3 秒是本实现的持有上限，不是 iOS 授予时间。
  文件写入在独立串行队列，不在 kernelQueue 或主线程等待。保存的只有实例/会话/回合 ID、
  授权状态和时间，不含标题、提示词、凭据、运行时 URL 或 guest 内存。
- `Application Support/dsh-background-recovery.plist` 在下一次启动读取，只提供
  recoveryAvailable 提示，绝不作为当前活动任务或自动重放依据。
  已终止 Linux 内存任务没有 checkpoint/restore 支持；会话持久日志仍由既有 DSH 路径负责。
- 设置的原 iOS 后台入口改为 iOS 专用页：续跑开关、版本支持原因、自动短时收尾说明、
  当前状态、手动刷新、结束续跑与远程模式建议。不承诺永久后台服务。设置存原生 defaults，
  页面销毁不结束授权。中英文 ARB 输入及原生 Localizable.strings 同步。
- ActivityKit 原生订阅后台状态，覆盖续跑、审批、授权结束、完成、异常及等待恢复。
  仅更新相同本地会话活动，保持 packId 与会话深链；Deepy/鲸娘资源未改。
  内容相同不更新，不使用 ActivityKit 保活。前台恢复先显示等待恢复，真实会话刷新后才显示运行。
- 在已有 sb_can_initialize 和 service 门禁通过之后，为新启动分配新 runtimeInstanceId，
  清理旧后台授权 bookkeeping；没有更改 stop 超时、StopBlocked、底层 I/O 或资源所有权逻辑。
  启动中的切后台没有运行回合，不申请 continued processing；StopBlocked 不被当作可启动状态。

### 限制与协调者必须复核的部分

1. **Flutter 分析、Flutter 测试、flutter gen-l10n、云 Mac 编译、Xcode 编译均未在本轮运行；
   未在真机验证。** Linux 无这些工具链，不应据源码宣称功能已经修复或可以发布。
   先在 Mac 运行 `python3 app/tool/l10n_merge.py` 完成 Dart 本地化生成，再 analyze/test 与构建。
2. 当前原生实现一次管理一个本地用户回合；已有授权时另一个会话返回 background_task_busy。
   不把并发会话打包成伪造进度，也不自动轮换申请。
3. 系统 expiration 没有可靠区分“用户点击停止”和“资源压力结束”的原因，均采取任务级取消请求。
   Dart isolate 若来不及收到通道消息，取消无法确认；不能保证原生 expiration 之后 guest 立即停工。
   未实现原生直连 DSH 的独立取消客户端。
4. 现有 `session/cancel` 是会话级 RPC，没有服务端 expectedTurn 条件参数。
   Flutter 在发送前核验当前回合，不能消除“核验后回合结束、RPC 到达时下一回合已开始”的竞态。
   这一限制需要后续引擎契约支持和真机并发测试，不能把本实现描述为原子回合取消。
5. 会话断线时不继续宣称已确认执行；返回前台仍需既有连接和会话同步。
   不确定进度可能较早被系统结束授权；没有用虚假进度或重复提交维持时间。
6. 元数据写入失败或超过截止时间会记录原因，结束 UIKit grant；不停止可能仍阻塞的写入 worker。
   不存在 App 终止后自动续跑/自动重新提交。该元数据不是完整会话备份。
7. 本文上方真机矩阵全部仍待验证，包括模型请求、工具、文件 I/O、StopBlocked、授权到期仍有
   Linux 线程、网络恢复、来电、快速切换和系统终止重启。系统取消、注册、progress 显示、
   Widget 本地化/资源编译、页面反复重建及多会话限制应一并实测。

### 本轮实际执行的检查

- `git diff --check`：通过。
- `python3 app/tool/l10n_merge.py`：完成 ARB 合并后因缺 Flutter 退出 1；**不是生成全链路通过**。
- `python3 app/tool/l10n_merge.py --no-gen`：通过（74 parts，7360 keys）；仅生成合并 ARB。
- `python3 app/tool/l10n_merge.py --check`：通过（74 parts，7360 keys）。
- Python plistlib 解析 Info.plist 并核对 continued 标识、processing 模式及无 audio 模式：通过。
- `python3 runtime/shellbox/tests/lifecycle-probes.py /data/workspace/shellbox-validation`：退出 0。
  既有 Linux 组件探针通过，包含 stop 超时进入 StopBlocked、拒绝重初始化/重置、确认停止后复用。
  输出中的 CONFIRMED LIMITATION / TRIAL REJECTED 是探针对既有阻塞 I/O 限制的确认，
  不是后台 API 验证，也不表示已修复阻塞 read。
- 新增 `app/test/runtime/shellbox_background_bridge_test.dart`，覆盖旧回合取消隔离、原生 expired
  事件不调用 stop、拒绝原因透传；**未运行**，留给 Mac Flutter 环境执行。
- 未运行 Android 构建；Android 原生代码与运行时补丁未改，新增发送标记的后台路径由 Platform.isIOS 隔离。


## 第三轮编译与分析错误修正（2026-11-13，未在真机验证）

依据协调者提供的云 Mac 失败记录，仅修正以下六处源码问题，未调整后台功能：

- `ShellBoxPlugin.m` 的 `backgroundGrace` 改为无显式初始化的静态声明，
  在首次创建进程生命周期 owner 时、任何后台状态使用之前赋为 `UIBackgroundTaskInvalid`；
  避免文件作用域初始化使用非常量表达式，保留初始无效标识语义。
- 初始 App 状态读取改用 Objective-C 的 `[UIApplication sharedApplication].applicationState`。
- `FakeChatController.send` 与 `_Chat.send` 均补齐 `bool userInitiated = false`，
  与 `ChatController.send` 一致，仅对齐签名，未改测试逻辑。
- `chat_state.dart` 的过期排队任务判断和 `ios_background_page.dart` 的刷新 mounted 判断
  补齐大括号，未改条件或执行逻辑。

本轮验证：`git diff --check` 通过。服务器没有 Flutter/Xcode 工具链，
Flutter 分析、Flutter 测试和云 Mac/Xcode 编译均未在本轮运行，需协调者在 Mac 重跑。
**未在真机验证**，第二轮真机矩阵及功能限制仍然有效；本次源码修正不代表后台功能已通过实测。
未修改 Mac 本地的 `integration_test/pet_island_drive_test.dart`，未切换分支、未提交、未推送。
