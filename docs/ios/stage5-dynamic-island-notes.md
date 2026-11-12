# Stage 5 — Dynamic Island pet

Source implementation on `feature/ios-shellbox-dynamic-island`, based on
`f8ed85a7`. This Linux environment has no Flutter, Dart, Swift, macOS or Xcode.
**Nothing here has been compiled for iOS, displayed in a simulator, or proved on
an iPhone/iPad.** No Actions runs were triggered or queued. No commit/push,
signing, provisioning, IPA export or credentials were created.

## Implementation and reuse

Read the Stage 1 audit's pet section, `pet_state.dart`, `pet_mood.dart`,
`pet_signals.dart`, `pet_overlay_bridge.dart`, and the existing `PetStage`,
`PetPerch` and `PetSprite` implementation before adding the native presentation.

- Reused the global Dart reducer, `PetTarget` host/session identity, existing
  `liveActivityOf` / `LivePush` projection, notification master/live/done/failed
  switches, existing localized chip labels, and `ChatAlertsController.open`.
  The reducer, in-app sprite renderer, packs and animation timing are unchanged.
- Added `app/lib/notify/pet_live_activity.dart`: presentation mapping and a
  serialized MethodChannel queue. `live_activity_state.dart` selects it on iOS;
  other platforms keep the existing `dsh/notify` path. Native errors remain
  observable through `petLiveActivityStatusProvider` as `AsyncError`; they do not
  break the in-app pet. This stage does not add a settings/error UI.
- Added `Runner/PetLiveActivityPlugin.swift` for actual ActivityKit request,
  update and end calls on `dsh/pet_live_activity` (`start`, `update`, `end`).
  Start/update reconcile the system's current activity list, including across
  app restarts. Only one pet activity is retained; changing the reducer target
  ends the previous session's activity. Dart serializes calls, so an end cannot
  overtake an unfinished start. Return values describe native API operations,
  not proof that iOS rendered a view.
- Added shared `PetActivityAttributes.swift` and the SwiftUI/WidgetKit
  `PetLiveActivity` extension with lock-screen, compact leading/trailing,
  minimal and expanded presentations. States have distinct expression, color,
  symbol and text: Idle, Thinking, Working, WaitingApproval, Completed, Error.
  Juggling/sweeping/carrying map to Working; questions share WaitingApproval's
  visual but retain the existing localized question label. Terminal visibility
  and duration follow the existing Dart projection (including background-only
  completed/error presentation). Idle is a rendering state when the reducer
  is idle while a live projection exists; no perpetual idle activity is started
  without a live session. When `LivePush.activity` is null or disabled, end.
- Added URL scheme registration and scene URL handling. Both widget surfaces
  use `dshgo://pet-session?host=…&sessionId=…`; URLComponents encodes both values.
  Native code holds a cold-launch URL until Dart's `ready` handshake. Dart
  validates the host with the existing strict `petActionHost` parser and opens
  that host/session using the existing notification navigation action. This
  does not execute approvals or other actions. Flutter default deep-link route
  handling is disabled to avoid treating this URL as a Flutter route.
- Added PBX target, source membership, Runner dependency and extension embedding.
  Runner remains iOS 15.0; the extension is iOS 16.2, Swift 5.0. Extension version
  and build number come from Flutter's generated configuration. Both targets
  reference App Group entitlements for `group.io.github.ccch1mneyyy.dshApp`.
  The shared Codable attributes and ActivityKit deliver activity state to the
  extension; no duplicate preferences file or credentials are written to the
  group container. App Group setup is entitlements only, with no team/profile.
  The extension has an empty signing identity; future builds must still use
  `flutter build ios --no-codesign`. Build success is not established here.

## Fallback, lifecycle and privacy

ActivityKit availability is guarded at iOS/iPadOS 16.2 and system authorization
is checked before requesting an activity. Unsupported OS versions and disabled
activities produce named errors and leave the full in-app pet available.
There is no hardware-model guess or empty placeholder island. On a supported
system without Dynamic Island, WidgetKit uses the lock-screen presentation;
phase transitions to waiting/completed/error request an alert banner with the
same presentation. Banner/sound delivery is controlled by iOS. Older iPads
without Live Activity support fall back to the in-app pet.

Requests require the app to be foregrounded. A foreground return re-sends the
current projection, allowing a previously background-only request to start.
If a previously started target disappears or is ended/dismissed by iOS, it is
not recreated on each reducer tick: the user can change target or turn live
updates off and back on. This suppression is in memory and resets on app process
restart. It does not claim persistence across force-quit.

Each update has a five-minute stale date. Stale expanded/lock-screen content
shows the existing bilingual “Status unavailable” label; compact trailing shows
a clock warning symbol. This can also occur during a long unchanged run: there
is deliberately no heartbeat promising freshness. A subsequent state change or
foreground reconciliation updates it. OS expiry/removal is handled by querying
ActivityKit before the next operation.

Only phase, localized public status/stale labels, opaque host kind/id and
session id are transmitted. Conversation titles, prompts, approval details,
request tokens, host display names and connection credentials are excluded.
Identifiers remain present in the system-owned activity URL and attributes.

## Licensing and fidelity

**Deepy/鲸娘 and brand assets are not covered by the repository's AGPL-3.0.**
They may be used as-is to build, test and run this repository. Modified
redistribution requires renaming/replacing those assets or separate permission;
see `ASSETS.md`. No pet/brand asset was copied, modified or repackaged here.
The existing in-app packs remain as-is. The extension uses system cat emoji
expressions and SF Symbols, not Deepy/鲸娘 artwork. Consequently it does not
faithfully reproduce the in-app character, sprite animation, custom packs,
tiers, roaming, bubbles or drag interactions. Live Activity rendering is owned
by WidgetKit, not a Dart animation timer.

## Stubs and named errors

There are **no simulated Stage 5 start/update/end successes or unimplemented
Stage 5 methods**: the code calls ActivityKit. Uncompiled implementation is not
device verification. Failures use these channel error codes:

- `pet_live_activity_unsupported`
- `pet_live_activity_disabled`
- `pet_live_activity_invalid_arguments`
- `pet_live_activity_requires_foreground`
- `pet_live_activity_dismissed`
- `pet_live_activity_request_failed` (includes ActivityKit's actual error)

No APNs/background push delivery or background execution entitlement is added.
When iOS suspends Dart, new host events cannot be promised to reach the activity;
no remote-push operation is exposed or reported successful. Stage 3's unrelated
local runtime stubs remain unchanged: `shellbox_start_rootfs_unimplemented`,
`shellbox_stop_unimplemented`, `shellbox_restart_unimplemented`;
`RuntimePlatformCapabilities.shellBoxRuntime` remains false. Stage 4 remote mode,
Stage 6 native experience, and Android native sources were not changed.

## Validation and remaining proof

Executed on Linux:

- `python3 app/tool/ios_pet_project_check.py`: passed OpenStep project parsing,
  object references, target dependency/embed, shared source membership, all
  three configurations' entitlements/version/deployment/signing contracts,
  plist/XML parsing and source whitespace. This is a structural check, **not a
  Swift/Dart syntax check or an Xcode build**.
- `python3 app/tool/l10n_merge.py --check`: passed, 71 parts / 7328 keys.
- `python3 app/tool/guide_sync.py --check`: passed, 26 files.
- `git diff --check`: passed. `git diff --stat`, `git status --short` and changed
  path inspection: zero tracked changes under `app/android/`, no codex log files.
- Credential-pattern scan of all changed/new files and manual source review:
  no real keys/tokens/passwords found. Pattern matching is not a guarantee.

Added `app/test/notify/pet_live_activity_test.dart` for state mapping, private-data
exclusion, ordered start/update/end, and recovery after native errors.
**Not run:** `flutter analyze`, Flutter tests (including these new tests and
existing reducer/sprite tests), Dart formatting/analyzer, Swift compiler,
`flutter build ios --no-codesign`, Xcode and all simulator/device checks: the
required toolchains are absent. Installing optional Python syntax parsers in
`/tmp` failed because package-host DNS is unavailable; no dependencies were
added to this repository. `git fetch origin main` also failed opening read-only
`.git/FETCH_HEAD`; a follow-up `git status` confirmed the requested clean branch
and baseline. Work stayed directly on the requested branch.

A future **manually authorized** macOS run must format/analyze/test Dart, resolve
Pods, and build Runner plus the embedded extension using Xcode 26.0.1 / Flutter
3.47.7 with `--no-codesign`; check bundle versions, availability/weak linking,
Swift API signatures and entitlements. Do not infer compile success from the
Linux checks. No Actions verification was requested or started.

An authorized signed-device run must prove all six state visuals, compact /
minimal / expanded / lock-screen layouts, VoiceOver and localization, warm and
cold session taps (including encoded/non-ASCII ids and switching hosts),
notification switches, start/update/end ordering, system denial/re-enable,
user dismissal, process restart, stale/expired activity handling, and foreground
recovery. Test a Dynamic Island iPhone, an iPhone without it, supported iPad,
and iOS 15 fallback. Verify the full animated in-app pet still works and document
suspension/force-quit limits. No real-device behavior is claimed by this stage.
