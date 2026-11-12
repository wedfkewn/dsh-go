# ShellBox 第一阶段集成与错误清单

日期：2026-11-12。分支 `feature/ios-shellbox-dynamic-island`，HEAD
`288234ae52fdfcfc2b0a0388763c371d0b09ea7d`。先读 architecture-audit.md、
shellbox-validation.md、CONTRIBUTING.md、docs/architecture.md，并对照固定 ShellBox
源码。未做 IPA、未写工作流、未 commit/push，未修改验证仓库。

## 集成文件及用途

| 路径 | 用途 |
|---|---|
| `third_party/shellbox/source.json` | 独立依赖的 URL、完整 commit、预期检出目录和许可；submodule 失败后的清单回退 |
| `third_party/shellbox/LICENSE.md` | 固定版本上游原文副本，保留作者及 GPLv3/部分贡献另按 GPLv2 声明 |
| `third_party/shellbox/LICENSE.IOS` | 固定版本上游原文副本，App Store 条件性不追责承诺，非专有豁免 |
| `third_party/shellbox/NOTICE.md` | 双语来源、版本、组合体对应源码/构建脚本及适用安装信息、AGPL 网络源码义务说明 |
| `runtime/shellbox/build-ios-libs.sh` | macOS arm64 静态库构建入口，只构建命名库目标，不签名、不打包 |
| `runtime/shellbox/ShellBoxBridge.h` | 引用上游 kernel/init.h 和 fs/tty.h；不复制或发明函数签名 |
| `app/lib/runtime/local_runtime_service.dart` | 独立于 Android 通道的启动/停止/重启/状态/错误契约 |
| `app/lib/runtime/shellbox/shellbox_runtime_service.dart` | 所有操作抛 UnimplementedError；状态只有 unimplemented 和稳定错误码 shellbox_not_implemented |
| `app/lib/runtime/runtime_platform_capabilities.dart` | 新增能力边界：Android 运行时仅 Android，ShellBox 当前始终不可用 |
| `docs/ios/shellbox-integration-errors.md` | 本报告 |

现有 Dart 文件修改行：**0**。Android、聊天、会话、模型、设置、插件 UI 和业务逻辑均未修改。
已有两份 iOS 报告在开工时就是未跟踪文件，本次保留。

先读了 runtime_state.dart 的 runtimeBridgeProvider/LocalRuntimeController、runtime_bridge.dart、
hosts_state.dart 的 HostKind/HostRef，并检查 connection_state.dart 的本机连接引用。
新接口刻意不导入 Android RuntimeBridge。**这是新增边界骨架，尚未迁移现有消费者，
不代表整个 App 的 Android 专属调用已隔离**。当前 Android 调用链保持原状，
iOS 仍不能运行；后续需要逐通道接线，保留安装、安全模式、日志与凭据等原契约。
此次不替换 provider，避免把完整 Android 契约接到未实现的窄接口上而改变业务行为。

不建立 app/ios：静态库与接口骨架不需要 Runner。没有 Flutter 时手写不完整工程
不会增加可编译证据；目前没有 Swift 文件或可构建 iOS 工程。

构建参数依据：固定 ShellBox `.github/workflows/static-libs.yml:47-157`。
macos-15、brew llvm/lld/ninja/libarchive/meson、xcrun SDK、clang/clang++、ar、strip、
pkg-config、Darwin/aarch64/little、arm64、最低 13.0、Meson guest_arch=arm64 和
三个命名目标均可在该文件找到。输出目录是本集成调用者传参，不是假称的上游目录。
与上游相比省略压缩、校验清单及发布；不增加签名。VDSO 另见 vdso/arm64/meson.build。
上游未固定准确 Xcode/SDK 版本；实际工具解析、VDSO 和链接保留 TODO，未验证。
C 依据：kernel/init.h:7-12；fs/tty.h:209 的 pty_open_fake；本地桥头仅 include 原始声明。

## A. 本机已查出

### Git 元数据写入失败（原样输出）

`git fetch origin main`，exit **255**：

```text
error: cannot open '.git/FETCH_HEAD': Read-only file system
```

`git submodule add https://github.com/lollipopkit/ShellBox third_party/ShellBox`，exit **128**：

```text
fatal: Unable to create '/data/workspace/dsh-go/.git/index.lock': Read-only file system
```

因此没有 submodule、gitlink 或成功拉取的新源代码，使用固定清单回退。
未绕过只读限制，也未创建隔离分支；沿用用户指定分支，远端 main 最新状态未核实。
只读验证源在 `/data/workspace/shellbox-validation`，HEAD 已对上固定 commit。

### 本机检查记录

| 命令/检查 | exit code | 输出摘要与范围 |
|---|---|---|
| `git status --short --branch`、`git remote -v` | 0 / 0 | 指定分支；开工仅 docs/ios/ 未跟踪；origin 为 wedfkewn/dsh-go |
| `git rev-parse HEAD` | 0 | 288234ae52fdfcfc2b0a0388763c371d0b09ea7d |
| `git -C /data/workspace/shellbox-validation rev-parse HEAD` | 0 | 5dfc962fe5e03fe5bc6b869b8744312ebe6af627 |
| `bash -n runtime/shellbox/build-ios-libs.sh` | 0 | 无输出，语法通过，非构建通过 |
| `bash runtime/shellbox/build-ios-libs.sh /data/workspace/shellbox-validation /tmp/dsh-shellbox-ios-build` | 1 | `error: requires macOS arm64 (upstream runner: macos-15)`；未安装工具、未生成库 |
| `python3 -`（内联 pathlib/json/subprocess/shutil 检查） | 0 | PASS: pin, license copies, upstream build tokens, C declarations, Dart relative import, no iOS project |
| 同一 Python 的 `shutil.which` 探针 | 0 | flutter/dart/xcodebuild/xcrun/pod/brew/meson/ninja/clang/lld 全部 NOT FOUND；探针成功不代表工具可用 |
| `git diff --check` | 0 | 无输出；该命令不覆盖未跟踪文件，另做新增文件空白检查 |
| `git diff --stat` | 0 | 无输出；无已跟踪文件修改 |
| `git status --short --untracked-files=all` | 0 | 仅本报告所列新增项及开工已有两份报告；未改 Android/workflows |
| Dart/C/脚本肉眼静态检查 | 不适用（人工检查） | 相对导入存在；没有成功启动分支或令牌字段；头文件引用存在；未做编译级类型/头文件检查 |

Python 引用检查逐项断言：清单 commit 等于验证源 HEAD；两个许可证逐字节一致；
kernel/init.h、fs/tty.h、meson.build、static-libs.yml、vdso/arm64/meson.build 存在；
上述工具/SDK/参数/库名出现在上游 workflow；mount_root、become_first_process、
pty_open_fake 的真实签名存在；Dart 相对导入目标存在；app/ios 不存在。
此检查仅核对源码证据，不代表头文件依赖闭包或库链接可用。

## B. 本机查不了，等待 macOS Runner 与设备

以下全部**未运行**，没有通过结果；本次没有创建 GitHub Actions 工作流。

- `flutter analyze` / `flutter test` / Dart 格式检查：本机无 Flutter/Dart。
- `bash runtime/shellbox/build-ios-libs.sh SOURCE OUTPUT` 的真实构建：需要 macos-15 arm64、brew、Xcode SDK；两个 SDK 的三个库、VDSO、静态依赖和 C 头文件编译都未验证。
- Flutter 插件 Pods/native assets、Runner 编译链接及 ShellBox 嵌入：无 iOS 工程、Xcode/CocoaPods。静态库最低 13.0 不代表最终 Flutter App/插件最低版本可以定为 13.0。
- rootfs realfs/fakefs、PTY 输入输出、初始化/重启/停止/资源收尾：无载荷和原生生命周期实现；Runner 构建成功也不能代替真机验证。
- Node 24/V8、npm 原生模块/子进程/网络与持续 DSH HTTP 服务：需 ARM64 Mac 初测及 iOS 真机验证，退出码 0 不能作为服务成功的唯一证据。
- 前后台挂起/恢复、Keychain、文件权限、SSH/Relay 与 UI：要签名真机测试，macOS Runner 不能完全覆盖。

## Node 24 有无新进展

**没有新的运行验证。** DSH 0.2.2-rc.1 要求 Node >=24.9.0；ShellBox 文档明确覆盖
Node 22，不能据此认定 Node 24 可用。未修改 DSH/Node 版本或 pins.json；没有降级，
没有启动 DSH。下一实验仍是固定 ShellBox + 精确记录并校验的 Node 24 二进制，
保留完整 stderr、版本/V8、派生构造函数、子进程及持续 HTTP 断言结果；之后再验证 DSH。

## 下一步 IPA 前缺什么

需先确认本清单与下一阶段范围，再在 macOS 用 Flutter 生成真正 iOS 工程：
Runner.xcodeproj/xcworkspace、Runner 启动入口、Info.plist、资源、Flutter 配置与生成插件注册、
依赖集成（包括 Pods/native assets）、ShellBox 链接/头搜索路径及实际原生 wrapper。
还缺固定 rootfs/Node/DSH 载荷、初始化与停止逻辑、逐通道能力适配和真机检查。

签名方面缺 Apple Team/应用标识、签名证书与私钥、匹配的 Provisioning Profile、
entitlements、设备/分发方式及导出配置；不将任何这些秘密写入仓库。
发布前还需确认素材授权与最终许可证/对应源码交付闭包。
本次没有 IPA、没有签名、没有构建成功声明；上述事项不在本次执行范围内。
