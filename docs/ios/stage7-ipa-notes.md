# Stage 7：手动构建 iOS IPA

工作流：`.github/workflows/ios-ipa.yml`，Actions 中显示为 **iOS IPA Build**。
仅配置 `workflow_dispatch`，push 和 pull request 都不会自动触发。

## 手动运行与执行顺序

1. 将工作流提交推送到 GitHub。GitHub 的手动运行入口需要默认分支中存在该工作流；若当前只存在于功能分支，网页可能不显示 Run workflow，不能把推送成功当成可直接点击运行。需要维护者以后将工作流按仓库流程纳入默认分支，再在 Actions → iOS IPA Build → Run workflow 中选择目标分支（本阶段为 `feature/ios-shellbox-dynamic-island`）。本阶段不自动合并。
2. 使用 `macos-15`，Checkout 后选择 `/Applications/Xcode_26.0.1.app/Contents/Developer`，安装 stable Flutter `3.47.7`。
3. 安装 Homebrew 依赖 `llvm lld ninja libarchive meson cocoapods`，在 `app/` 执行 `flutter pub get` 和 `flutter analyze`。
4. 从 `third_party/shellbox/source.json` 读取 URL、钉死提交和 `checkout_path`，检出 ShellBox。运行 `runtime/shellbox/build-ios-libs.sh`，沿用脚本里的补丁，输出到 `$RUNNER_TEMP/shellbox-ios-libs`。工程的 ShellBox 配置继续使用 Actions 自带的 `RUNNER_TEMP`。
5. 沿用 ios-check 的临时 iOS 工程检查，然后在 `app/` 执行 `flutter build ios --no-codesign`。准备或门禁失败时工作流失败，后续签名、导出、上传均不执行。
6. 门禁通过后检查六项签名 Secrets。任意一项缺失或为空，打印“未配置签名，跳过 IPA 导出”，正常绿色结束，没有 IPA Artifact。即使只配置了一部分，也会跳过；完整但无效的材料会导致签名步骤失败，不伪装成成功。
7. 完整配置时，将证书导入随机密码的临时 keychain，安装两个目标的描述文件，在临时目录生成 `ExportOptions.plist`，仅在 runner 检出中设置各目标的手动签名描述文件。执行 `xcodebuild archive` 和 `xcodebuild -exportArchive`，成功后上传 `ios-ipa-<run_id>-<run_attempt>` Artifact（保留 7 天）。构建日志（`ios-ipa-logs`）无论成功失败都会上传为 Artifact，保留 7 天。步骤退出时恢复 keychain 搜索列表，删除临时 keychain、安装的描述文件及临时签名文件。不会登录 Apple ID，也不使用自动下载描述文件的选项。

## 以后需要准备的材料

需要用户自行拥有具备对应权限的 Apple Developer 账号/团队，在 Apple Developer 网站或自己的 Mac 上准备注册的 App IDs、所需 capabilities、证书和描述文件。账号只用于用户自行办理材料，**不放入本工作流，不提供账号密码给代理，不登录 Apple ID**。

本工程同时包含主应用和 Live Activity 扩展，必须分别准备匹配的 Provisioning Profile：

- Runner：`io.github.ccch1mneyyy.dshApp`
- PetLiveActivity：`io.github.ccch1mneyyy.dshApp.PetLiveActivity`

两个描述文件需属于同一 Team，匹配签名证书、公钥、各自 App ID 与 entitlements（含工程使用的 App Groups）。开发或 Ad Hoc 安装需包含目标设备 UDID；App Store Connect 导出的 IPA 用于后续上传/TestFlight，不能直接安装到任意设备。本工作流不上传 App Store Connect、不发布、不验证真机运行。

## GitHub Secrets 清单

在仓库 **Settings → Secrets and variables → Actions → New repository secret** 逐项创建（需要仓库管理权限）。值必须是真实材料，不要提交到 Git、贴到 issue 或构建日志中。

| Secret | 格式与含义 |
|---|---|
| `IOS_CERTIFICATE_BASE64` | 含私钥的 Apple Development 或 Apple Distribution `.p12` 文件的单行标准 base64。证书必须与导出方式、描述文件匹配。 |
| `IOS_CERTIFICATE_PASSWORD` | 导出 `.p12` 时设置的非空密码。空密码在本工作流中视为未配置。 |
| `IOS_PROFILES_BASE64_JSON` | JSON 对象：键为上面两个完整 Bundle ID，值为各自 `.mobileprovision` 原始文件的单行标准 base64 字符串。必须且仅包含这两个键；不要把解码后的 plist 或文件路径填进去。 |
| `IOS_TEAM_ID` | Apple Developer 团队的真实 Team ID 字符串。 |
| `IOS_SIGNING_IDENTITY` | 已导入证书的 SHA-1 指纹（40 位十六进制字符串，可在自己的 Mac 上通过 `security find-identity -v -p codesigning` 查看）。用于 archive 和 export，避免证书名称歧义。 |
| `IOS_EXPORT_METHOD` | Xcode 26 的导出方式字符串，例如 `development` 对应的新名称 `debugging`、Ad Hoc 对应 `release-testing`，或 `app-store-connect`。请填 `debugging`、`release-testing` 或 `app-store-connect` 中与材料匹配的一项；企业分发仅在团队具有对应资格时使用 `enterprise`。 |

在自己的可信 Mac 上可用 `base64 -i <文件> | tr -d '\n'` 编码证书或描述文件，然后通过 GitHub 的 Secret 输入框保存。创建 JSON 时分别把两份描述文件的编码作为上述 Bundle ID 的值。不要在共享终端、录屏或日志中展示这些值。无需设置 keychain 密码 Secret，运行时自动随机生成。ExportOptions 的 Team、证书、导出方式和描述文件映射均来自这些 Secrets；仓库不保存实际 ExportOptions.plist。

## 当前边界与验证记录

目前没有签名材料，预期路径仅为：准备 → 无签名构建门禁 → 明确跳过 IPA 导出。绿色结果代表无签名构建通过，不能证明签名或 IPA 安装成功。此前 bed605a4 的云 Mac 无签名构建结果是已有背景，不是本工作流的运行结果。

本阶段在 Linux 沙箱通过系统 libyaml 的 YAML 解析、7 段 shell 的 `bash -n`、内嵌 Python 语法检查，以及准备步骤、手动触发、门禁和六项 Secrets 的文档一致性核对。PyYAML 和 Ruby 在本机未安装，因此未进行 Ruby 语法或 Xcodeproj 执行验证；没有 macOS/Xcode，没有运行此工作流，也没有验证签名、archive、export 或真机安装。即便以后填齐 Secrets，也必须首次在 GitHub macOS runner 实跑，核验实际 Apple 签名权限、证书有效期、Profile/capabilities 和 Xcode 导出兼容性，再在获授权设备上验证。缺少真实材料时无法产出真正可安装的 IPA。
