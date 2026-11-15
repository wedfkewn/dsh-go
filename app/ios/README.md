# iOS 工程

Flutter 3.47.7，最低 iOS 15。插件走 Swift Package Manager，这个工程没有 CocoaPods 的 `Podfile`。本机已在 Xcode 27.2 验证无签名真机构建；`iOS compile` 使用 Xcode 26.6，手动 IPA 工作流使用 Xcode 26.0.1。版本不同不影响工程结构，但签名和导出以实际选择的 Xcode 为准。

## 在 Mac 上编译

如果终端提示 `zsh: command not found: flutter` 或进程返回 `Exited with status code 127`，先修工具链，不要改 Xcode 工程。Flutter 不在默认 `PATH` 时，可临时或永久把安装目录加入 `PATH`：

```sh
export PATH="$HOME/flutter/bin:$PATH"
flutter --version
```

然后从仓库根目录执行：

```sh
cd app
flutter pub get
flutter build ios --simulator --debug
flutter build ios --release --no-codesign
```

最后一条命令只生成未签名的真机 Release 包，不能直接说明 iPhone 可安装。需要本机 Node 引擎时，先运行 `tooling/ios/prepare-engine.sh`；其产物在 `app/ios/Engine/`，不进 git。

开发或查看签名配置时打开 workspace，不要打开 `.xcodeproj`：

```sh
cd app
open ios/Runner.xcworkspace
```

`Missing package product 'FlutterGeneratedPluginSwiftPackage'` 通常是把 `Runner.xcodeproj` 当成入口，或还没执行 `flutter pub get`/Flutter 构建生成的 Swift Package 集成。先 `flutter pub get`，再打开 `Runner.xcworkspace`。单纯运行 `flutter build` 时也不要指定 `.xcodeproj`。

### 三个可分发 target

当前工程有三个 shippable target，必须使用同一 Team，并为每个 target 准备独立、匹配的 Provisioning Profile：

- `Runner`：`io.github.ccch1mneyyy.dshgo`
- `ShareExtension`：`io.github.ccch1mneyyy.dshgo.ShareExtension`
- `PetLiveActivity`：`io.github.ccch1mneyyy.dshgo.PetLiveActivity`

三者都声明同一个 App Group：`group.io.github.ccch1mneyyy.dshgo`。扩展 ID 必须以主 App ID 为前缀。`ShareExtension` 是当前分享入口，`PetLiveActivity` 是当前 Live Activity 组件，不能为了绕过 Personal Team 或签名错误删除它们。

免费 Apple 账号（Personal Team）是否能为该组合注册 App Group 和两个扩展取决于账号与 Apple 当前策略；若不能，该账号不能产出合格的自签 IPA。应改用具备对应 capabilities 的正式开发者团队，而不是删除扩展、权限或后台模式。

首次在 Xcode 中自动签名时，三个 target 都要选择同一 Team，并确认各自 App Group capability 已启用。若任一 target 的 App ID、Profile、Entitlements 或 Team 不一致，安装阶段会失败。

`PetLiveActivity` 还以 folder reference 带着 `app/assets/pets`（构建后位于 `PetLiveActivity.appex/pets/`）。每次状态更新都随 `ContentState.art` 内联一张 App 渲染的小型透明 PNG，所以第三方导入宠物即使 App Group 被剥掉、扩展读不到 App 沙盒，也会显示导入宠物的真实静帧。原生读取顺序是内联 PNG、App Group 暂存的 `<group>/pet-art/<packId>`、appex 自带的 `pets/<packId>`（内置宠物）、emoji。Console 里 `using_bundled_art` 表示走到了 appex 内置图。

### 无签名结构与签名检查

从仓库根目录检查未签名真机产物：

```sh
python3 tooling/ios/verify-ipa.py --unsigned \
  app/build/ios/iphoneos/Runner.app
```

对已经构建好的 `Runner.app` 按从内到外逐 bundle 重签并生成 IPA：

```sh
tooling/ios/sign-app.sh \
  --app app/build/ios/iphoneos/Runner.app \
  --identity "Apple Development: Example (TEAMID)" \
  --profiles "$HOME/Desktop/dsh-profiles" \
  --team-id TEAMID \
  --output "$HOME/Desktop/DSH.ipa"
```

`--profiles` 目录里必须恰好能匹配上述三个 Bundle ID 的三份 `.mobileprovision`；签名材料不要放进仓库。脚本不使用 `codesign --deep`，而是依次签 Framework、扩展和主 App，再调用 `verify-ipa.py` 检查全部 Mach-O、嵌套关系和签名。手工验 IPA：

```sh
python3 tooling/ios/verify-ipa.py \
  --require-profiles --require-native-node --require-engine \
  --team-id TEAMID --signing-identity TEAMID \
  "$HOME/Desktop/DSH.ipa"
```

若当前产物没有本机引擎，去掉 `--require-native-node`/`--require-engine`；正式发布若要求这些组件，就不应去掉。CI 的 `iOS IPA Build` 在未签名构建后和导出 IPA 后都会运行结构门禁。

### 安装失败与运行加载失败要分开

- 安装阶段验签失败：系统还没完成安装。常见日志包括 `MIInstallerErrorDomain`、`ApplicationVerificationFailed`、`0xe8008015`、`0xe8008001`，原因通常是嵌套 Framework/扩展未签、签名 Team 不一致、Profile 不匹配、entitlements/App Group 未授权或证书过期。
- 安装成功后动态库加载失败：App 已进入启动阶段。常见日志是 `dyld: Library not loaded`、`@rpath` 解析失败、`dlopen` 失败，应检查 Framework 是否在正确的 `Frameworks/` 路径、install name 和 Node/runtime 路径。

没有 iPhone 的安装日志时，只能证明结构和签名材料自洽，不能宣称“无法验证 App 完整性”已在真机上修复。
## 引擎 addon 的 framework 布局

两份 addon 由 `build-engine-native.sh` 输出为 `DshFlock.framework/DshFlock` 和 `DshRequireBuiltin.framework/DshRequireBuiltin`，与 `DshNodeHost.framework` 一起嵌入 App 的 `Frameworks/`。iOS 宿主校验与生成 runtime 的 loader 必须使用同一布局；addon 源码、N-API 版本和注册名不因包装改名。升级必须重新准备 runtime，不能把旧 loader 与新 framework 混用。 嵌入脚本会在编译和复制前检查已准备 ZIP 的唯一 loader 成员及两项新路径；旧布局、缺失或损坏时明确失败并要求重跑 `tooling/ios/prepare-engine.sh`，不会自动下载。

`embed-engine.sh` 清除增量构建遗留的两个裸 `.so`，启用签名时逐个签 framework；`CODE_SIGNING_ALLOWED=NO` 仍产出未签名代码，安装前必须由 Xcode 或重签工具签妥全部嵌套 framework。包装改变不是签名验证成功的替代，第三方重签与真机启动须实际复核。模拟器 engine-smoke 会要求新 executable 路径存在，再进入原真实工具回合。

## iSH 的构建产物

`tooling/ios/build-ish.sh iphoneos OUTPUT_DIR`（或 `iphonesimulator`）从固定的
`OpenMinis/ish-arm64` 提交下载源码，核对 SHA256 后打 `tooling/ios/ish/build.patch`，
生成未签名的 `DshGuest.framework`。上游源码和工具链缓存不进仓库。
本补丁**未在 Apple 上编译**，首次真实验证由 `iOS compile` 的 `engine` 任务执行。

Mac 首次构建还需 LLVM（生成 ARM64 Linux VDSO）、独立 lld、Meson 和 Ninja；CI 使用
Meson 1.7.2、Ninja 1.11.1.4。可运行 `brew install llvm lld meson ninja`，并将
`$(brew --prefix llvm)/bin`、`$(brew --prefix lld)/bin` 以及 Meson/Ninja 放进 `PATH`。
iSH 构建脚本兼容 Python 3.9+；固定源码包使用先验证全部路径的解压器，仅接受目录和
普通文件，不依赖 `tarfile.data_filter`，不会退回未过滤的 `extractall`。
已准备本机引擎时，Xcode 嵌入阶段会调用该脚本；未准备引擎的远程专用包仍跳过。
缓存分别在 `Engine/build/iphoneos/guest` 和 `Engine/build/iphonesimulator/guest`，
命中前核对构建输入、Xcode/SDK/实际 Apple clang 和全部产物 SHA256；命中后不再探测
构建工具、下载或解压，因此 Xcode 阶段的 Python 版本及 PATH 顺序变化不会使有效缓存失效。
缓存未命中才检查 Meson/Ninja/LLVM/lld 并给出安装命令；固定源码压缩包在 `Engine/ish-cache`。

`DshGuest.framework` 与其他引擎 framework 一起复制和签名，不在 App 启动时链接。
它携带上游许可、固定源码地址和本地修改补丁；Archive 继续拒绝 framework 外的原生代码。
可选 Linux 安装入口和 guest owner 已接入；安装后重启本机引擎才启用 Linux 路由。工作区准入、权限与路由的本轮修复仍需 iPhone 真机复验，模拟器或 Linux 上的测试不代替真机结果。

### 可选 Linux 的 shell 契约

- 没安装 Linux 时，保留 just-bash 和引擎 Node Worker；不把它们描述成真正的 Linux。
- 已安装且由可信原生 owner 接入时，普通脚本整段交给 Linux。`cat /etc/os-release`、`ls /`、`command -v apk` 和管道不再按虚拟命令清单决定环境；guest 不可用或缺包时明确失败，不回退虚拟后端重跑。
- guest 使用 `/bin/sh`（Alpine ash），不是完整 Bash。需要 Bash 时在 guest 安装后显式调用；`git`、`rg`、`jq` 等也需要 guest 自己安装，不能借用虚拟桩。只有工作区 `/workspace` 和私有 `/tmp` 是宿主挂载，`danger-full-access` 也不能突破 iOS 沙箱或扩大挂载；执行仍需工具策略生成的一次性票据。
- 静态明确的 `node script.mjs` 等仍用引擎 Node Worker，可配合简单的虚拟管道命令；含 guest 命令、动态或不透明执行的 Node 混合脚本先拒绝，不执行前半段。脚本文件、stdin 及未选择 Worker 的动态命令或 `source`/`eval` 都只在 Linux 内执行，其中的 `node` 是 guest 程序，不会切回引擎 Worker。

本机可运行的回归检查（不启动 iSH）：

```sh
npm ci --ignore-scripts --prefix runtime/ohos/process
python3 runtime/ohos/process/build-just-bash.py
node --test tooling/ios/guest-tests/route.test.mjs runtime/tests/ios-guest-policy.test.mjs
python3 tooling/ios/tests/guest-admission.test.py -v
```

票据与真实 worker 集成测试另需从 `runtime/locks/dsh-0.2.2-rc.1/` 安装的独立 npm 前缀；先安装 `runtime/ohos/node/build-tools` 的锁定依赖并运行 `node runtime/ohos/process/build-rg-regex.mjs`，再按 [runtime.test.mjs](../../tooling/ios/guest-tests/runtime.test.mjs) 的启动说明运行。该测试使用真实工具、审批、Worker 和生成的 override，但 native 通道只记录请求，不运行 iSH；JIT 与 `--jitless` 分别验证。真机还应分别在只读、工作区可写和完全权限会话里测试独立环境探测、包管理、普通管道、Node Worker 及混合脚本拒绝。

## 现状

- CI 会在 iOS 模拟器上真跑：真 NodeMobile 的工具回合、取消、停止和恢复会话；停止时不误关别人的 fd；真 App 里的安装、启动、登录、停止、重启和重置；真 App 启动后 30 秒还活着；在 App 进程里真调用提醒、联系人、定位、OCR 和网页操作，只有点确认框是测试代点的（`RunnerTests`，选图除外）。上述 CI 运行门是 Debug 构建。2026-11-06 一台 iPad Air 5（iPadOS 18.7.7）装了自签的 Release 包：App 三次冷启动都正常，本机引擎在加载没签名的 addon 时失败，addon 因此改成了 framework，改后还没在真机上跑过。这不说明 iPhone 上 TestFlight 包的白屏已经解决，下面的验收项也还没做。
- 本机引擎和鸿蒙共用基础层（`runtime/ohos/`）：同进程的 Node（NodeMobile 24.22.1，`--jitless`）。未安装可选 Linux 时，命令由 just-bash 模拟，没有 Linux 或 Python；安装并启用后按上面的 guest 契约运行，软件包以 guest 实际安装情况为准，仍不能任意启动 iOS 宿主进程。基础引擎首次安装解压约 160 MB；可选 Linux 另占空间。引擎第一次启动时才加载，只连远程的人不占这份内存。
- 和鸿蒙不同：停止后能原地再启动，不用重开应用（`runtime/ios/host/node_runner.cc`）。
- 和鸿蒙不同：本机引擎能处理图片。sharp 在这里装不了，所以 `runtime/ios/image/ios-sharp.cjs` 替代它，像素走系统的 ImageIO（`runtime/ios/host/image_binding.cc`），附件库自己的规则不变。ImageIO 写不了 WebP，所以带透明的图存 PNG，比目标大时压不下去（只影响透明图）。校验和缩放都走缩略图路径，大图的像素不用全部放进内存，但实际峰值还没在设备上量过。
- App 切到后台后，系统很快会暂停引擎；后台的本地监听被回收时，回到前台会自动重启引擎。iOS 26 以上，本机正在跑的一轮会向系统申请继续运行（`BGContinuedProcessingTask`），系统同意就接着跑并显示进度，也可能随时收回，收回后和暂停一样。这部分只编过、没在设备上跑过。
- 引擎的堆上限是 `--max-old-space-size=256 --max-semi-space-size=4`，还没在设备上定过。它和 App 同进程，所以快撞上限时 runner 会停掉这次运行（退出码 70），App 留着，可以重新启动。这一轮不会接着跑。Buffer 和原生内存、系统的 jetsam 不在保护范围内。
- NodeMobile 24.22.1-0 记录 fd 时增删用的哈希不一样，Environment 结束时会按旧号关掉别人的文件和 socket，所以主线程和 Worker 都关了 fd 跟踪。代价：一次运行留下没关的原始 fd，要到 App 退出才释放。
- 桌宠悬浮窗、后台常驻、应用内 APK 更新在 iOS 上没有，已隐藏。
- 手机系统动作（日历、分享、拨号草稿等）给本机引擎提供 13 个 `mcp__phone__*` 工具，和安卓同一份目录。每个动作都要在 App 里批准一次，通知点击不算批准。系统动作本身还没在设备上跑过。
- Siri 和快捷指令（iOS 16 以上）：问 DSH Go、语音输入、新建对话。都只是打开 App 停在输入框，不会自动发送。CI 只查过元数据，没实际喊过。
- 内置浏览器：`mcp__browser__*`，App 内一个独立的 WKWebView，脚本跑在单独的 content world 里。每次运行里，每个站点第一次要用户批准。密码和支付字段不让填，弹页面交给用户。不能访问本机和内网地址，但只查写死的 IP，解析到内网的域名拦不住。iOS 17 以上登录状态和 App 其他网页分开存。
- 系统工具：`mcp__system__*`，读写提醒事项和联系人、选图片、读一次位置、识别图片里的文字。只在用户看着 App 时才跑，每次都弹确认并写明要读写什么。选图片用系统选择器，它本身就算同意；文字识别只能用这个对话选过的图片，图片 30 分钟或本次运行结束后失效。这部分只编过、没在设备上跑过。
- 控制其他 App：默认仍用 `tooling/ios/phone-runner.sh <设备 ID>` 从 Mac 启动长期运行的 XCTest（`PhoneRunner` target），读取结构化元素并执行操作；需要开发者模式、同 Team/App Group 签名以及常驻的 Mac 脚本。另有[端上 XCTest 实验](../../tooling/ios/phone-self-runner.md)：显式构建可选原生库后，用 RP 配对、本机隧道和已安装 helper 在手机启动同一套元素读屏；新握手不依赖 App Group，但必须预先挂载匹配 DDI，不声称设备重启后也能永远不用 Mac。用户现有一次 30 分钟授权、敏感输入拦截和 handoff 保留，没有增加逐步确认。Mac 路径已有模拟器烟测；新端上路径尚未做 Apple SDK/真机验证，不能上架或当成已可用功能宣传。
- `dsh/native-media` 的语音不提供：回声消除管不到扬声器。`dsh/usage` 只读不上报：Worker 只收安卓的值。`dsh/dynamic_color`、`dsh/picture_shortcut` iOS 没有公开接口，入口隐藏。
- 设备档位：内存低于 3.5 GiB 算低档，其余中档，不用 `high`。
- 通知只在应用运行时发得出去。锁屏和离开应用后的提醒要 APNs，还没做，所以离开应用后等你确认的请求不会提醒你，回到应用才看得到。
- 凭据存在 Keychain，只留在本机，不随备份迁移。全新安装时会先清掉上一次安装留下的 Keychain。“完整凭据能不能落盘”这件事和安卓一样还没改，发行前要定。
- 包里还带着 `assets/engine/`，隐藏入口不等于移除。发行前要决定去留，并生成 iOS 的第三方许可清单。
- 分享扩展靠响应链唤起主应用，这是非公开用法，上架时要重新评估。唤起失败时，内容留在收件箱，下次回到应用时送达。

## 真机验收

装好后逐项过一遍，失败的记下系统版本和现象：

| 项 | 怎么测 | 应该看到 |
|---|---|---|
| 首次引导 | 全新安装 | 只出现通知和语音两项权限，没有存储、电池、无障碍；通知和麦克风各弹一次系统对话框 |
| 远程连接 | 配对一台主机，发一轮消息 | 回复流式出现；局域网直连时系统问一次本地网络权限 |
| 系统识别 | 输入框点语音，说中文和英文 | 边说边出字；结束后文字留在输入框；飞行模式下，支持本机识别的语言仍可用 |
| 语音被打断 | 听写时来电或定闹钟 | 听写结束并提示，之后应用里的声音正常 |
| 通知 | 应用在前台，后台跑完一轮 | 收到提醒，点开进入对应对话 |
| 通知被拒 | 系统对话框选不允许，再到后台运行页点通知 | 跳到系统设置的通知页 |
| 快捷操作 | 长按桌面图标 | 有新对话、语音输入和最近的对话，点开各自进入 |
| 冷启动快捷操作 | 划掉应用后再用快捷操作 | 同样能进入，不丢 |
| 分享文字和链接 | Safari 分享一个网页 | 应用被唤起，新对话输入框里有链接和标题 |
| 分享照片 | 相册选 3 张（含一张 HEIC），分享 | 都在附件里，HEIC 变成 JPEG，长边不超过 2560 |
| 分享过多 | 一次分享超过 9 项 | 系统不提供 DSH Go，或多出的提示被跳过 |
| 唤起失败 | 分享后没有回到应用时，手动打开应用 | 内容仍然送达，只送一次 |
| 分享时被杀 | 分享后立刻划掉应用，再打开 | 内容还在，可能重复一次，不会自动发送 |
| 重装 | 登录后卸载，再装回来 | 不会带着旧凭据自动连上 |
| `.dshgo` | 文件 App 里打开或分享一个 `.dshgo` | 进入分享码导入，不会变成聊天附件 |
| 链接 | Safari 打开 `dshgo://` 链接 | 进入对应页面 |
| 文件 | 打开和保存对话产生的文件、PDF 预览 | 预览正常，保存后在文件 App 的 DSH Go 目录里 |
| 相册 | 保存生成的图片 | 系统只要求“添加照片”权限，图片进相册 |
| WebView | 打开网页模式，切后台久一点再回来 | 被系统回收时显示“网页已关闭 · 重新打开”，点开后恢复 |
| 本机引擎安装 | 设置里安装本机运行环境，中途杀掉应用再来一次 | 有进度；第二次接着装完 |
| 本机引擎一轮 | 配好模型，新对话让它写文件、搜索、跑 bash | 回复流式出现，审批是真弹的，文件在产出目录 |
| 本机引擎重启 | 停止，再启动 | 不用重开应用，新对话正常 |
| 本机引擎切后台 | 跑一轮时切走几分钟，再回来 | 接着跑或明确报结果未知，不重复执行工具 |
| 结果未知 | 工具跑到一半时划掉应用，再打开那个对话 | 横幅说有调用没等到结果；确认之前工具被拒绝；确认后对话能继续，那个调用不会重跑 |
| 本机产出 | 让引擎往产出目录写文件，再打开、分享、保存 | 产出列表里有它，三个操作都正常 |
| 本机图片 | 配一个支持图片的模型，发一张 4800 万像素照片和一张透明 PNG，再让内置浏览器截图 | 模型看得到图内容；照片方向正确；发送时内存不至于把 App 杀掉；对话里有缩略图 |
| 重置和卸载 | 引擎页重置（保留技能），再装回来；再卸载 | 选了保留的还在，其余没了；卸载后存储空间回来，远程连接不受影响 |
| 只连远程不加载引擎 | 不启动本机引擎时看内存（Xcode 调试栏） | 没有多出约 90 MB 的 Node |
| 后台继续（iOS 26） | 本机跑一轮时切走 | 系统显示进度，这一轮接着跑；系统收回后回来能看到结果或结果未知，不重复执行工具 |
| Siri | 喊“问 DSH Go”，快捷指令 App 里也找一下 | 打开 App，内容在输入框里，没有自动发送；中文系统用中文短语 |
| 内置浏览器 | 让引擎打开一个网站、读内容、点链接、填搜索框 | 第一次弹站点批准；换站点再弹；密码框被拒绝并弹页面给你；关掉后没有留下进程问题 |
| 浏览器和 App 分开 | 在内置浏览器登录一个网站，再看 App 的网页模式 | 登录状态不互通（iOS 17 以上） |
| 提醒事项 | 让引擎列提醒、新建一条、标记完成 | 每次弹确认写明内容；系统权限只问一次；提醒 App 里能看到改动 |
| 改过的提醒 | 引擎列完后手动改那条提醒，再让它标记完成 | 引擎收到“已经改过了”，没有覆盖你的改动 |
| 联系人 | 让引擎查一个人的电话、新建一个联系人 | 确认里写明查什么；只返回问到的字段；不动已有联系人；iOS 18 受限授权时只查得到允许的 |
| 选图片和识别 | 让引擎选一张带中文的图并读文字 | 弹系统选择器；读出中文；换个对话用这张图被拒绝 |
| 位置 | 让引擎读当前位置，再在设置里改成大致位置 | 确认后弹一次系统权限；大致位置时返回 `reduced` |
| 控制其他 App | Mac 上跑 `phone-runner.sh`，让引擎打开设置、读屏幕、点一项 | 先弹 30 分钟授权；能看到和操作；密码框被拒绝；Mac 上停掉后工具明确报不可用 |
| 换主题的网页小窗 | 系统和应用的深色设置不一致时打开插件小窗 | 跟随应用的深色，文字缩放跟随 |
| 深色模式 | 系统切深色后启动 | 启动屏不闪白 |
| 中文 | 系统语言切中文和英文 | 权限说明和快捷操作跟随系统语言 |
| 图标 | 桌面、设置页 | 显示品牌图标，不是 Flutter 默认图标 |
| 换图标 | 外观页依次选四款图标 | 系统提示后桌面图标跟着变，重开应用仍选中当前这款 |
