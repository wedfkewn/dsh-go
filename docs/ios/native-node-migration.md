# iOS native Node runtime migration (Phase 1: fail-closed boundary)

Status: **scaffold only; NOT a runnable DSH engine**. This branch does not
replace or uninstall ShellBox. It must not be described as having fixed the
reported ESM URL or DeepSeek guest-network failures.

## Architecture decision

Keep the existing Flutter UI and its authenticated DSH HTTP client. Add a
separate iOS native Node backend inspired by the **approach**, not copied source,
of [Fish Pocket](https://github.com/imsai-sh/fish-pocket):

Flutter UI -> RuntimeBridge (existing) -> dsh/native_node (new) -> NodeMobile
(iOS Mach-O XCFramework) -> DSH engine worker -> loopback HTTP.

Fish Pocket uses a native Node framework, in-process worker threads for Node
commands, just-bash for shell command execution, native linked libraries for
Git/Python/FFmpeg, and an iOS filesystem view. Those are separate adaptations,
not features obtained by embedding NodeMobile alone.

The existing ShellBox path remains:

Flutter UI -> dsh/shellbox -> ShellBox Linux syscall emulator -> Ubuntu ARM64
-> Linux Node 24.22.3 -> DSH.

The two runtimes **cannot share executable binaries or fakefs metadata**.
No in-place conversion of ShellBox/active/data or its meta.db is permitted.
Workspace export/import and plugin migration need an explicit, reversible step.

## Phase 1 implemented on this branch

- iOS registers a separate MethodChannel "dsh/native_node" that reports
  "unimplemented" / "native_node_unavailable" until a real engine is linked.
  All lifecycle operations reject; no simulated success.
- The Dart NativeNodeRuntimeService enforces phase/error types and requires
  an authenticated localhost endpoint before accepting a "running" status.
- Dedicated mock-channel tests check fail-closed semantics and compatibility
  with the LocalRuntimeService phase contract.
- RuntimePlatformCapabilities.nativeNodeRuntime is **false**. The current
  runtimeBridgeProvider still selects ShellBox on iOS. Existing behavior,
  users' guest data, background tasks and Live Activities stay untouched.

No iOS compile, Flutter analyze/test, NodeMobile link or phone test has been
run from this environment. A documented test is not a validation result.

## Phase 2: native engine implementation (not done)

1. Pin and verify a redistributable NodeMobile iOS XCFramework version, build
   for iphoneos and iphonesimulator, embed/sign it in Runner. Confirm the actual
   V8 flags and supported Node APIs on device; do not substitute Linux Node.
2. Package DSH dependencies and JavaScript assets in the signed app bundle.
   No runtime download or execution of unsigned native code or arbitrary
   native .node addons. Inventory native deps and replace them selectively.
3. Start Node once per App process on a dedicated native thread. Place the DSH
   worker and restart handler inside that process. Never treat worker exit as
   proof that the Node process can safely restart; use generation IDs.
4. Expose a localhost HTTP URL only after a successful auth-token round trip.
   Return "running" only on verified readiness; on failure expose actionable,
   redacted startup diagnostics with a bounded timeout.
5. Map subprocess commands into an iOS execution world: JS worker threads,
   just-bash (where semantics are sufficient), and verified linked native
   capabilities. Do not claim general Linux binary compatibility.
6. Use App-container files with checked path mapping and atomic deployment.
   Isolate iOS workspace/config from ShellBox's fakefs; export user data and
   restore with an explicit confirmation flow.
7. Check all model providers using native iOS network paths and real calls.
   An unauthenticated /models HTTP 401 demonstrates reachability only.
8. Preserve authorization boundaries: tool approval, workspace restrictions,
   credential handling, redaction and safe mode. Match the existing Flutter
   bridge API including logs, status and cancel operations before selecting it.

## Phase 3: gated adoption (not done)

- Introduce backend selection *only after* Phase 2 passes. Default to
  ShellBox until the native backend has been fully tested.
- Integrate with RuntimeBridge, lifecycle tags, sessions, logs, reset/install,
  startup diagnostics, provider settings and reconnection.
- Do not automatically start both backends; they must own separate workspaces,
  ports, tokens and process/session lifecycles.
- Keep background execution best-effort under iOS policy. A native runtime
  does not guarantee unlimited background CPU/network execution.
- Test device foreground/background, network switching, locked screen, crash,
  StopBlocked regression, launch reuse, repeated starts/stops and data recovery.

## First Mac verification commands

Run in the repository checkout with Flutter and Xcode installed:

    cd app
    flutter pub get
    dart format --output=none --set-exit-if-changed lib/runtime/native_node test/runtime/native_node_runtime_service_test.dart
    flutter test test/runtime/native_node_runtime_service_test.dart
    flutter test test/runtime/shellbox_runtime_service_test.dart
    flutter analyze
    flutter build ios --debug --no-codesign

Expected Phase 1 behavior: native Node status is unimplemented and every
operation fails explicitly; existing ShellBox starts exactly as before.

Source comparison: Fish Pocket README section "How it works",
app/DshIOS/NodeEngine.swift, engine/runtime/child-process.mjs and
engine/runtime/shell.mjs. Implementation and licensing must be reviewed before
importing third-party source, binaries or assets.
