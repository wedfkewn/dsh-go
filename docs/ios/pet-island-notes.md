# 选中宠物的灵动岛补链

2026-11-13，基于 fix/ios-shellbox-network-lifecycle / 6cf30481；仅改工作树，未提交、未推送。

## 复核与缺口

- 原有桥接链路完整：home_shell.dart:316、pet_stage.dart:174、web_home.dart:213 挂载 petOverlayBridgeProvider，经 live_activity_state.dart 的 iOS 分支到现有插件和扩展；Info.plist 与扩展 target 已配置。
- app/lib/notify/live_activity.dart:116 在没有目标时返回 null；原 app/lib/notify/pet_live_activity.dart:14–16 随之返回 null，通道发送 end。只选择宠物无法显示活动。
- 原 app/lib/notify/pet_live_activity.dart:27–34 未传 packId；原 app/ios/PetLiveActivity/PetLiveActivity.swift:55–62 仅按 phase 渲染猫表情。
- app/lib/ui/pets/pet_picker.dart:106 确实只设置偏好，但“选宠物不触发”不准确：pet_signals.dart:650 读取偏好，livePushProvider 监听宠物 packId，已有桥接会发送变化。无需在 _pick 中另起启动逻辑。

## 修改文件

- app/lib/notify/pet_live_activity.dart：仅 iOS payload 在 enabled 且已选宠物、无会话活动时回退 idle；稳定目标为 host=local-pet、sessionId=packId；真实会话优先，reducer 返回 null 后自然回到 idle。传递 packId，保留会话 phase/label。
- app/ios/Shared/PetActivityAttributes.swift：ContentState 增加可选 packId（兼容缺失字段）；idle 宠物不生成虚假会话深链。
- app/ios/Runner/PetLiveActivityPlugin.swift：透传 packId；本地 idle 无会话新鲜度问题，不设 staleDate，真实会话仍保留原过期规则。
- app/ios/PetLiveActivity/PetLiveActivity.swift：锁屏及 expanded / compact / minimal 共用按 packId 渲染的系统 emoji，Deepy 为 🐳、whale-girl 为 🐋；其他包保留现有 phase 表情。未加入美术素材。
- app/test/notify/pet_live_activity_test.dart：补 idle、none、禁用、会话接管/返回、换宠物与通道顺序测试。
- docs/ios/pet-island-notes.md：本说明。

Android 路径、共享 reducer、第八轮网络/生命周期修复均未修改；无新依赖。

## 本机验证

在 app/ 下使用 /data/workspace/round8-flutter/bin/flutter：
- flutter analyze：通过，No issues found。
- DSH_TEST_FONT_DIR=/usr/share/fonts/opentype/noto flutter test test/notify/pet_live_activity_test.dart test/notify/live_activity_test.dart：13 项通过。
- 首次测试未指定字体目录，因默认 /usr/share/fonts/noto-cjk 缺失而加载失败；使用现有字体目录重跑通过，未修改测试环境代码。
- git diff --check：通过。未跑全量测试。

## 尚未验证 / 限制

前两轮本机未编译 iOS Swift、未签名或验证设备。协调者随后报告裸 xcodebuild 通过、模拟器 request 和扩展渲染成功，但岛仍不可见；真机展示未验证。此轮仅在 Linux 复核与运行 Dart 检查。
沿用 ActivityKit 的系统授权、前台创建与活动生命周期限制；后台切换目标如需创建活动，会报告 pet_live_activity_requires_foreground，已有前台恢复监听会重发。用户主动划掉活动后仍沿用现有 dismissed 保护与关闭/重开实时更新的恢复方式。不能保证系统无限期保留活动。
会话完成/失败仍先遵循现有短暂状态；共享 reducer 不再提供会话活动时回退 idle。自定义宠物尚无独立 emoji 映射。Deepy/鲸娘美术授权仍未解决。

## Round 3 复核与诊断日志清理

未发现导致 SpringBoard 不展示岛的代码缺陷：ActivityConfiguration 注册正确，Runner 与扩展共用 Shared attributes 源码，扩展依赖/嵌入和 Info.plist 接线完整。packId 可选兼容旧内容；idle/label/staleLabel 有内容；compact/minimal 均有实际视图。pushType=nil 表示本地活动；staleDate=nil 不会结束活动；widgetURL(nil) 仅不指定点击深链，不控制可见性。

Dart 通道串行执行；Swift 仅在显式 end 或替换其他目标时结束活动，request 后没有 end。livePushProvider 随偏好、宠物、会话更新；即使 activity=null，只要 enabled=true 且仍选 Deepy，仍发送 idle，不发送 end。桥接销毁仅移除回调；前台恢复会再发当前状态。

协调者提供的证据为 request 成功、扩展渲染成功无 crash、后台仍无岛、截图始终无黑色外壳。判定倾向此模拟器的 SpringBoard 展示或截图环境限制；尚不能证明所有模拟器不支持或真机已经通过。此轮未访问 Mac，未重跑模拟器。

真机验收需要带灵动岛的 iPhone（iOS 16.2+）、签名且包含扩展的同版本 App，系统允许实时活动，应用内开启实时更新并选 Deepy。前台启动后切到主屏/其他 App，检查 compact、长按 expanded 和锁屏，再查会话接管/回到 idle、换宠物、关闭开关。记录机型、系统版本、安装版本和截图；若仍无岛，核对 ActivityKit 活动状态及 SpringBoard/WidgetKit 日志，started 不代表展示成功。

删除 round 2 全部临时 Dart/Swift 日志，保留原错误返回与状态上报。project.pbxproj 唯一 SWIFT_ACTIVE_COMPILATION_CONDITIONS=DEBUG 属于 RunnerTests；Runner/项目 Debug 未定义 Swift DEBUG，GCC_PREPROCESSOR_DEFINITIONS 的 DEBUG=1 是 C/ObjC 宏，不等同 Swift -D DEBUG。仓库内 xcconfig 也无该 Swift 条件，与协调者观察的 dylib 无日志字符串相符。未取得 Mac 的最终 swiftc 参数，不声称已检查；Linux 普通 flutter test 不编译 Runner Swift。选择删日志，不改构建配置，不留无效诊断分支。

参考 Apple 官方文档：[本地更新与 pushType](https://developer.apple.com/documentation/activitykit/activity/request(attributes:content:pushtype:style:))、[staleDate](https://developer.apple.com/documentation/activitykit/activitycontent/staledate)、[widgetURL](https://developer.apple.com/documentation/widgetkit/dynamicisland/widgeturl(_:))、[Xcode 编译设置](https://developer.apple.com/documentation/xcode/build-settings-reference)。
