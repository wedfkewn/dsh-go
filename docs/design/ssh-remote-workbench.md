# SSH 远程工作台：连接能力、接口契约与实现范围

适用分支：`feat/ssh-remote`。本文按**当前代码**描述已落地的 Dart 接口与行为边界，供 UI（Pixel）、测试（Swift）与构建（Release）对齐；未实现或不支持的部分明确列出，不伪造成功。最近一次核对基于提交 `a09bf02`。

## 1. 复用与边界

- 已有 SSH 主干不重写：认证、指纹 TOFU、`RemoteDshBootstrap`、隧道、`DshClient` 登录、保活与退避保持原样。
- 远程 DSH 的会话、工作区、模型、渠道、插件继续走 active `DshClient`（原有 RPC），本契约不改变它们。
- **文件与终端不共用 DSH 链路**：`SshSessionService` 自己建立一条独立的已认证 SSH 连接（`app/lib/remote/ssh/ssh_session_service.dart`），不探测、不启动、不建隧道、不登录 DSH。因此 `dsh web` 停止时服务器文件与 SSH 终端仍可用。
- 同一条 SSH 连接内可以复用：工作台/能力探测通过 `SshHostLink`（DSH 链路）判断 `hasSftp` / `hasPty`；文件与终端页面则使用独立会话的状态层，不直接缓存 `SshTransport`。
- 写入一律经过主机身份过滤（`activeWriteConnectionProvider`，见 §13.3）：本机回落只用于展示，绝不承接远程写入。
- relay 主机与测试假传输不实现 `SshSessionHost`，页面对它们显示「服务端不支持」，不伪造成功。

## 2. 传输能力：`SshSessionHost`

文件：`app/lib/remote/ssh/ssh_session_capabilities.dart`。由 `DartSshTransport`（`app/lib/remote/ssh/ssh_transport.dart`）实现。

```dart
abstract interface class SshSessionHost {
  bool get supportsSftp;
  bool get supportsPty;
  Future<SshFileSession> openSftp();
  Future<SshPtySession> openPty([SshPtyOptions options = const SshPtyOptions()]);
}
```

- `SshPtySession`：`Stream<Uint8List> output`、`write(List<int>)`、`resize(columns, rows)`、`Future<int?> exitCode`、`Future<void> done`、`close()`。终端模拟与按键映射归调用方（复用 `xterm` 与现有 `TerminalScreen`）。
- `SshFileSession`：`list` / `stat(followLinks)` / `readRange(offset, length)` / `writeRange(offset, create, truncate, append)` / `makeDirectory` / `remove(directory)` / `rename` / `chmod(mode)` / `absolute` / `close()`。路径一律服务器绝对路径。
- 大文件由调用方按窗口读写（`readRange`/`writeRange`），接口不提供整文件 API。
- 打开方式：`SSHClient.sftp()` 与 `SSHClient.shell(pty:)`；PTY 合并 stdout/stderr。

## 3. 连接层暴露：`SshHostLink`

文件：`app/lib/remote/ssh/ssh_link.dart`。**工作台、归属与错误提示**使用它；文件/终端页面不直接用它开会话（见 §12）。

```dart
SshDshOwnership? get ownership;      // null 未连接
bool get hasSftp;                     // 当前连接能否 SFTP
bool get hasPty;                      // 当前连接能否 PTY
Stream<SshTransport> get transports;  // 每次新 SSH 连接（含重连）
Future<T> withTransport<T>(Future<T> Function(SshTransport), {Duration wait = 30s});
Future<List<RemoteDshInstance>> discoverDsh({Duration timeout = 20s});
Future<SshFileSession> openSftpSession({Duration wait = 30s});
Future<SshPtySession> openPtySession({SshPtyOptions options, Duration wait = 30s});
Future<void> stopManaged();           // 仅 Managed
bool get stoppedByUser;
```

- 能力判断以 `hasSftp`/`hasPty` 为准，不要自行 `is` 判断；不支持时 `openSftpSession`/`openPtySession` 抛 `StateError`。
- `transports` 在每次认证成功（含重连替换）时发一条新传输；旧会话随旧传输失效，**不自动重开**。
- `withTransport` 在断线期间等待重连（默认 30s 上限），超时抛 `TimeoutException`；`link` 已关闭时抛 `StateError`。
- 保活判死或主动停机会 `_teardownTransport`，正在进行的 SFTP/PTY 通道随之失效；页面进入「连接已断开，请重试」，只有用户显式重试才继续。

## 4. Attach 语义

- `SshHostConfig.attachHost`（默认 `127.0.0.1`），表示 SSH 服务器侧访问既有 DSH 的地址；`RemoteDshEndpoint.host` 决定隧道目标与登录 `Host` 头（`authority`），因此容器或同网第二台机器上的实例也可接管。
- 目标地址校验：`SshHostConfig.isDialableHost`；非法地址进 `SshAttachProblem.target`。
- 工作目录：Attach 下必须是绝对路径（`/` 开头）。原因：Attach 不执行任何远端命令，拿不到 `$HOME`，`~/…` 会原样下发；引擎是否展开未经验证，因此不依赖。违规返回 `SshAttachProblem.relativeWorkingDirectory`，文案用 `remoteErrAbsolutePath`。
- 其他 Attach 问题统一由 `SshHostConfig.attachProblem({required bool hasToken})` 判定，UI 与 link 共用一个决策函数。
- Attach 连接依旧零远端命令、零状态写入、零启停；`restartManaged()`、`stopManaged()` 对 Attach 抛 `StateError`。
- `attachHost` 纳入 `connectionKey`：改目标地址需重建 SSH 会话；旧配置 JSON 没有该字段时回落到 `127.0.0.1`，向后兼容。

## 5. 实例发现

文件：`app/lib/remote/ssh/dsh_discovery.dart`。

```dart
Future<List<RemoteDshInstance>> discoverDshInstances(RemoteShell shell, {Duration timeout = 20s});
class RemoteDshInstance { int pid; String command; List<int> ports; bool managed; String? token; bool get attachable; }
```

- **用户显式触发**：不进首连、不在后台轮询；UI 用按钮调用 `link.discoverDsh()`。
- 只跑一个只读脚本：读 `/proc/<pid>/cmdline` 与 `/proc/<pid>/fd` 的 socket inode，匹配 `/proc/net/tcp{,6}` 的 LISTEN 端口；只覆盖当前 SSH 用户自己的进程，读不到就跳过。
- 脚本只报事实：端口文件只写端口，不混入 PID；`managed` 由 Dart 侧判定（pid 与 `web.st` 启动时间同时匹配）。
- 缺少 `web.st` 或启动时间不符：保守标为归属未知、`token == null`，不凭 PID 认领实例。
- 不读其他进程的 environ/内存/文件；不停止、不重启、不改任何状态。
- 扫描输出不写日志、不进诊断包（含 token 的行由解析器消费，不保留）。

## 6. Managed 停止

- `stopManaged()`：仅 Managed 且已连接可调用；停止 `web.pid` 记录的实例，把 link 置为 `failed` + 非重试错误（`remoteErrDshStopped`），并设置 `stoppedByUser`。
- `stoppedByUser == true` 时：`open()` 立即返回同一错误，`kick()`（网络变化）不再触发重连，`_recover` 退出，因此**自动重连不会再次拉起实例**。
- 只有 `retry()`（用户点重试/重新连接）或 `restartManaged()`（用户确认重启）会清除 `stoppedByUser`。
- `RemoteConnectionController.retry()` 把 `failed`/`reconnecting` 交给 `link.retry()`，否则无法清除停止标记。
- 归属标识：`SshDshOwnership { attached, managedStarted, managedReused }`。UI 文案：Attach →「只连接 · 你的实例」，Managed →「托管 · App 启动 / 复用已有」。

## 7. Remote Only

- 编译期标志：`app/lib/build_variant.dart` 的 `remoteOnlyBuild`（`--dart-define=DSH_REMOTE_ONLY=true`，由 Release 的打包脚本传入）。
- `LocalRuntimeState.available` 在 Remote Only 构建下为 `false`：首启「本机」不可选，直接落到远程主机；Full 构建行为不变（不靠版本字段推断）。
- 入口：设置页「引擎」入口与概览卡引擎行在 Remote Only 下隐藏；`home_shell._openDestination` 统一拦截 `DrawerDestination.engine`（抽屉、快捷面板、身份栏、安全模式横幅四条路径），提示「这个版本不含本机引擎，请连接远程主机」而不是打开空页面。
- 手机侧能力（手机操控、通知、个人化等）不依赖本机引擎，保持可见。
- 不使用 `runtimeMissing` 作为构建变体判断；它只表示「包内有运行时但未安装」。

## 8. 已实现范围与明确不提供

已实现（详见 §12、§13）：

- 服务器文件：浏览/隐藏文件/面包屑/目录优先；新建、重命名、删除、改权限（均二次确认、显示绝对路径）；上传（文件流分块）、下载（临时目录 + 系统分享）、进度与取消、失败显式重试；文本预览编辑（2 MiB 上限）、图片预览（16 MiB 上限）、PDF 原生逐页渲染；语法高亮；搜索（当前目录树、可停止、不穿符号链接目录）；收藏目录（按主机持久化）；复制/移动（必确认、目标等于源拒绝、目录不复制）；批量复制/移动/删除；目录加入工作区、文件加入对话附件（64 MiB 上限）。
- SSH 终端：多标签、每标签独立 resize、Ctrl/Alt/Esc/Tab/方向键软键、从文件页以当前目录打开；断线标签 `ended`，不自动重开。
- 主机信息：`host_info_page.dart` + `host_facts.dart`，一次只读探测（uname、核数、内存、负载、运行时长、磁盘 `/`），不启动、不改动服务器；页面 watch 会话，离开即断开。

明确不提供（保留在缺口清单，不随阶段通过消失）：

- 递归复制/删除目录；批量下载到手机（多选分享）。
- HEIC 预览；全盘搜索（搜索范围限当前目录树）。
- SFTP 不展开 `~`（一律绝对路径）；取消上传会留下部分文件。
- 终端不保活远端进程（channel 关闭即结束），与真实 SSH 行为一致。
- relay 不允许安装/卸载插件（只能开关）；HarmonyOS 主机拒绝市场安装；本机 safe mode 禁止安装。
- 插件安装历史只在内存：重启 App 或切主机后看不到旧作业，安装日志只保留尾部 16 KiB。

## 9. 测试挂点

- `app/test/remote/ssh_attach_control_test.dart`、`remote_ui_p0_test.dart`：`attachProblem` 各类问题、Attach 连接零远端命令、`attachHost` 持久化与回调。
- `app/test/remote/dsh_discovery_test.dart`：发现脚本真实运行（端口只来自 LISTEN、`web.st` 缺失/时间不符不认领、匹配时取自有 token）。
- `app/test/remote/ssh_managed_stop_test.dart`：停止后 `open()` 报错、`kick()` 不重连、`retry()` 才恢复。
- `app/test/remote/ssh_file_terminal_state_test.dart`：SFTP 列目录/流式下载、取消终态、空文件创建与覆盖、最后一块期间取消、上传分块、复制/移动/搜索/重试、PTY 打开失败与拒绝分类、断线不重连不重放。
- `app/test/remote/{server_files_ui,ssh_terminal_ui,server_files_page...,sftp_edge_cases,sftp_temp_dir,sftp_favorites}_test.dart`：页面级文件/终端行为、主机切换与同名并发下载、临时路径隔离。
- `app/test/remote/{remote_target_isolation,plugin_install_reconnect,engine_settings_host_isolation}_test.dart`、`app/test/plugins/*`：写入目标隔离、安装作业跨重连保留、设置不落到本机。
- `tooling/ios/tests/ssh-live/with-sshd.sh` + `app/test/remote/live_sftp_pty_test.dart`：真实 sshd 的 SFTP/PTY 互通与断线行为；PTY 能力探测导出 `DSH_APP_LIVE_SSHD_PTY`，CI 用 `DSH_APP_LIVE_SSHD_REQUIRE_PTY=1` 强制要求可分配。

## 10. 验证记录（截至 `a09bf02`）

- 本机 `flutter analyze --no-pub`：`No issues found!`。
- 状态层与页面用例：SFTP/终端/工作台/隔离相关组合多次实跑通过（最近 `ssh_file_terminal_state_test` 12/12；`server_files_ui` 20/20；P2 文件组合 67 项）。
- 本机真实 sshd：`live_sftp_pty_test.dart` → `+6 ~2 All tests passed!`（SFTP 6 项真跑、未启动 DSH；PTY 2 条按能力探测 skip）。
- **本机 PTY 无法分配**：本机 `/dev/pts` 为只读挂载，非 root sshd 在 `chown(/dev/pts/0, 1000, 5)` 失败后自行关闭连接；不是 dartssh2 通道销毁缺陷（该判断已撤回）。因此「真实 PTY 交互」只能由 CI 的 `ubuntu-24.04` runner 验证。
- CI `ssh-live` job 在 `a09bf02` 上 success（PTY 严格门禁与跳过拦截都在步骤内）；精确 `+N ~M` 统计行以 artifact `ssh-live-log` 为准。
- 未在真机验证：文件选择器/分享面板、PDF 原生渲染手感、通知与后台、签名安装。这些需要真机结果，未签名编译与 runner 结果不能替代。

## 11. P1 远程管理链路核对（会话 / 工作区 / 模型）

核对方式：读调用链 + 现有测试实跑；不改代码即满足「操作落到真实远程主机」。

| 操作 | 入口 | 通道 | 目标 |
|---|---|---|---|
| 会话列表 / 新建 / 继续 / 重命名 / 归档 / 搜索 / fork | `sessions_state`、`chat_state` | `session/list`、`session/create`、`session/rename`、`workspace/archiveSession`、`session/search`、`session/fork`、`session/follow`（mux） | active host 的 `DshClient` |
| 永久删除会话 | 抽屉删除流程 | `GET /dsh-go/v1/sessions/deletion` 能力探测 + `POST /dsh-go/v1/sessions/delete` | 仅装了 dsh-go bridge 的 Host；stock `dsh web` 返回 unsupported，UI 明示「不支持永久删除」，**不回退成归档** |
| 工作区登记：列出/新增/切换/重命名/移除/排序/置顶 | `workspaces_state`、`workspace_actions` | `workspace/follow`、`workspace/create`、`workspace/rename`、`workspace/delete`、`workspace/insertBefore`、`workspace/pinSession` | active host；`workspace/delete` 只移除登记（RPC 语义 + UI 文案「移除工作区」），不动目录与对话 |
| 工作区目录选择 / 新建文件夹 | `directory_picker` | `directoryPicker/list`、`directoryPicker/createDirectory` | active host 自己的磁盘 |
| 模型目录 / 会话内切换 / 默认模型 | `models_state`、`model_defaults_state` | `session/modelCatalog`、`session/selectModel`（含下一会话默认保存） | active host |
| 模型渠道 CRUD / 覆盖参数 / 测试连接 | `providers_state`、`provider_backend` | `settings/describe`、`settings/mutate`（pi-ai 命名空间）、`llm/listConfigurableProviders` | active host |
| 渠道 API Key | 渠道表单 | `credentials/set`（`setProviderKey`） | active host 的凭据库；手机侧 vault 仅在 `backend.isLocal` 时写，远程 key 不落手机 |
| 自动发现模型 | 渠道表单 | `llm/discoverModels` 走 active host | active host 出网请求 |

手机侧只保留与主机无关的东西：主机配置、按 host 分键的工作区偏好（`workspaces.<kind>.<id>`）、本机自愈用的 provider key vault（只在本机写）。已核实 `localConnectionProvider` 的其余调用点都是手机本地功能（手机操控、语音、通知、诊断、账号），远程主机上被显式挡住。

状态恢复（断线 / 换 client）：

- `readListLiveConnectionProvider` 在 mux `reconnecting` / `unauthorized` / `closed` 时返回 null，列表与渠道降级为「离线」，恢复后由 provider 重建重新拉取；不保留半截快照。
- 写入用 `activeWriteConnectionProvider`：按 `kind` + `hostId` 过滤，选中主机缺失/未加载时返回 null，而不是本机的回落连接；它保留重连中的 client，恢复后同一 client 继续。
- mux 同一 client 内重连时，`session/follow`、`workspace/follow`、终端等流由 client 的 `_resilient` 重开；`chat_state` 以 `mux.generation` 校验事件代次，旧代事件不落地。
- Managed 重启等导致 **client 被替换**时，`activeConnectionProvider` 发布新 client，会话/工作区/模型/渠道 provider 全部重建；换主机或换连接会让永久删除的授权 owner 立即失效（`SessionDeletionOwner`）。
- 目标主机隔离：列表缓存按 `ReadListIdentity`（含 host 与运行时根）区分，切主机不串数据；`WorkspacePrefs` 按 `HostRef` 分键。

## 12. 服务器文件与 SSH 终端（独立于 DSH）

新模块：

- `SshSessionService`（`app/lib/remote/ssh/ssh_session_service.dart`）：只做 SSH 认证与指纹固定——不探测 DSH、不启动、不建隧道、不登录 DSH。首次使用打开，15s ping，连续 2 次失败判死并广播 `lost`；`acquire / reconnect / openFiles / openPty / close`。**不自动重连**。
- `sshSessionServiceProvider`（`app/lib/state/ssh_session_state.dart`）：按主机共享，页面 watch 持有，最后一个文件/终端/信息页面关闭即断开。
- `SftpController` + `sftpProvider(HostRef)`（`app/lib/state/sftp_state.dart`）：
  - 浏览：`connect(path)` / `open` / `refresh` / `up` / `listDir(path)`（只列不移动当前目录）
  - 操作：`createDirectory` / `rename` / `remove(directory:)` / `chmod` / `copy({from,to})` / `move({from,to})`
  - 编辑与预览：`readText`（2 MiB 上限）/ `writeText` / `readBytes(path,{maxBytes:8 MiB})`
  - 搜索：`search(query,{root,includeHidden,maxResults:200,maxDirectories:500})` / `cancelSearch()` / `clearSearch()`；BFS，不进入符号链接目录，单目录读失败跳过
  - 传输：`download(remotePath, localPath)` / `upload(localPath, remoteDir)` / `cancel(id)`（仅运行中）/ `retryTransfer(id)`（同一 transfer id）/ `clearFinished()`
  - 状态：`SftpState{phase, path, entries, failure, transfers, busy, searchResults, searching}`；`SftpFailureKind` 不带文案，由 UI 本地化；`SSHStateError` 归 `connectionLost`。
- `SshTerminalsController` + `sshTerminalsProvider(HostRef)`（`app/lib/state/ssh_terminal_state.dart`）：
  - `openTab({title, columns, rows})` / `write(id, data)` / `resize(id, columns, rows)` / `closeTab` / `setActive` / `reconnect` / `outputOf(id)`
  - 状态：`SshTerminalsState{tabs, activeId, failure}`，`SshTerminalTab{id, status, title, exitCode, failure}`
  - 失败分类：`SSHChannelRequestError` → `ptyRefused`；`SSHStateError` / 连接丢失 → `connectionLost`；打开失败只影响该标签，页面仍可开新标签。

语义与边界：

- **DSH 无关**：既不走 `hostLink` 的隧道，也不要求 `dsh web` 在跑；Attach/Managed 都能用，DSH 停止后 SFTP 与终端照常。
- **流式与大文件**：256 KiB 窗口读写，大文件不进内存；下载直接写手机文件，上传按本地文件 `openRead()` 分块。空文件上传也会创建/截断远端文件。
- **取消**：在块之间生效，已写/已读部分保留；终态 `cancelled`——包括「最后一块传输期间取消」，不会被收尾改写成 `done`。
- **断线**：SFTP 置 `failed(connectionLost)`、终端标签置 `ended(connectionLost)`；**不自动重连、不重放写入或命令**，只有用户显式 `retry()` / `reconnect()` / 新开标签才继续。
- **终端首屏**：页面订阅前的输出会缓冲，banner/prompt 不丢。
- **危险操作**：删除、覆盖、`chmod`、复制/移动都必须由 UI 二次确认；本层只执行明确调用，不提供递归删除，不获取 root。
- **复制/移动边界**：`copy` 不递归、不进入符号链接目录，传目录抛 `unsupported`；`move` 是服务端 rename，移动链接本身；符号链接文件复制的是目标内容（SFTP 无服务端 copy/link 原语）。

## 13. 多主机、重连与插件

### 13.1 每台主机独立

- 文件/终端状态按 `HostRef` family 区分，两台主机不共享会话、目录、传输列表或标签。
- 插件：`pluginHostProvider` 读 `readListLiveConnectionProvider`（按 kind + hostId 过滤，mux 断开时返回 null），清单/开关/安装都落在该主机的 `DshClient`；市场索引由 App 自己读，与主机无关。

### 13.2 重连行为

- 链路抖动：同一 `DshClient` 内部重连，DSH 实例不重启；插件安装卡片跨一次链路瞬断保留（作业表 `_jobs` 只在换成另一个 client 时清空），未发送的步骤按 generation 取消、不重放。
- 已发送的安装请求在 Host 上继续运行，链路恢复后卡片与结果回来；`waitForInstall` 用于响应丢失后的结果恢复。
- 文件/终端不自动恢复：终端标签直接 `ended`，文件页 `failed` + 「连接已断开，请重试」；用户显式重试才新开连接。

### 13.3 主机身份过滤

- 所有远程写入（会话、工作区、插件配置、引擎设置、插件清单）都经过 `activeWriteConnectionProvider`；`activeConnectionProvider` 的本机回落只用于展示。
- 引擎设置页、插件配置桥、插件清单在「选中的 SSH 主机未加载」窗口下按未连接处理，不读写本机；回归见 `app/test/plugins/engine_settings_host_isolation_test.dart`。

### 13.4 插件能力矩阵（按真实接口）

| 能力 | 本机 | SSH 隧道 | 中转 relay | HarmonyOS 本机 |
|---|---|---|---|---|
| 清单 / 开关 | ✓ | ✓ | ✓ | ✓ |
| 安装 / 卸载 / 更新 | ✓（safe mode 除外） | ✓ | ✗（allow-list，界面给 `dsh plugin --profile web add`） | ✗（`installRefused`） |
| 安装进度 / 取消 / 结果恢复 | ✓ | ✓ | ✗ | ✗ |
| 插件配置（bridge） | ✓ | ✓（`canReachDshGo`） | 回落到 engine settings 字段 | 视 bridge 能力 |
| 引擎重启 / 运行日志 | ✓ | ✗（本机专属） | ✗ | ✓ |

## 14. 已知限制汇总

- 真实 PTY 交互：本机不可验证（`/dev/pts` 只读），依赖 CI `ssh-live` 的 runner 结果；界面手感仍需真机。
- 文件能力缺口：递归复制/删除、批量下载、HEIC、全盘搜索、真机文件选择器/分享面板、PDF 原生渲染手感。
- 插件：无安装历史；日志仅尾部 16 KiB；relay 只允许开关。
- 远程 DSH 的 `~` 展开：不依赖、不实现；Attach 要求绝对路径。
