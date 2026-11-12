# GitHub Actions iOS 无签名编译检查

工作流：[ios-check.yml](../../.github/workflows/ios-check.yml)，名称
`iOS Check (no codesign)`。用于发现 Flutter 分析、ShellBox 静态库和 iOS
编译链的实际阻塞。不导出 IPA、不做签名、不读 Secrets、不上传可安装产物；
仅上传日志，不代表本地引擎、手机安装或真机功能已通过。

触发条件：push 分支为 `feature/ios-shellbox-dynamic-island`；pull_request
的**目标分支**为该分支（GitHub 的 branches 过滤针对 base）；手动
workflow_dispatch 也仅在选择该分支时执行 job。没有 paths 过滤，main 上的
push 或以 main 为目标的 PR 不自动运行此工作流。

Runner 为 `macos-15`，ShellBox 脚本要求宿主 arm64，实际架构会记录在日志中。
Flutter 固定 `3.47.7`，来源为 `tooling/setup-toolchain.sh` 和现有 `ci.yml`，
与 `goldens.yml` 一致；App 为 `1.0.15+1`，Dart 约束 `^3.13.5`。
Homebrew 安装 `llvm lld ninja libarchive meson`（与 ShellBox 脚本一致），
另用 `brew install` 安装真实公式 `cocoapods`。现有 CI 没有 CocoaPods 安装先例。
Xcode、SDK 和 Homebrew 工具版本没有固定，依赖 Runner 镜像与当时公式；不能声称
已验证某个精确版本。构建脚本自身也会安装上述五个 ShellBox 工具。

执行顺序：

1. `actions/checkout@v4`，不持久化检出凭据。
2. `subosito/flutter-action@v2` 安装 Flutter 3.47.7 stable。
3. 安装构建依赖，记录宿主、Xcode、Flutter、CocoaPods 版本。
4. 在 `app/` 运行 `flutter pub get`。
5. 在 `app/` 运行 `flutter analyze`。
6. 读取 `third_party/shellbox/source.json` 的 URL、commit 和 checkout_path，
   检出 `https://github.com/lollipopkit/ShellBox` 的
   `5dfc962fe5e03fe5bc6b869b8744312ebe6af627` 到 `third_party/shellbox-src`（与已提交的许可证副本目录分开，避免 checkout 覆盖冲突）。
   调用 `bash runtime/shellbox/build-ios-libs.sh SOURCE_CHECKOUT OUTPUT_DIRECTORY`，
   输出到 Runner 临时目录；生成设备/模拟器 arm64 的三个静态库，只构建、不签名。
7. `app/ios` 不存在时，在 Runner 的 `app/` 运行官方命令
   `flutter create --platforms=ios .`；生成物仅用于当次检查，不提交、不上传。
8. 在 `app/` 运行 `flutter build ios --no-codesign`。
9. 失败时汇总各关键日志最后 80 行；无论成功失败，使用
   `actions/upload-artifact@v4` 上传完整命令 stdout/stderr 日志，保留 7 天。
   analyze、ShellBox build、Flutter build 各自独立记录。失败前未执行的步骤
   没有日志；checkout/Flutter 安装 Action 的输出见 GitHub 原始 job 日志。

关键命令使用 Bash `set -euo pipefail`，通过 tee 保存日志不会吞掉失败。
无 continue-on-error；首个失败会阻止后续构建，失败摘要不改变原始失败状态。
上传范围仅为日志目录中的 `.log`，不包含静态库或 App。

首次运行**预期失败**，尚无实际 Actions 结果。若依赖解析或分析先失败，
流程会在那里停止；否则可能首先在未编译验证过的 ShellBox 构建处失败
（宿主架构、工具解析、SDK/VDSO 等）。到达 Flutter 构建后，缺失的 iOS 工程
会由官方工具临时生成，但模板不会补齐 Android-only 插件、原生平台通道或
ShellBox 链接/wrapper，因此 Pods/native assets/编译链接仍可能失败。
不能预先断言某个插件必定编译失败，应以首轮日志为准。

Node 24 状态仍为 **UNKNOWN**：DSH `0.2.2-rc.1` 要求 Node `>=24.9.0`，
ShellBox 文档仅明确覆盖 Node 22。本工作流不启动 Node/DSH，也不把 Node 24
未验证伪装为确定的编译错误或通过结果。即使无签名构建成功，也未验证
ShellBox 实际嵌入、rootfs、PTY 或本地服务。

本机验证（2026-11-12，Linux 服务器，仅静态检查）：

- Python 导入 yaml 失败：**本机无 pyyaml，未做解析验证**；未安装依赖冒充验证。
- 核对引用文件/脚本路径存在、ShellBox 清单与脚本固定提交一致、两个位置参数
  符合真实接口；Flutter 版本与 setup-toolchain.sh、ci.yml、goldens.yml 一致。
- 检查内嵌 Bash 的 `bash -n` 语法、步骤顺序、分支限制、只读内容权限、日志管道；
  无 Secrets 表达式、签名身份配置、导出、发布或可安装产物上传命令。
- `git status --short`、`git diff --stat` 核对无已跟踪文件修改；相较开工状态，
  只新增本工作流与本文。开工已有其他未跟踪的 iOS 报告和 ShellBox 集成文件，均保留。
- 本机未创建 `app/ios`，未运行 Flutter/ShellBox/iOS 构建；Linux 不能替代 macOS。
- 分支为 `feature/ios-shellbox-dynamic-island`，HEAD 为 `288234ae`，无 upstream；
  `git fetch origin main` 因 `.git/FETCH_HEAD` 只读失败，远端新鲜度未核实。

实际运行还需要用户将分支及工作流引用的 ShellBox 集成文件推送到 fork
`wedfkewn/dsh-go`，并在 GitHub 上启用 Actions，确认 macOS Runner 可用。
当前服务器 gh 未登录（用户已核实），这是通过本机 CLI 操作 GitHub 的阻塞；
本任务没有登录、读取登录凭据、提交、推送或触发运行。
workflow_dispatch 的界面入口还要求工作流存在于默认分支；仅放在 feature
分支时应先依靠该分支的 push 事件，不承诺立即出现手动运行按钮。
