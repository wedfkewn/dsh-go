# Stage 3: ShellBox channel and link wiring

This supersedes the Stage 1 state recorded in shellbox-integration-errors.md. Implementation only: no macOS compile, simulator or device execution occurred. No successful runtime start is claimed.

## Wired

`FlutterImplicitEngineDelegate.didInitializeImplicitFlutterEngine` retains Flutter's GeneratedPluginRegistrant call and registers the app-owned ShellBoxPlugin through the engine registry. Flutter still generates its own registrant. The plugin implements MethodChannel `dsh/shellbox`: `start`, `stop`, `restart`, `status`, without arguments. Dart forwards operations and preserves PlatformException codes; status decodes the native map and rejects unsupported/malformed responses. Android channels and providers are unchanged. RuntimePlatformCapabilities.shellBoxRuntime remains false; existing app consumers are not migrated to the incomplete lifecycle.

ShellBoxKernel.c includes runtime/shellbox/ShellBoxBridge.h and forwards to the pinned upstream functions:

- `mount_root(const struct fs_ops *fs, const char *source)` → integer result unchanged.
- `become_first_process(void)` → integer result unchanged.
- `pty_open_fake(struct tty_driver *driver)` → pointer unchanged, including upstream ERR_PTR (not a nullable-pointer error convention).

The wrappers are real compiled calls, not declaration replicas or fake success. They are intentionally not invoked by start: a directory tree is not a prepared payload, and becoming PID 1 changes thread-local kernel state and process signal handlers without an implemented teardown path. Filesystem selection (realfs/fakefs), fakefs metadata preparation, a persistent tty driver with callbacks, execution thread ownership, stdio, exec/Node/DSH launch, endpoint discovery and resource teardown remain unimplemented. The C primitives expose no boot-success API.

## Sandbox and operation results

`start` creates `Library/Application Support/ShellBox/rootfs/` with bin, dev/pts, etc, proc, root, sys, tmp, usr/bin, var/lib. Intermediate directories are created by NSFileManager. There are no downloaded files, fakefs database, ready marker or payload probes. This structure does not commit to a filesystem backend. Existing files are not replaced or deleted.

| Operation | Result |
|---|---|
| start | After directory creation: PlatformException `shellbox_start_rootfs_unimplemented` |
| scaffold I/O failure | PlatformException `shellbox_rootfs_scaffold_failed` |
| stop | PlatformException `shellbox_stop_unimplemented` |
| restart | PlatformException `shellbox_restart_unimplemented` |
| status | phase `unimplemented`, error code `shellbox_start_rootfs_unimplemented`; no readiness inferred from directories |
| unknown channel method | FlutterMethodNotImplemented |
| invalid native status | Dart PlatformException `shellbox_status_invalid_response` |

No operation reports running. Stop/restart do not pretend to kill an engine. Missing registration propagates MissingPluginException. Payload preparation is out of scope; a real device alone cannot supply the missing lifecycle implementation.

## Build paths

Flutter/Debug.xcconfig and Release.xcconfig include the appropriate optional CocoaPods configuration, Generated.xcconfig and ShellBox.xcconfig. Profile uses Release per template. ShellBox settings are scoped to Runner, not Pods.

- `SHELLBOX_SOURCE_ROOT = $(SRCROOT)/../../third_party/shellbox-src` (pinned checkout made by the existing workflow).
- `SHELLBOX_LIBS_ROOT = $(RUNNER_TEMP)/shellbox-ios-libs` (exact output root supplied by the existing workflow).
- Device: `$RUNNER_TEMP/shellbox-ios-libs/build-ios-arm64/{libish.a,libish_emu.a,libfakefs.a}`.
- arm64 simulator: `$RUNNER_TEMP/shellbox-ios-libs/build-iossim-arm64/{libish.a,libish_emu.a,libfakefs.a}`. No x86_64 libraries are produced.
- HEADER_SEARCH_PATHS: inherited, `$(SRCROOT)/../../runtime/shellbox`, source checkout root and SDK-selected build directory (generated headers).
- LIBRARY_SEARCH_PATHS: inherited plus SDK-selected build directory. ISH_INTERNAL=1 and GUEST_ARM64=1 match upstream embedding requirements.
- OTHER_LDFLAGS force-load all three archives and link sqlite3/zlib, preserving inherited flags. This makes native symbol resolution part of the build even while boot is disabled. No unresolved-symbol suppression.

For local Xcode builds supply SHELLBOX_LIBS_ROOT and optionally SHELLBOX_SOURCE_ROOT as build settings. Actions must prove RUNNER_TEMP expansion actually reaches xcodebuild and that all transitive native dependencies resolve. No workflow was changed or run.

## Verification

Passed on Linux: `git diff --check`; Python parsing of all plist/XML/JSON and PNG signatures/dimensions with asset-reference checks (31 files); PBX object references/unique IDs/source membership; no unresolved Mustache tokens; no hand-authored registrant; deployment/signing assertions; whitespace scan including untracked files; `bash -n runtime/shellbox/build-ios-libs.sh`; `python3 app/tool/l10n_merge.py --check` (71 parts, 7319 keys); `python3 app/tool/guide_sync.py --check` (26 files). These structural checks are not an Xcode parser or compiler.

Attempted `cc -fsyntax-only -DISH_INTERNAL=1 -DGUEST_ARM64=1 -I runtime/shellbox -I /data/workspace/shellbox-validation app/ios/Runner/ShellBoxKernel.c`: blocked by unavailable sqlite3.h in the upstream header dependency. No C compile pass claimed.

Runtime suite: `node --test runtime/tests/*.test.mjs` failed (30 passed, 142 failed); output included unset DSH_PREFIX and EROFS for the default /data/tmp directory. Repeated as `TMPDIR=/tmp node --test runtime/tests/*.test.mjs`: **41 passed, 131 failed**, including missing DSH_PREFIX/prepared patched runtime and unavailable @deepseek-ai/cordis. These are not iOS tests and no pass for this suite is claimed. Full retry output is at `/tmp/dsh-runtime-tests.txt`. No runtime source was changed to accommodate this environment.

Android checks: `git status --short -- app/android/`, `git diff --stat -- app/android/`, and `git diff --exit-code -- app/android/` are empty/successful: zero tracked Android changes. A credential-pattern scan of all 33 new/changed text files found no matches; new text was also reviewed for credential values. No codex logs are included.

Flutter analyze, Dart formatting, the new Flutter channel tests and iOS build: **not run**, Flutter/Dart/Swift/Ruby/Xcode absent. Channel tests cover native failure propagation, honest status and rejection of an unexpected running response; they need Flutter's matching desktop engine to execute.

Morning Actions must prove: Xcode 26.0.1/SDK selection, dependency resolution, actual Flutter analysis, CocoaPods/plugin integration, Swift registrar signature and Objective-C import, C header compatibility, arm64 archive selection, symbol resolution and unsigned Runner compilation. Run `cd app && flutter test test/runtime/shellbox_runtime_service_test.dart` separately if not part of the workflow. The workflow does not prove method dispatch, filesystem behavior or kernel execution on a device. Later device testing must exercise channel registration and named errors; payload and lifecycle implementation must precede any real startup claim. Node 24 and DSH remain unverified.

## Exact Stage 3 files

Changed relative to Stage 2:

- `app/ios/Flutter/Debug.xcconfig`
- `app/ios/Flutter/Release.xcconfig`
- `app/ios/Runner/AppDelegate.swift`
- `app/ios/Runner/Runner-Bridging-Header.h`
- `app/ios/Runner.xcodeproj/project.pbxproj`

Created:

- `app/ios/Flutter/ShellBox.xcconfig`
- `app/ios/Runner/ShellBoxKernel.c`
- `app/ios/Runner/ShellBoxKernel.h`
- `app/ios/Runner/ShellBoxPlugin.h`
- `app/ios/Runner/ShellBoxPlugin.m`

Dart and notes:

- `app/lib/runtime/shellbox/shellbox_runtime_service.dart`
- `app/test/runtime/shellbox_runtime_service_test.dart`
- `docs/ios/stage3-shellbox-wiring-notes.md`

Stage 2 baseline: `/tmp/dsh-ios-stage2.tar`. Stage 3 edits to shared files: `/tmp/dsh-ios-stage3-shared.patch`. The final Stage 3 overlay is `/tmp/dsh-ios-stage3.tar`. Coordinator can preserve the final tree, restore Stage 2 for commit 1, then restore the overlay for commit 2. No commits, pushes, fetches, signing, IPA export or Actions triggers were performed.
