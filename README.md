# iOS Dynamic Island / Pet Live Activity — upstream contribution reference

Source: https://github.com/wedfkewn/dsh-go/tree/5d583426aa0e6518462d30fd4733d80fec2c40c6 (v1.1.1). This deliberately reduced source snapshot is a review bundle, NOT a buildable Flutter project, NOT a merge-ready branch/PR, and NOT a replacement for upstream 1.2.0. Do not merge this branch wholesale. Shared integration files are full-file references; selectively port relevant hunks into upstream. Runtime download and platform pruning are not part of the proposed contribution; shared files may still contain unrelated modifications. No pet artwork, binaries, credentials, provisioning profiles or engine archives are intentionally included. Original upstream licensing and attribution remain unchanged; see LICENSE and ASSETS.md. Reuse existing upstream artwork under its applicable terms.

## Integration map
- Native: PetLiveActivity widget extension, Shared/PetActivityAttributes, Runner/PetLiveActivityPlugin, AppDelegate registration; merge target/signing/App Group/Info.plist changes selectively.
- Flutter: notify/pet_live_activity, pet_live_activity_art, pet_art_stage, state/live_activity_state, pet_overlay_bridge, shared live activity reducer and channel.
- Settings/background: notify_state, notification_settings, continued_run, runtime_bridge, EngineChannel, ContinuedRun, live localization parts. Distinguish ActivityKit display (iOS 16.2+) from BGContinuedProcessingTask (iOS 26+); neither guarantees indefinite background execution.
- Tests: two existing focused Dart tests included as references; re-run against upstream before merging. Original source changelog reports Debug simulator build and Flutter analysis passed; this exported subset was not compiled or device-tested. Real device signing / Live Activity behavior remain to be verified.

## Files
- LICENSE
- ASSETS.md
- app/ios/PetLiveActivity/PetLiveActivity.swift
- app/ios/PetLiveActivity/Info.plist
- app/ios/PetLiveActivity/PetLiveActivity.entitlements
- app/ios/Shared/PetActivityAttributes.swift
- app/ios/Runner/PetLiveActivityPlugin.swift
- app/lib/notify/pet_live_activity.dart
- app/lib/notify/pet_live_activity_art.dart
- app/lib/notify/pet_art_stage.dart
- app/lib/state/live_activity_state.dart
- app/test/notify/pet_live_activity_test.dart
- app/ios/Runner/AppDelegate.swift
- app/ios/Runner/Info.plist
- app/ios/Runner/Runner.entitlements
- app/ios/Runner.xcodeproj/project.pbxproj
- app/lib/notify/live_activity.dart
- app/lib/notify/notify_channel.dart
- app/lib/pets/pet_overlay_bridge.dart
- app/lib/state/notify_state.dart
- app/lib/runtime/continued_run.dart
- app/lib/runtime/runtime_bridge.dart
- app/ios/Runner/ContinuedRun.swift
- app/ios/Runner/EngineChannel.swift
- app/lib/ui/settings/notification_settings.dart
- app/lib/l10n/parts/live_en.arb
- app/lib/l10n/parts/live_zh.arb
- app/test/notify/pet_live_activity_art_test.dart

Full original implementation: https://github.com/wedfkewn/dsh-go/tree/5d583426aa0e6518462d30fd4733d80fec2c40c6
