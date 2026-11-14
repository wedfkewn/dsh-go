# Stage 6: iOS native experience

Implementation in the existing `feature/ios-shellbox-dynamic-island` checkout,
starting at `77247b05`. No commit, push, signing, IPA export, workflow change or
GitHub Actions trigger. All conclusions below are source inspection or Linux
checks. **Nothing was compiled on macOS or exercised on an iOS device.**

## Implemented and reused

| Area | Stage 6 behavior and source |
| --- | --- |
| Safe areas and layout | Reused `MirroredSideInsets`, `SideSafeArea`, `AppPage` and chat's top/bottom safe areas. Reused `AdaptiveScaffold` session list / chat / details columns and width-based breakpoints (wide layout starts at 840 logical pixels); narrow iPad split views use the existing compact layout. Runner already declares phone/tablet landscape orientations and does not lock Flutter orientation. No Dynamic Island or widget changes. This is static coverage, not visual verification of every screen. |
| File/photo picking | Reused `file_picker` and `image_picker`, already invoked by attachment and customization UI. Added camera and photo-library usage descriptions to Runner Info.plist. Attachment photos use `requestFullMetadata: false` and read selected XFile bytes; document attachments read the picker-provided stream with existing byte limits. No native filesystem browser, arbitrary outside-sandbox path access, persistent security-scoped URL, or new entitlement. Provider file access/copy lifetime remains the plugin's responsibility and needs device testing. |
| Clipboard and share | Reused Flutter `Clipboard` read/write and existing paste affordances; no startup clipboard polling. Added `share_code/system_share.dart` and routed all existing `SharePlus.instance.share` call sites through it. It preserves share parameters and adds a nonzero center anchor in the current Flutter window on iOS, including split view. Runner supports one scene. Android calls retain the original parameters. Existing cache-backed exports retain their file-lifetime behavior. |
| Keyboard | Reused chat's `resizeToAvoidBottomInset: true`, composer bottom SafeArea, metric handling, and scrollable form/page scaffolds. No additional global keyboard padding that would double the existing inset. The new lock screen is safe-area-aware and scrollable; hidden content loses focus eligibility. No iOS keyboard interaction was tested. |
| Optional app lock | Added `local_auth: ^3.0.2`, a privacy-page switch shown only on iOS, persistent opt-in defaulting off, and a gate above Navigator. Enabling/disabling requires successful OS authentication and preference persistence. Biometric authentication allows the OS device-passcode fallback. Missing authentication capability prevents enabling; failures/cancellation retain the lock and offer retry. Backgrounding locks enabled instances; inactive content is covered for app switching and OS prompts. Authentication completing after a background transition cannot unlock/change preferences. Added Face ID usage description. A successful unlock is never synthesized. |
| Dark mode | Reused `ThemeMode.system` default, existing light/dark themes, and the user's explicit appearance override. New lock widgets use Theme colors/text. No forced iOS style or hard-coded light lock-screen background. |
| Notifications | Added `Runner/NotifyPlugin.swift`, the iOS implementation of the existing `dsh/notify` method/tap/action contract, registered with Runner and included in its source phase. It calls `UNUserNotificationCenter` directly through this project-owned plugin. Existing Flutter alert policy, preferences and host/session navigation are reused. Settings → Notifications → system-enable action requests permission if undetermined, otherwise opens app settings. Status reads do not prompt. Posts use only public notification text, group by conversation, and support cancellation. Taps route through the existing host/session checks, with a pending tap for cold-start scene delivery. Approval is answered in the foreground app. No new third-party notification dependency or Android build configuration is required. |
| Background restore | Reused SharedPreferences host-bound current-session restoration and saved host/connection configuration. Added an iOS HomeShell resume listener calling the existing session-list refresh, which retains an already-loaded list if refresh fails. The host remains authoritative and cold starts reload its list after reconnect. There is no new offline disk snapshot of session contents/list, no process-death restoration of arbitrary routes, and no new draft/attachment restoration guarantee. |

`local_auth` is the only new package declaration. Its upstream API documents
OS-passcode fallback and iOS setup:
https://pub.dev/packages/local_auth/versions/3.0.2 . The Flutter-maintained plugin
is BSD-3-Clause; the resolved transitive package licenses and final Pods still
need review after dependency resolution. Share anchoring follows the existing
share_plus API: https://pub.dev/documentation/share_plus/13.3.1/share_plus/ShareParams-class.html .
No native picker, clipboard or biometric reimplementation was added.

## Remaining limitations and named errors

- Local ShellBox execution remains stubbed. Existing native operation errors
  remain `shellbox_start_rootfs_unimplemented`, `shellbox_stop_unimplemented`,
  and `shellbox_restart_unimplemented`. Stage 6 does not claim a running local
  engine or local-session recovery on iOS.
- Shizuku/ADB, Android phone control, overlay windows, APK installation and
  foreground-service keep-alive remain known-incompatible, outside this stage.
  No replacement succeeds fictitiously. Existing Android-only save-to-Downloads
  and gallery channels were not ported; use the share sheet for export. A picker
  usage description does not implement saving media to Photos.
- Notification inline approval returns
  `ios_notification_inline_approval_unimplemented`. The Android live-notification
  methods return `ios_android_live_notification_unimplemented`; Stage 5's separate
  pet ActivityKit channel remains unchanged. `liveStatus` reports that this
  Android-style facility is unsupported, rather than representing ActivityKit.
- Native notification failures use `ios_notification_invalid_arguments`,
  `ios_notification_permission_failed`, `ios_notification_permission_denied`, or
  `ios_notification_delivery_failed`. The existing Dart `tryShow` contract returns
  false for platform errors; the existing best-effort `show`/cancel wrapper still
  absorbs platform exceptions. No delivery receipt or user-visible alert is
  claimed from a successful enqueue callback.
- Notifications can only be submitted when Flutter receives an event and can
  execute. A suspended/killed app does not receive ongoing remote events through
  this implementation. No APNs integration, background keep-alive, background
  Dart engine or Live Activity keep-alive abuse was added.
- App lock is a UI access gate, not encryption of existing app/host data. If device
  authentication becomes unavailable after opt-in, content stays covered; restore
  device authentication in iOS Settings and retry. There is no bypass button.
- Dependency resolution and generated Dart localization classes are pending:
  no Flutter/Dart SDK is present. `pubspec.lock` was deliberately not fabricated.
  New strings are bilingual ARB inputs; merged ARBs were generated by the existing
  tool. Tracked `l10n/gen` classes must be regenerated with Flutter before analysis
  or compilation; current generated classes do not yet contain the new getters.

## Linux checks actually run

- `git status --short --branch` and `git rev-parse --short HEAD`: requested branch,
  clean starting worktree, `77247b05`. `git fetch origin main` failed opening
  `.git/FETCH_HEAD` with a read-only-filesystem error; follow-up `git status`
  succeeded. Edits were made directly in this checkout, with no scratch clone.
- `python3 app/tool/l10n_merge.py --no-gen`: passed; merged bilingual inputs.
- `python3 app/tool/l10n_merge.py`: merged inputs, then **failed** because Flutter
  was absent. No generated Dart classes were hand-edited.
- `python3 app/tool/l10n_merge.py --check`: passed (72 parts, 7333 keys).
- `python3 -m unittest discover -s app/tool -p 'test_l10n*.py'`: 56 passed.
- `python3 app/tool/ios_pet_project_check.py`: passed OpenStep/PBX references,
  existing extension/signing contracts, plist/XML and whitespace checks. This
  does not compile Swift, link frameworks, or validate notification delegates.
- `python3 app/tool/guide_sync.py --check`: passed (26 files).
- `TMPDIR=/tmp node sdk/plugin-kit/scripts/sync-skill.mjs --check`: passed.
- `node --test runtime/tests/*.test.mjs`: failed (30 passed, 142 failed).
  Reran as `TMPDIR=/tmp node --test runtime/tests/*.test.mjs` after observing the
  default temporary directory was unwritable: 41 passed, 131 failed. Remaining
  failures include missing required `DSH_PREFIX`/patched runtime fixtures and
  missing runtime modules (for example `@deepseek-ai/cordis`). These tests do not
  establish iOS correctness. No runtime files were changed to mask failures.
- New `app/test/security/app_lock_test.dart` covers default-off behavior,
  rejected opt-in, persistence/reload, unavailable authentication, disable and
  a background/authentication race. **Not run:** no Flutter test runner.
- `TMPDIR=/tmp node --test sdk/plugin-kit/test/*.test.js`: incomplete/failed.
  The run reported a failure in `check-config.test.js`, then stopped producing
  output; interrupted with Ctrl-C after several minutes. An isolated rerun with
  `timeout 15s` also failed that file (one failed test). The SDK was not modified.
  An earlier `*.test.mjs` glob selected zero tests and provides no validation.
- `git diff --check`: passed. A supplemental Python check passed whitespace and
  relative Dart import checks across all 30 changed/new files and confirmed the
  new notification source is included in Runner. This is not a Dart/Swift parser.
- `git diff --stat -- app/android` and `git status --short -- app/android`: empty;
  zero tracked Android changes and no new Android files.
- Scanned all changed/new files for private keys, common provider token formats
  and long literal credential assignments; no matches. Also manually inspected
  the new source/configuration: no real credential values or signing material.
  No `codex-*.log` files were created in the checkout; test output stayed in /tmp.

## Required macOS and real-device proof

1. Run `flutter pub get` to resolve local_auth and update the lockfile; run
   `python3 app/tool/l10n_merge.py` from repository root, then Dart format,
   `flutter analyze` and `flutter test`. Resolve any compiler/analyzer findings;
   this Linux source inspection cannot replace them. Validate Android dependency
   compatibility as local_auth also has an Android implementation, despite being
   called only on iOS here. No Android source changes are included.
2. Install Pods and perform an unsigned iOS build on macOS/Xcode. Verify plugin
   registration, UNUserNotificationCenter delegate forwarding under the implicit
   Flutter engine/UIScene lifecycle, and existing widget target linkage unchanged.
3. On iPhone with a notch/Dynamic Island and on iPad, check portrait/landscape,
   small split-view widths and full-width list/detail columns, large text,
   home indicator, pushed pages, sheets and dialogs. Verify keyboard avoidance
   in chat and forms with docked, floating, hardware and predictive keyboards.
4. Pick/cancel Files and Photos, including iCloud downloads, limited/denied Photos
   access, large/HEIC images, camera denial, repeated imports and backgrounding
   during selection. Prove picker stream access stays valid within the sandbox.
5. Copy/paste text with iOS paste permissions and share images, diagnostics,
   artifacts, logs, conversations, cards, profiles and tavern exports. Confirm
   iPad popovers show inside the current split-view window and cancellation keeps
   usable files long enough. The center anchor is not a precise tapped-button anchor.
6. Test lock opt-in/off, Face ID and Touch ID where available, device-passcode
   fallback, cancellation, biometric lockout, unavailable enrollment, preference
   write failure, OS prompts, app-switcher snapshots, deep links/notification taps
   while locked, and backgrounding during authentication. Check no frame/content
   leak or keyboard interaction with hidden content; OS snapshot timing is unproven.
7. Test notification first grant/deny, settings changes and status refresh,
   public-text privacy, foreground presentation, grouping/replacement/cancellation,
   warm/cold scene taps and host selection. Confirm exactly one navigation for a
   cold-launch tap. Verify no promise of alerts while the app cannot execute.
8. Change system light/dark appearance while running and after suspension. Kill
   and relaunch with local/remote host selections; reconnect and prove server
   sessions and selected session remain intact. Test offline launch explicitly:
   there is no newly persisted offline session-list snapshot or full route restore.

## File manifest

Created/modified paths (including generator-produced merged ARBs):

- `app/ios/Runner.xcodeproj/project.pbxproj`
- `app/ios/Runner/AppDelegate.swift`
- `app/ios/Runner/Info.plist`
- `app/ios/Runner/NotifyPlugin.swift`
- `app/ios/Runner/SceneDelegate.swift`
- `app/lib/app.dart`
- `app/lib/diagnostics/diagnostics_export.dart`
- `app/lib/l10n/app_en.arb`
- `app/lib/l10n/app_zh.arb`
- `app/lib/l10n/parts/ios_en.arb`
- `app/lib/l10n/parts/ios_zh.arb`
- `app/lib/security/app_lock.dart`
- `app/lib/share_code/system_share.dart`
- `app/lib/state/artifact_files.dart`
- `app/lib/state/session_export.dart`
- `app/lib/ui/chat/media/media_card.dart`
- `app/lib/ui/chat/widgets/image_actions.dart`
- `app/lib/ui/engine/log_view.dart`
- `app/lib/ui/replay/conversation_out.dart`
- `app/lib/ui/settings/app_lock_widgets.dart`
- `app/lib/ui/settings/privacy_page.dart`
- `app/lib/ui/share/share_export.dart`
- `app/lib/ui/share_code/share_out.dart`
- `app/lib/ui/shell/home_shell.dart`
- `app/lib/ui/tavern/tavern_backup.dart`
- `app/lib/ui/tavern/tavern_chat_files.dart`
- `app/lib/ui/tavern/tavern_widgets.dart`
- `app/pubspec.yaml`
- `app/test/security/app_lock_test.dart`
- `docs/ios/stage6-native-experience-notes.md`
