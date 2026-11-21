# SSH 远程工作台：连接能力与接口契约（P0）

适用分支：`feat/ssh-remote`。本文只描述本阶段实际落地的 Dart 接口与行为边界，供 UI（Pixel）与测试（Swift）对齐签名；未实现的部分明确标注「不提供」。

## 1. 复用与边界

- 已有 SSH 主干不重写：认证、指纹 TOFU、`RemoteDshBootstrap`、隧道、`DshClient` 登录、保活与退避保持原样。
- 新能力只通过**同一条** SSH 连接提供，不另开第二条连接：`SshSessionHost`。
- relay 主机与测试假传输不实现 `SshSessionHost`，因此页面对它们显示「服务端不支持」，不伪造成功。
- 远程 DSH 的会话、工作区、模型、插件继续走 active `DshClient`（原有 RPC），本契约不改变它们。

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

文件：`app/lib/remote/ssh/ssh_link.dart`。

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

页面优先用 `openSftpSession` / `openPtySession`，不要在 UI 里做类型转换；不支持时它们抛 `StateError`。

- `transports` 在每次认证成功（含重连替换）时发一条新传输；页面据此**重开** SFTP/PTY，旧会话已随旧传输关闭。
- `withTransport` 在断线期间等待重连（默认 30s 上限），超时抛 `TimeoutException`；`link` 已关闭时抛 `StateError`。SFTP/PTY 页不要缓存 `SshTransport`，用 `transports` 重绑。
- 能力判断以 `hasSftp`/`hasPty` 为准，不要自行 `is` 判断。
- 保活判死或主动停机会 `_teardownTransport`，正在进行的 SFTP/PTY 通道随之失效，页面需回到「重连中」状态。

## 4. Attach 语义

- 新增 `SshHostConfig.attachHost`（默认 `127.0.0.1`），表示 SSH 服务器侧访问既有 DSH 的地址；`RemoteDshEndpoint.host` 决定隧道目标与登录 `Host` 头（`authority`），因此容器或同网第二台机器上的实例也可接管。
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
- 不读其他进程的 environ/内存/文件；不停止、不重启、不改任何状态。
- `token` 只对 `managed == true` 且来自本 App 自己的 `~/.dsh-app-remote/web.log` 时填写；其他实例 `token == null`，用户自己粘贴。
- 扫描输出不写日志、不进诊断包（含 token 的行由解析器消费，不保留）。

## 6. Managed 停止

- `stopManaged()`：仅 Managed 且已连接可调用；停止 `web.pid` 记录的实例，把 link 置为 `failed` + 非重试错误（`remoteErrDshStopped`），并设置 `stoppedByUser`。
- `stoppedByUser == true` 时：`open()` 立即返回同一错误，`kick()`（网络变化）不再触发重连，`_recover` 退出，因此**自动重连不会再次拉起实例**。
- 只有 `retry()`（用户点重试/重新连接）或 `restartManaged()`（用户确认重启）会清除 `stoppedByUser`。
- `RemoteConnectionController.retry()` 改为把 `failed`/`reconnecting` 交给 `link.retry()`，否则无法清除停止标记。
- 归属标识：`SshDshOwnership { attached, managedStarted, managedReused }`。UI 文案：Attach →「只连接 · 你的实例」，Managed →「托管 · App 启动」。

## 7. Remote Only

- 编译期标志：`app/lib/build_variant.dart` 的 `remoteOnlyBuild`（`--dart-define=DSH_REMOTE_ONLY=true`，由 Release 的打包脚本传入）。
- `LocalRuntimeState.available` 在 Remote Only 构建下为 `false`：首启「本机」不可选，直接落到远程主机；Full 构建行为不变（不靠版本字段推断）。
- 不使用 `runtimeMissing` 作为构建变体判断；它只表示「包内有运行时但未安装」。

## 8. 本阶段不提供

- 主机信息（uname/磁盘/内存/DSH 版本）：未实现，`remoteWorkbenchSoonHostInfo` 保持提示文案。
- 传输中心（进度/取消/重试/冲突确认）：SFTP 只提供分块接口，传输调度待 P2。
- SFTP 目录树/收藏/语法高亮：UI 后续实现，接口已够用。
- 远程 DSH 的 `~` 展开：不依赖、不实现。

## 9. 测试挂点（Swift）

- `attachProblem` 四类问题各一条；Attach 连接仍 `scripts.isEmpty`。
- `attachHost` 非回环时隧道目标与 `Host` 头一致；旧 JSON 回落。
- `stopManaged` 后：`open()` 报错、`kick()` 不重连、`retry()` 才恢复。
- `discoverDshInstances`：解析畸形输出不进结果；非 managed 实例无 token；managed 实例从自有日志取 token。
- `SshSessionHost` 只在 `DartSshTransport` 上为真；relay/假传输 `hasSftp == false`。

## 10. 未验证项

- 本机无 Flutter/Dart（Linux），`flutter analyze`/`flutter test` 未运行；本文件列出的签名尚未编译验证。
- Pixel 新增的 l10n key（`remoteErrAbsolutePath` 等）尚未 `flutter gen-l10n`；生成前引用这些 key 的代码无法编译，属预期中间态。
- 服务端 `dsh web` 是否自行展开 `~`：引擎源码不在仓库，静态不可判定；因此本阶段取「Attach 必须绝对路径」。

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
- mux 同一 client 内重连时，`session/follow`、`workspace/follow`、终端等流由 client 的 `_resilient` 重开；`chat_state` 以 `mux.generation` 校验事件代次，旧代事件不落地。
- Managed 重启等导致 **client 被替换**时，`activeConnectionProvider` 发布新 client，会话/工作区/模型/渠道 provider 全部重建；换主机或换连接会让永久删除的授权 owner 立即失效（`SessionDeletionOwner`）。
- 目标主机隔离：列表缓存按 `ReadListIdentity`（含 host 与运行时根）区分，切主机不串数据；`WorkspacePrefs` 按 `HostRef` 分键。

已知限制（P1 范围内，不伪造）：

- 远程 Host 若跑 stock `dsh web`（无 dsh-go bridge）：永久删除会话、插件配置编辑、客户端清单、伴侣等 bridge 专属能力不可用，UI 走「不支持」文案；插件管理属 P3，届时按同一规则处理。

## 12. P2 服务器文件与 SSH 终端（独立于 DSH）

新模块（Dart 侧已落地，analyze 通过，冒烟测试 4/4）：

- `SshSessionService`（`app/lib/remote/ssh/ssh_session_service.dart`）：只做 SSH 认证与指纹固定——不探测 DSH、不启动、不建隧道、不登录 DSH，所以 DSH 停止时文件与终端仍可用。首次使用打开，15s ping，连续 2 次失败判死并广播 `lost`；`acquire / reconnect / openFiles / openPty / close`。
- `sshSessionServiceProvider`（`app/lib/state/ssh_session_state.dart`）：按主机共享，页面 watch 持有，最后一个文件/终端页面关闭即断开。
- `SftpController` + `sftpProvider(HostRef)`（`app/lib/state/sftp_state.dart`）：
  - 浏览：`connect(path)` / `open` / `refresh` / `up`
  - 操作：`createDirectory` / `rename` / `remove(directory:)` / `chmod`
  - 编辑：`readText`（2 MiB 上限）/ `writeText`
  - 传输：`download(remotePath, localPath)` / `upload(localPath, remoteDir)` / `cancel(id)` / `clearFinished()`
  - 状态：`SftpState{phase, path, entries, failure, transfers, busy}`；`SftpFailureKind` 不带文案，由 UI 本地化。
- `SshTerminalsController` + `sshTerminalsProvider(HostRef)`（`app/lib/state/ssh_terminal_state.dart`）：
  - `openTab({title, columns, rows})` / `write(id, data)` / `resize(id, columns, rows)` / `closeTab` / `setActive` / `reconnect` / `outputOf(id)`
  - 状态：`SshTerminalsState{tabs, activeId, failure}`，`SshTerminalTab{id, status, title, exitCode, failure}`。

语义与边界：

- **DSH 无关**：既不走 `hostLink`，也不要求 `dsh web` 在跑；Attach/Managed 都能用，DSH 停止后 SFTP 与终端照常。
- **流式**：256 KiB 窗口读写，大文件不进内存；下载直接写手机文件，上传按块读本地文件。
- **取消**：在块之间生效，已写/已读部分保留；状态 `cancelled`，不删除半截文件（由 UI 让用户决定）。
- **断线**：SFTP 置 `failed(connectionLost)`、终端标签置 `ended(connectionLost)`；**不自动重连、不重放写入或命令**，只有用户显式 `retry()` / `reconnect()` / 新开标签才继续。
- **终端首屏**：页面订阅前的输出会缓冲，banner/prompt 不丢。
- **危险操作**：删除、覆盖、`chmod` 必须由 UI 二次确认；本层只执行明确调用，不提供递归删除，不获取 root。
- 已知限制：SFTP 不展开 `~`（一律绝对路径）；无递归删除/批量操作；取消上传会留下部分文件；终端不保活远端进程（channel 关闭即结束），与真实 SSH 行为一致。
