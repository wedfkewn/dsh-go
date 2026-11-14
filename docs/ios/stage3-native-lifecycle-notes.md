# Stage 3 native lifecycle: incomplete implementation

This change does **not** implement a working ShellBox lifecycle. No guest is
mounted, booted or killed. Compilation is unverified on this Linux machine;
there is no Xcode/macOS, simulator or attached iOS device. No dependencies,
workflows, signing, IPA, Android, l10n or Dart bridge files changed. No commit,
push or Actions run was performed. The supplied branch is
`feature/ios-shellbox-dynamic-island`, baseline `ce7b0327`. Fetching origin main
failed because `.git/FETCH_HEAD` is read-only; the supplied checkout was retained.

## Changes that work at the channel implementation level

`ShellBoxPlugin.m` now reports `notInstalled` initially and `error` with a stable
named error after a failed lifecycle request. Empty directories are never
installation evidence. No versions, endpoint or token are invented.

`install` and `reset` have explicit native handlers returning
`shellbox_install_unimplemented` and `shellbox_reset_unimplemented`. They do not
modify data, regardless of `dropKept` or `keep`. `start` retains
`shellbox_start_rootfs_unimplemented`; stop/restart retain their named errors.
The former start-time directory scaffold was removed: it was neither installation
nor boot. These operations are still unimplemented, not successful no-ops.

`logs` and `logSnapshot` return the native diagnostic tail with the contracted
shapes. The buffer holds 2000 entries, with process-lifetime sequence numbers
shared across plugin registrations. `lines: 0` returns no entries while retaining
the current watermark. Counts are bounded to 2000; negative, fractional, boolean,
non-finite and nonnumeric values are rejected. Missing lines use 500/300.
All access is on the platform thread. Only fixed system diagnostics are recorded;
arguments, environment values and raw NSError descriptions never enter the ring.
There is no guest stdout/stderr source or general guest-output redactor yet.
Thus log retrieval is partial against the requested guest-stdio requirement.
Do not attach guest output to this buffer until redaction is implemented.

## Investigation and remaining implementation

Evidence is the local pinned ShellBox checkout
`/data/workspace/shellbox-validation` at
`5dfc962fe5e03fe5bc6b869b8744312ebe6af627`, the Android runtime sources named
in the task, `runtime/build-runtime.sh`, and the existing validation/wiring notes.
These are source observations, not execution results.

### Rootfs source and installation

There is currently **no iOS rootfs payload source** in the Runner bundle or an
iOS download manifest. Linking libish does not bundle a Linux root filesystem
or Node. Android's `RuntimeManifest` and `RuntimeInstaller` consume
`assets/runtime/manifest.json`, verify archive hashes, stage extraction and
activate versioned payloads; those Gradle assets are not iOS bundle resources.
The old iOS scaffold contains no payload or installation marker.

A concrete remaining approach is to build a dedicated arm64 Ubuntu/glibc guest
payload from the pinned inputs in `runtime/build-runtime.sh`, bundle its archive
and version/hash manifest as Runner resources, and import into staging before
atomic activation. This is a proposed delivery approach, not an implemented
bundle path or download URL. An installer must preserve Linux mode/uid/gid,
symlinks and device metadata. ShellBox `tools/fakefs.c` supplies import/export
code using libarchive; it is not made available merely by the current
libish/libish_emu/libfakefs link flags. Check build membership before adopting
it; adding libarchive would be a dependency change. No dependency was added here.

Upstream `xX_main_Xx.h` selects realfs with `-r` or fakefs with `-f`; fakefs mounts
`<root>/data` with metadata alongside it. For realfs, `/dev` still needs its own
fakefs because iOS cannot create real host device nodes. A full fakefs root is
the intended remaining approach. `benchmark/create_fakefs.py` demonstrates
inode-based metadata, but copying its generated database onto another filesystem
is not a verified installer. Use an importer/rebuild that handles destination
inodes and archive metadata. None of this is implemented by directory creation.

Reset must first complete teardown, preserve the selected guest paths and their
fakefs metadata, then retire the installation. Match Android `ResetKeep` groups
and restore kept paths on install. `dropKept` permits abandoning a failed restore,
not blindly deleting data before a replacement payload is ready. Both reset and
install intentionally fail before mutation today.

### Node 24 and DSH

The existing validation finds Node 22-specific V8 workarounds and binary-address
assumptions; it does not establish Node 24 compatibility. DSH requires
`>=24.9.0`; substituting Node 22 violates that contract. A linux-arm64 Node 24
binary can be placed in a glibc guest rootfs by a build-time assembler (the
Android builder already pins Node 24.22.1 and its arm64 archive hash). Placement
is not proof it executes correctly under ShellBox. An Alpine/musl rootfs cannot
be assumed to run that glibc binary.

The proposed delivery is **bundled at build time**, together with the guest
loader/libraries, rather than npm/network installation during native `install`.
No such iOS bundle is implemented. First verify Node 24 under the pinned kernel:
version, asserted JS results, module loading, crypto, fetch/network, worker and
subprocess behavior used by DSH, and sustained HTTP serving. Exit code zero alone
is insufficient given the upstream V8 fatal-error handling described in
`shellbox-validation.md`. Binary-specific patches may need updating.

DSH also has no iOS guest payload today. Assemble the locked npm dependency tree,
repository runtime patches, bridge and managed assets at build time as the
Android builder does (`install_dsh`, `patch-dsh`, `assemble`). Do not download an
unpinned npm package or reuse Android's proot launcher inside ShellBox. Launch
the prepared guest Node/DSH with `dsh web --host 127.0.0.1 --port <port> --no-open`,
the appropriate guest HOME/PATH/DSH configuration and working directory from the
assembled launch specification. Map env/mode/visualReplies/phoneStorage only when
the corresponding guest setup exists; do not silently discard those arguments
and claim startup succeeded.

### Thread ownership, stdio and endpoint discovery

`main.c` is a CLI entry point, not an embedding API. It installs host signal
handlers, calls `xX_main_Xx`, mounts proc/devpts and runs `task_run_current`.
`xX_main_Xx.h` mounts the root, creates PID 1, sets `current->thread`, prepares
devices, cwd, argv/env and `do_execve`, then stdio. Its failure cleanup is not a
Runner lifecycle. `platform/darwin.c` supplies host metrics, not boot or teardown.

A remaining native owner must perform kernel operations on an owned pthread,
retain the tty driver and callbacks through final task exit, and frame separate
stdout/stderr streams. Do not redirect Runner's global stdout/stderr or use
`create_piped_stdio` as if it supplied isolated host pipes. Redact credential
assignments, token URLs, authorization/cookie headers and multiline private keys
before buffering. Parse readiness privately before redaction; retain the token
only as runtime state. Neither stdio nor readiness discovery is implemented.

ShellBox `fs/sock.c:sys_bind` calls host `bind(sock->real_fd, ...)`;
`sys_connect` likewise uses host sockets. Guest loopback should therefore be
reachable as iOS loopback without a proxy or VM port forward. This is an
inference from source that requires simulator and device verification. Mirror
Android's token URL parsing and bounded readiness wait, then verify the actual
DSH HTTP response/authentication from iOS before reporting running. A token line
or a listening port alone must not be used as proof that DSH serves requests.

### Shutdown is an embedding blocker

`kernel/exit.c:do_exit` calls `exit_hook` when PID 1 dies, then calls
`halt_system`. That function signals other tasks, may send host SIGTERM to their
threads, attempts unmounts, invokes CLI diagnostic functions and calls `_exit(0)`.
It terminates Runner. A returning exit_hook does not intercept shutdown. Calling
pthread_exit from that hook would bypass the cleanup and does not implement
reusable kernel state. The existing three C wrappers supply no shutdown API.

A proper remaining solution needs a pinned upstream embedding change (or a
reviewed embedding implementation) that terminates guest tasks without host
process exit, waits for all task threads, releases fds, tty, mounts and memory,
and defines reuse of PID/global kernel state. An owner must join the worker and
finish cleanup on every failed boot as well as stop. Deliver guest signals via
kernel task APIs, not host kill with a guest PID; pthread_cancel is not cleanup.
Keep process-global signal handler ownership explicit. Verify repeated boots,
child processes, blocked I/O, failed exec and failed mount. Only after this exists
can stop succeed and restart implement stop followed by the previous launch.
No guest process or kernel thread is created or released by this change.

## Exact cloud Mac checks

Use the existing macOS arm64 build environment and installed Flutter/CocoaPods.
From the repository root with the pinned checkout at `third_party/shellbox-src`:

```bash
export RUNNER_TEMP="${RUNNER_TEMP:-/tmp/dsh-shellbox-mac}"
mkdir -p "$RUNNER_TEMP"
bash runtime/shellbox/build-ios-libs.sh third_party/shellbox-src "$RUNNER_TEMP/shellbox-ios-libs"
cd app
flutter pub get
flutter build ios --no-codesign
xcodebuild -workspace ios/Runner.xcworkspace -scheme Runner -configuration Debug -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
```

The source checkout must be exactly the pin above. The build script requires a
fresh build output directory. Check actual compile/link output, including
ShellBoxPlugin.m, force-loaded archives, generated headers and arm64 simulator
selection. No x86_64 simulator support is claimed. These commands build locally;
do not trigger Actions as a substitute. Use `flutter devices`, then
`flutter run -d <arm64-simulator-id>` to exercise the debug build. Device execution
requires the maintainer's existing signing setup; this change adds none.

In a debug channel test or debug harness invoke
`const MethodChannel('dsh/shellbox')` with the following calls:

1. `status` before mutation: `phase: notInstalled`, no token/baseUrl/version.
2. `logSnapshot`, `{lines: 0}`: empty entries and current throughSeq (zero in a
   fresh process). `logs`, `{lines: 500}`: empty in that fresh process.
3. `install` with null, then `{dropKept: true}`: named install error; no files
   deleted or installation marker created. `status`: error and same code.
4. `start` with `{env: {}, phoneStorage: false, mode: null, visualReplies: true}`:
   `shellbox_start_rootfs_unimplemented`, no directory scaffolding or boot.
5. `stop` and `restart` with null: their named errors, Runner remains alive.
6. `reset` with `{keep: []}`, then each keep group and both groups:
   `shellbox_reset_unimplemented`, existing sandbox data unchanged.
7. `logs` and `logSnapshot`, `{lines: 2000}`: matching fixed system messages,
   increasing sequences; `{lines: 0}` keeps throughSeq despite empty entries.
   Exercise more than 2000 failed calls to verify bounded eviction and a
   watermark greater than the retained count. Negative/fractional/string/bool
   lines should fail with `shellbox_invalid_arguments`.
8. Pass a synthetic secret in start env and ensure neither logs nor status echo
   it. Re-register a Flutter engine in the same process: sequence must continue.

These tests validate the partial channel implementation only. After payload and
embedding work, repeat on a real device: install offline, corrupted/interrupted
install, keep/restore and dropKept, Node 24 assertions, DSH authentication over
loopback, redaction across stdio chunks, long-running requests, stop during boot,
child cleanup, repeated stop/start/restart and application background/foreground.
A successful Mac build cannot validate these runtime behaviors.

## Per-operation status

| Operation | Status | Remaining gap and verification |
| --- | --- | --- |
| status | partial | Correct absence/error state; installed/starting/running/stopping require real lifecycle. Mac build, simulator channel tests, then real device transitions. |
| start | still unimplemented | No payload/importer, verified Node 24/DSH, stdio/endpoint discovery or safe kernel owner. Mac build plus simulator and real device serving/auth tests. |
| stop | still unimplemented | Embedded shutdown must avoid upstream host exit and join/release all tasks/resources. Mac build and repeated simulator/device teardown. |
| restart | still unimplemented | Needs completed stop, saved launch arguments and new boot. Simulator and real device repetition/failure tests. |
| install | still unimplemented | Needs iOS payload manifest/delivery, integrity check, fakefs import and activation/kept restore. Mac build, simulator fault tests, real device install. |
| reset | still unimplemented | Needs teardown and metadata-aware keep/retire/restore semantics. Simulator fault tests and real device data preservation. |
| logs | partial | Native fixed diagnostic ring works in source; guest stdio framing/redaction absent. Mac build and simulator channel tests; device guest-output tests after boot implementation. |
| logSnapshot | partial | Native ring/watermark implemented in source; guest ingestion absent. Mac build, simulator sequence/eviction tests and device stdio tests. |
