# DSH Go iOS 灵动岛 / Live Activities 实现参考包

来源：https://github.com/wedfkewn/dsh-go/tree/5d583426aa0e6518462d30fd4733d80fec2c40c6 （1.1.1，2026-11-17）。

这是供上游 Issue 审阅的**精简源代码快照**，不是可独立构建的 App，不是针对上游 1.2.0 生成的补丁。保留原始路径，未附运行时 ZIP、完整宠物素材、私钥、签名证书或 IPA。共享文件保留原版以便定位，尤其 EngineChannel.swift、project.pbxproj、AppDelegate.swift、Info.plist 和 Dart 桥接文件可能含其他改动，请选择性移植而非直接覆盖。

## 移植入口
- app/ios/PetLiveActivity/：WidgetKit / ActivityKit 扩展，锁屏、紧凑、最小、展开态。
- app/ios/Shared/PetActivityAttributes.swift：共享状态与会话标识。
- app/ios/Runner/PetLiveActivityPlugin.swift：dsh/pet_live_activity MethodChannel、活动生命周期和状态体积约束；AppDelegate 注册。
- app/lib/notify/pet_live_activity*.dart、pet_art_stage.dart、app/lib/state/live_activity_state.dart：状态桥接、宠物帧生成与资源暂存。
- project.pbxproj：仅合并扩展 target、共享源、嵌入与签名配置相关段；不要替换整个工程。Runner Info.plist 加 NSSupportsLiveActivities，按实际 Team/Bundle ID 配置共享组（无可用 App Group 时参考内联静帧降级）。
- notify_state.dart、notification_settings.dart、continued_run.dart、runtime_bridge.dart、EngineChannel.swift、l10n/parts/live_*.arb：设置与后台任务开关相关改动。上游生成本地化文件需重新生成。

需要 iOS 16.2+；支持灵动岛的 iPhone 才显示岛，其他设备可显示锁屏活动。不依赖 APNs；系统暂停 App 时无法保证持续更新，不提供永久后台保活。请保留上游已有 Android/鸿蒙能力和共享代码。

验证：来源仓库更新日志记录 Xcode 27.2 Debug 模拟器编译、Flutter 静态检查通过；未完成真机签名、安装或完整功能验证。本参考包及上游 1.2.0 移植未重新编译，不声明真机兼容性。

许可证：遵循原仓库 LICENSE（AGPL-3.0）及 ASSETS.md 的素材授权限制；不重新分发宠物素材。原仓库及其贡献者保留署名。
