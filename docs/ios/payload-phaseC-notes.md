# Phase C: verified installer; embedded lifecycle still blocked

This is a **partial Phase C**, not a completed local runtime. Baseline verified
with `git rev-parse HEAD`: `10e20b32339349102c662b755e42109622577315`, branch
`feature/ios-shellbox-dynamic-island`, initially clean. `git fetch origin main`
failed because `.git/FETCH_HEAD` is read-only. No branch creation, commit, push,
Android, workflow, onboarding or signing change was made.

## Implemented

- `app/ios/Runner/ShellBoxPlugin.m:25`: resolve the original archive filename and
  `MANIFEST.json` from `NSBundle.mainBundle`, never the manifest's historical
  absolute paths. Validate manifest shape and stream the entire archive through
  CommonCrypto SHA256, checking both digest and byte count before mutation.
- `app/ios/Runner/ShellBoxPlugin.m:89`: same-hash installation is idempotent.
  Existing different-hash installations return `shellbox_upgrade_requires_reset`;
  unrecognized active trees return `shellbox_installation_invalid`. Neither is
  deleted. No upgrade or keep-data restore is claimed.
- `app/ios/Runner/ShellBoxPlugin.m:98`: import to a unique sibling staging tree
  using a real `fakefs_import` call. The upstream importer stores Linux mode,
  uid/gid and rdev in `meta.db`, represents symlinks as fakefs data, and preserves
  hardlink relationships. This does not use a host tar extractor or host copies
  of guest user directories. Write an installation marker inside staging, then
  move the entire tree to `Application Support/ShellBox/active`. Same-parent
  directory publication keeps the marker and fakefs database together. Errors
  clean only that attempt's staging and return stable named codes.
- `app/ios/Runner/ShellBoxPlugin.m:145`: status now reports installing/installed
  from the operation/committed marker. It does not claim guest Node/DSH versions,
  endpoint or token. Install completes asynchronously, with replies on main.
  The process-global install flag prevents overlapping imports across Flutter
  engines; main sets it before dispatch and clears it on worker completion.
- `runtime/shellbox/fix-fakefs-import-cleanup.patch:1`: the upstream CLI importer
  returned directly on failure, leaking live database/archive/fd resources.
  Import now unwinds through one cleanup path, finalizes outstanding statements,
  rolls back errors and closes resources. Export remains unchanged. Archive
  close is checked before commit. This is a local modification of pinned
  ShellBox `tools/fakefs.c`; existing third-party license/notice applies.
- `runtime/shellbox/build-ios-libs.sh:21`: apply the cleanup patch using the same
  apply-or-reverse-check mechanism as the two existing patches. Pin unchanged.

The importer reference is reachable from the registered plugin and retains its
archive dependencies through normal linking. No new `-u` flag is needed for
import. Dead-code stripping stays enabled. **Guest boot is not called**; keeping
boot symbols alive would not implement a lifecycle.

Power loss/process death can leave an unactivated `prepare-*` tree. It is never
recognized as installed; the next attempt uses a fresh tree. Automatic orphan
reclamation and power-loss durability beyond the directory publication are not
implemented. A failed cleanup reports `shellbox_install_cleanup_failed` rather
than silently claiming the staging was removed. These leftovers can consume
storage and must be inspected before manual deletion.

`dropKept` does not delete anything: no kept archive exists in this implementation.
Reset still refuses before mutation for every keep selection, including empty.

## Shutdown evidence and design boundary

Inspected local source `/data/workspace/shellbox-validation`, pinned
`5dfc962fe5e03fe5bc6b869b8744312ebe6af627`:

- `kernel/exit.c:141` takes `pids_lock`; `:191` invokes the PID 1 exit hook,
  then `:193` calls `halt_system`. Returning from the hook cannot intercept it;
  exiting the pthread there strands the lock and skips teardown.
- `kernel/exit.c:510` shutdown sends guest signals, then `:526` sends host
  `SIGTERM` to task pthreads. Host signals are process dispositions, so merely
  replacing the final `_exit(0)` at `:577` does not protect Runner.
- `kernel/exit.c:420` explicitly accepts stuck host threads and removes them
  from the guest thread list; `:452` and `:472` defer mm/fd release until those
  threads eventually leave their blocked syscalls. An empty guest list therefore
  is not evidence of host-thread quiescence or reusable kernel state.
- `kernel/task.c:252` creates detached pthreads. The primitives exposed by
  `ShellBoxKernel.c` do not join them, reset the global PID/mount/tty state, or
  interrupt every blocking host syscall.

These are concrete counterexamples to a safe **wrapper-only** stop/restart.
They do not prove that an upstream embedding redesign is impossible. Such a
redesign remains unimplemented here. It needs tracked host-thread completion,
interruptible guest-owned I/O, guest-only termination without process signals,
PID 1 teardown outside the held PID lock, and a defined cleanup/reset of kernel
globals before another boot. It must also handle failed exec and spontaneous
PID 1 exit, not only a user stop request. Replacing `_exit`, `pthread_exit` from
an exit hook, host `kill`, or `pthread_cancel` is insufficient.

Accordingly start returns `shellbox_start_shutdown_unavailable`, stop/restart
retain `shellbox_stop_unimplemented` / `shellbox_restart_unimplemented`. Runner
never boots an unsafe kernel in this change. **Start, real readiness/auth,
Node/DSH version probes, restart and reset keep-list preservation are unfinished.**
No versions, endpoints or tokens are fabricated. The diagnostic ring retains
2000 entries and its process-lifetime sequence/watermark semantics. Only fixed
messages enter it; real guest stdout/stderr framing/redaction remains unfinished
because no guest starts. Arguments, env and raw native error text are not logged.

## Validation performed on Linux

- `bash -n runtime/shellbox/build-ios-libs.sh`: passed.
- `git diff --check`: passed.
- Python JSON parsing plus independent streamed archive SHA256/size comparison:
  passed (`218112716` bytes,
  `b55564360f41aa14ddd57a9807771ae06de0ca7961ec33fdc9d0d4597d72ac65`).
- On temporary copies of pinned upstream files, each of the three patches passed
  `git apply --check`, apply and `git apply --reverse --check`; all three also
  passed the second-build reverse checks together. Actual Meson/CMake reruns
  require Mac.
- Flutter/Dart unavailable: channel unit tests **not run**. No tracked
  `integration_test/shellbox_channel_test.dart` exists in this checkout; the
  coordinator must supply/locate its integration harness. Existing Dart files
  and tests were not changed.
- No Apple SDK/compiler, libarchive/sqlite development headers or Flutter here:
  no Objective-C/C compile, iOS link, fakefs execution, simulator or real-device
  verification is claimed.

## Exact coordinator Mac commands

Use the existing pinned source and Phase A payload, no signing:

```bash
export RUNNER_TEMP="${RUNNER_TEMP:-$TMPDIR/dsh-phaseC}"
mkdir -p "$RUNNER_TEMP"
git -C third_party/shellbox-src rev-parse HEAD
bash runtime/shellbox/build-ios-libs.sh third_party/shellbox-src "$RUNNER_TEMP/shellbox-ios-libs"
bash runtime/shellbox/build-ios-libs.sh third_party/shellbox-src "$RUNNER_TEMP/shellbox-ios-libs"
(cd app && flutter pub get && flutter test test/runtime/shellbox_runtime_service_test.dart)
(cd app && flutter build ios --debug --no-codesign)
(cd app && flutter build ios --simulator --debug)
for SDK in ios-arm64 iossim-arm64; do
  xcrun nm -g "$RUNNER_TEMP/shellbox-ios-libs/build-$SDK/libfakefs_tools.a" | grep fakefs_import
done
xcrun nm app/build/ios/iphonesimulator/Runner.app/Runner | grep fakefs_import
xcrun otool -L app/build/ios/iphonesimulator/Runner.app/Runner
```

Require both build-script runs and unsigned builds to succeed. Inspect the actual
link map (Debug dylib too if Xcode enables it) for a retained importer and static
libarchive dependencies; `nm` on a stripped binary alone is not conclusive.
No global dead-strip override is requested.

Use `flutter devices`, then `cd app && flutter run -d <arm64-simulator-id>` with
the coordinator's native channel harness. Required observations:

1. Fresh status notInstalled. Invoke install and poll status while pending:
   installing, then installed only after successful completion. Restart Runner;
   status remains installed. No Node/DSH versions, URL or token appears.
2. Inspect the simulator container using
   `xcrun simctl get_app_container <simulator-id> <bundle-id> data`.
   Under `Library/Application Support/ShellBox/active`, require `data`, `meta.db`
   and `installed.plist`. Compare fakefs metadata/content for representative
   root-owned files, executable Node, links and `/dev` entries against the tar.
3. Repeat install; modify a guest data file between calls and verify it survives.
   Start a second concurrent install: require `shellbox_busy`. Re-register a
   Flutter engine during import and check the same exclusion.
4. In a disposable unsigned test bundle, corrupt or omit archive/manifest before
   installing that bundle. Require the named missing/manifest/integrity error,
   no new active tree, and unchanged existing active content. Exercise low disk,
   failed import, marker write and activation failure; inspect resource counts
   across repeated failures and check old data remains untouched.
5. Terminate Runner during import and relaunch: no partial tree is installed;
   retry can complete. Inspect/document orphan staging storage separately.
6. Start/stop/restart/reset return the documented errors and Runner stays alive.
   Reset with each keep group, both groups and empty keep changes no data.
7. Verify logs/snapshot shapes, lines zero, 2000-entry eviction, monotonic seq
   across failures and plugin registrations. Pass synthetic secrets through env;
   none may appear in logs, error text or status.

Real-device offline import/storage and metadata validation remain necessary.
These checks cannot establish full lifecycle acceptance: safe kernel teardown,
real serving/authentication, guest stdio redaction and metadata-aware reset must
be implemented and tested before Phase C is considered complete.

## Follow-up investigation (2026-11-12): incomplete, not an impossibility proof

**This follow-up does not meet either requested completion condition.** No safe
embedded lifecycle was implemented, and no proof that a source-level redesign
is impossible was obtained. “证实无法实现” would overstate the evidence. The
counterexamples below establish that the current implementation and local
wrapper changes are insufficient; they do not rule out replacing the relevant
kernel subsystems. No experimental shutdown patch is shipped as working code.

The starting branch and HEAD were verified as stated above. The four existing
modified/untracked files were read and preserved. Fetch was attempted again and
failed with `cannot open '.git/FETCH_HEAD': Read-only file system`. This follow-up
changes only this note. No Dart, native lifecycle, pinned source, build script,
Android, workflow, onboarding or signing changes were made; no commit or push.

### Additional source evidence

All upstream references below are to the verified pinned commit
`5dfc962fe5e03fe5bc6b869b8744312ebe6af627` in
`/data/workspace/shellbox-validation`. The prior exit.c/task.c line references
were checked against those files, rather than accepted from the previous note.

- `kernel/signal.c:61-91`: even `deliver_signal` uses host `pthread_kill` with
  `SIGUSR1` to wake another task. Removing only halt_system's host SIGTERM does
  not create signal-free guest shutdown. The condition-variable broadcast in
  this function does not wake arbitrary host reads or accepts.
- `fs/real.c:202-241`: read, write, pread and pwrite retry EINTR without examining
  pending guest signals or a stop request. Realfs descriptors are not limited
  to regular files: `kernel/init.c`'s `open_fd_from_actual_fd` and
  `create_piped_stdio` use `realfs_fdops` for host stdio. An idle open input pipe
  or full output pipe therefore gives a concrete blocking path.
- `fs/sock.c:499` calls host connect directly; `:581` calls host accept directly.
  A shutdown wake descriptor added only to the poll implementation would not
  participate in these calls. Their blocking behavior also needs redesign.
- `util/timer.c:20-30` schedules asynchronous timer disposal, rather than waiting
  for completion; `:77-78` creates and detaches timer pthreads. Counting/joining
  only `task_start` threads leaves these workers unaccounted for. The worker
  invokes `timer->callback(timer->data)` at `:45`.
- `kernel/task.c:47` keeps the PID allocation cursor in a function-local static;
  `:133-163` has deferred task frees based on subsequent destruction, not joins.
  `task_destroy` zeroes the task before its delayed free. A thread registry must
  own its completion record independently of this task allocation. Resetting
  the PID array while old host threads still run would invalidate their state.
- `fs/mount.c:114-127` refuses nonzero mount references with EBUSY. In
  `kernel/exit.c:550-552`, halt abandons busy mounts instead of draining them.
  Clearing the list to permit another boot would bypass filesystem teardown
  while old references remain. It is not a valid cleanup operation.
- `kernel/init.c:24-32` changes process-wide SIGUSR1 and SIGPIPE dispositions
  during boot. An embedding redesign must address host ownership of these
  dispositions as well as guest termination.
- `app/ios/Runner/ShellBoxKernel.c:4-14` is in **this repository**, not the pinned
  upstream root. It forwards only mount_root, become_first_process and
  pty_open_fake. It supplies no lifecycle or quiescence primitive.
- `kernel/exec.c:597-619` can return an error after first-process construction;
  it does not undo that construction or unmount the root. Boot-error cleanup
  needs an explicit path, including the case before any task pthread exists.
  Spontaneous PID 1 exit still reaches the locked halt path in exit.c, so a
  stop-method-only implementation cannot cover it.

### Approaches examined and experiment actually run

The following are source-level evaluations, **not implemented redesign trials**:

| Approach | Concrete remaining failure |
| --- | --- |
| Move PID 1 hook outside pids_lock, replace final process exit with thread exit | Other tasks still use blocking host I/O; PID 1 resource/reaping and mount cleanup must be completed, not skipped. |
| Make task pthreads joinable and join before boot | A join does not interrupt the blocked call; timer workers are outside the task registry. Joining from the exiting PID 1 thread would also need a separate supervisor. |
| Use guest SIGKILL plus existing wake logic | Existing cross-task guest signal delivery itself uses host SIGUSR1; realfs retries EINTR. |
| Add a shutdown descriptor to host poll | Direct read/write/connect/accept do not wait on that descriptor. All guest-owned blocking I/O needs an interruptible abstraction. |
| Reinitialize global PID/mount/tty tables after task list empties | The exit-group safety valve permits surviving host threads, so the assumed quiescence is false. Clearing their referenced objects creates lifetime violations. |

One executable experiment was run on Linux: extract the **unchanged** pinned
`realfs_read` function, compile it against a deterministic read shim that returns
EINTR on its first call (and marks a simulated shutdown), then returns one byte
on its second call. The assertion confirms that read is called again after the
interruption. This isolates the retry behavior; it does **not** execute the guest,
measure a real shutdown, test Darwin, or prove that rewriting this function is
impossible. Reproduction on Linux or Mac:

```bash
python3 - /path/to/pinned/shellbox-source <<'PY'
from pathlib import Path
import subprocess, sys, tempfile
source = (Path(sys.argv[1]) / 'fs/real.c').read_text()
body = source[source.index('ssize_t realfs_read('):
              source.index('\nssize_t realfs_write(')]
harness = '''#include <errno.h>
#include <assert.h>
#include <stdio.h>
#include <sys/types.h>
struct fd { int real_fd; };
static int calls, stopping;
static int errno_map(void) { return -errno; }
static ssize_t injected_read(int fd, void *buf, size_t size) {
    (void)fd; (void)buf; (void)size;
    if (++calls == 1) { stopping = 1; errno = EINTR; return -1; }
    return 1;
}
#define read injected_read
''' + body + '''
int main(void) {
    struct fd fd = {0}; char c;
    assert(realfs_read(&fd, &c, 1) == 1);
    assert(stopping == 1 && calls == 2);
    puts("CONFIRMED: pinned realfs_read retries host read after EINTR; no shutdown check");
}
'''
with tempfile.TemporaryDirectory(prefix='shellbox-eintr-') as d:
    p = Path(d)
    (p / 'probe.c').write_text(harness)
    subprocess.run(['cc', '-Wall', '-Wextra', '-Werror', str(p / 'probe.c'),
                    '-o', str(p / 'probe')], check=True)
    subprocess.run([str(p / 'probe')], check=True)
PY
```

### Follow-up Linux results and coordinator acceptance boundary

- Extracted-function C probe above: compiled and passed using `/usr/bin/cc` on
  x86_64 Linux. No full ShellBox build or guest execution was performed.
- All three existing patches: check, apply, reverse-check passed on temporary
  copies of their pinned upstream input files; combined second-build reverse
  checks also passed. No new lifecycle patch exists to validate.
- `bash -n runtime/shellbox/build-ios-libs.sh`: passed.
- `git diff --check`: passed after updating this note.
- `dart`, `flutter`, `clang` were not found on PATH. Dart/Flutter tests and Apple
  compile/link/simulator/device checks were **not run**.

The preceding Exact coordinator Mac commands still apply to the installer.
Do not label their success lifecycle acceptance. Start, stop, restart, reset
(including empty/all keep), and real guest stdout/stderr remain unimplemented.
The existing channel errors and fixed-message ring remain unchanged.

Once an actual lifecycle patch exists, the coordinator must additionally test:
real Node/DSH version probes and readiness before start completes; same Runner
PID and a responsive Flutter engine through repeated stop/start cycles; clean
PID/mount/tty state and no residual task/timer workers before second boot; idle
stdin, full stdout/stderr, pending accept/connect and active timers during stop;
missing/non-executable init and spontaneous PID 1 exit; reset for empty, each
individual and all keep groups, checking fakefs metadata and pre-mutation failure
behavior; stdout/stderr framing across split UTF-8, partial and oversized lines;
secret redaction across chunk boundaries; and the existing 2000-entry eviction,
sequence and snapshot watermark contracts across stop/restart/reset. These are
pending acceptance cases, not commands claimed to pass or functionality supplied
by this follow-up. Real-device validation remains required after simulator work.

**Result: Phase C remains incomplete. The shutdown redesign is not implemented;
architectural impossibility has not been established.**

## Round 3 implementation (2026-11-13): partial patch, lifecycle still incomplete

This round adds executable code in `runtime/shellbox/embedded-lifecycle.patch`
against the unchanged `5dfc962fe5e03fe5bc6b869b8744312ebe6af627` pin.
`build-ios-libs.sh` applies it fourth, using the existing apply-or-reverse-check
mechanism. The earlier installer and fakefs import patch were retained. Fetch
again failed because `.git/FETCH_HEAD` is read-only; no branch, commit or push
was created. The pinned checkout was not modified.

**This is not a working start/stop/restart/reset implementation.** Runner still
refuses these operations with its existing explicit error codes. Its start/stop
messages now describe the remaining integration gap accurately. There is no
native supervisor wiring, readiness result, endpoint, token or guest log stream;
the existing system-message history is not presented as guest stdout/stderr.
Dart remains unchanged. The partial code below is not an impossibility proof.

### 1. Guest I/O: retry guard implemented; blocking wakeup not implemented

The patched `realfs_read`, `realfs_write`, `realfs_pread` and `realfs_pwrite`
check `guest_threads_stopping()` before every host call, including EINTR retries.
A deterministic shim sets stop on the first EINTR; all four extracted functions
return guest `-EINTR` after exactly one host call, without recording a successful
write. A stop already present before entry also prevents calling host read.

The new **patched-code** `blocked-realfs-read-stop-gap` probe demonstrates the
remaining failure: a worker passes the guard, enters a real host pipe read, and
the supervisor requests stop. The completion pipe remains unreadable for the
50 ms observation window and `guest_threads_join_stopped()` returns `EBUSY`.
Writing a byte to the input pipe releases the read; only then can the registry
join the worker. This is an expected failure of the desired stop-wakes-read
property, not a passing shutdown test. No wake descriptor or host-signal wake
was added to these calls. `connect`/`accept` are not patched. Consequently this
block is **partial**, and cannot justify enabling start.

### 2. Host workers: independent registration/join and retirement implemented

New `util/guest_threads.[ch]` allocates each completion record separately from
its task/timer. An outer pthread cleanup handler records completion, including
`pthread_exit` paths. Task and timer pthreads are joinable; their creation uses
`guest_thread_create`. Registry operations serialize creation, retirement,
completion and joining. Join errors propagate to callers.

`task_destroy` removes PID/sibling ownership and retires storage through the
registry; it no longer zeroes live task storage or frees it based on subsequent
destructions. A registered task allocation is freed only after its own pthread
has been joined. An unstarted task has no record and can be freed immediately.
Normal reaping retains records for unreaped zombie tasks; supervisor joining
can remove a completed record while leaving the zombie owned by the PID table.

`timer_thread` now waits on a per-timer pthread condition, rather than
`nanosleep` plus SIGUSR1. `timer_set` and `timer_free` wake it while holding its
mutex. A dead timer's condition/mutex are destroyed after the worker releases
them. Worker completion is recorded independently even when the timer object
has already been freed. Failed timer worker creation rolls back `active` and
`thread_running`; stop admission maps to guest `-EINTR`, other pthread errors
use `errno_map`. Timer/task creation also reaps eligible completed records.

`task_start` now returns a host errno. The implementation initially retained
its fatal `die` path for rejected creation; an extracted-function probe exposed
that stop admission would reach it. This was corrected rather than shipped:
`sys_clone` now calls `discard_unstarted_task` on failure, removes group
membership, drops sighand/fs/files/mm references, removes the PID/task, and
cleans a prepared vfork condition. A new group is freed; a shared group is
retained. No ptrace fork event is emitted for failed creation. The probes cover
both group ownership cases and ECANCELED admission without a fatal exit.

State ownership: `guest_threads_request_stop` sets the admission barrier under
the registry mutex; only the completion handler sets `done`; task destruction
sets `retired`; successful join removes the record and frees retired storage.
There is deliberately **no clear/rearm API**: no caller may authorize a second
boot before kernel-global teardown exists. Runner does not set this barrier.
`guest_threads_join_stopped` requires stop admission to be closed, joins only
completed workers, and returns `EBUSY` if workers remain; it does not hide a
blocked worker behind successful shutdown. Registration/join primitives are
implemented, but autonomous worker interruption and PID-cursor reset are not.

### 3. Init exit: unlocked notification implemented; supervisor/drain missing

`do_exit` has an opt-in `embedded_init_exit_notify(int status)` branch for the
init group. With this callback installed, init bypasses `halt_system`, completes
its per-task teardown, releases `pids_lock`, notifies, and exits its pthread.
The callback receives a status, not a task pointer, and must wake a separate
supervisor rather than join its own worker. The default NULL callback preserves
the CLI halt path. Identification uses the group leader's PID, including when
the last exiting thread is not the leader.

Init stays a zombie with its group retained: freeing it at this point would
leave surviving children's parent references dangling. This intentionally
leaves explicit supervisor reaping work. The extracted branch/notification-tail
probe verifies zombie marking, exactly one status notification, availability of
`pids_lock` inside the callback, and subsequent host-thread join. It does **not**
execute full `do_exit`, child reparenting or kernel teardown.

No supervisor loop, init-zombie reaper, mount drain, PID allocator reset, tty
reset, or SIGUSR1/SIGPIPE ownership acquisition/restoration is implemented.
The patch neither clears global tables nor discards busy mounts. In particular,
the callback alone is insufficient to authorize another boot. This block is
**partial**, not a safe embedded shutdown implementation.

### 4. First exec failure: teardown dispatch implemented; boot rollback incomplete

`run_first_process` in `kernel/init.c` calls `do_execve`. On error it reports the
original negative errno and calls `do_exit(127 << 8)` rather than returning a
half-initialized current task. On success it enters `task_run_current`. Its
contract requires an init worker registered with task ownership and the embedded
exit callback installed before use. The wrapper is not called by Runner yet.
The first-exec probe injects ENOENT, EACCES, ENOEXEC and ENOMEM, checking original
error reporting before exit dispatch and that execution is never entered on
failure; success enters execution without an error report. `do_exit` is a shim
in this probe, so it does not establish actual resource or mount reclamation.
The init-exit branch is shared with spontaneous exit; full spontaneous-exit
coverage with real tasks remains pending. Mount/signal rollback is not supplied.

### Linux commands and actual results

```
python3 runtime/shellbox/tests/lifecycle-probes.py /data/workspace/shellbox-validation
bash -n runtime/shellbox/build-ios-libs.sh
git diff --check
```

The Python command compiles with `cc -std=gnu11 -Wall -Wextra -Werror -pthread`
and runs these probes, each in its own process:

- `realfs-stop-before-eintr-retry`: passed.
- `registry-retirement-and-stop`: passed, including extracted `task_destroy`,
  live storage after retirement, pthread_exit cleanup and EBUSY before release.
- `timer-wake-free-join-without-signals`: passed, including an observed wait,
  cancellation before the 100-second timer fires, join, and creation rejection.
  This process installs no SIGUSR1 handler.
- `first-exec-error-dispatch`: passed with the shim boundary described above.
- `blocked-realfs-read-stop-gap`: expected shutdown limitation reproduced;
  assertions confirming that limitation passed. Stop itself did not wake read.
- `init-exit-unlocked-notification`: extracted branch/tail assertions passed.
- `task-start-stop-admission-error`: passed after fixing the fatal path.
- `clone-unstarted-resource-rollback`: extracted cleanup helper passed for
  shared/new groups; real kernel references/tty teardown are not exercised.

All four patches passed check, apply and reverse-check together on temporary
inputs read from the pinned git objects. All four reverse checks also passed
again in build-script order, covering an already-patched rebuild. The first
probe-run setup attempted a full source archive extraction and exhausted `/tmp`;
its temporary directory was cleaned automatically. The runner was changed to
extract only required patch inputs and headers, and the subsequent runs passed.
This setup failure was not a kernel failure.

The new registry and patched timer translation units also compiled separately
on Linux. An attempted whole `exit.c` syntax check initially failed for missing
`sqlite3.h`. A subsequent `-fsyntax-only` check of patched fork/init/exit/task
succeeded using **type-only SQLite forward declarations** in a temporary header;
it emitted the upstream `tty.h` tgroup forward-declaration warning. This is a
limited syntax check, not a dependency-complete ShellBox build or ABI check.
Shell syntax and whitespace checks passed. No iOS library, guest, Flutter,
Xcode, simulator or real-device verification was performed.

### Remaining coordinator work

The patch is reviewable partial implementation, **not Phase C acceptance**.
Before enabling Runner start, code is still required for guest-owned blocking
I/O wakeup (including connect/accept), supervisor cancellation and complete
resource draining, init zombie reaping, mount/tty/PID reset, host signal ownership,
and boot-error rollback through that same supervisor. Native start/stop/restart/
reset and real stdout/stderr capture remain unwired. Mac compilation should
first check the changed timer layout, pthread condition behavior, updated
`task_start` contract and static-library linkage. After the missing lifecycle is
implemented, the previously listed repeated-boot, failure, logging and reset
acceptance cases still require Mac simulator and real iPhone validation.

## Round 4 (2026-11-13): two teardown fixes; blocking wakeup still unresolved

**This round does not complete the embedded lifecycle. In particular,
`blocked-realfs-read-stop-gap` still reproduces failed stop wakeup.** The rejected
implementation trials below establish failures of those concrete mechanisms,
not impossibility of an interruptible I/O redesign. They are insufficient evidence
for claiming that local mode can never support safe stop. No Runner/Dart wiring
was enabled, and no guest readiness, version, endpoint, token or log is invented.

The starting branch/HEAD and pre-existing worktree changes match the supplied
baseline. `git fetch origin main` failed with `.git/FETCH_HEAD: Read-only file
system`. All prior work was preserved; no branch creation, commit, push, Android,
workflow, signing, onboarding or pinned-checkout modification was performed.
This round changes only the lifecycle patch, its existing probe runner and this
note. Temporary patch assembly happened in `/tmp/phasec4-work`.

### 1. Blocking wakeup: three rejected executable implementation trials

The production retry guards are retained. No known-broken wake mechanism was
added to them or to `connect`/`accept`.

- `trial-single-signal-loses-pre-syscall-wakeup`: implement the candidate policy
  "set stop, send one non-SA_RESTART SIGUSR1 to the worker" in a C harness. A
  semaphore pauses the worker just after its stop check; the signal handler
  acknowledges delivery through an async-signal-safe semaphore before the
  worker enters the blocking call. The completion descriptor stays unreadable
  for 50 ms. Only external pipe input releases the worker. Thus replacing the
  flag-only stop with one `pthread_kill` still loses the wakeup between the guard
  and host entry. The harness uses a real blocking pipe as the deterministic
  host-call shim; its three iterations do **not** establish real socket coverage.
  An initial attempt to use an actual abstract UNIX listener failed at `bind`
  with host `EPERM` (also reproduced directly with Python `socket.bind`), so
  real blocking connect/accept experiments were not run in this sandbox.
- `trial-poll-wake-descriptor-readiness-race`: implement poll on the input fd
  plus a shutdown pipe, followed by a blocking read. After poll reports input,
  a competing reader consumes the available byte. Stop makes the shutdown pipe
  readable before the worker proceeds, but the subsequent host read still
  blocks. Completion stays unreadable for 50 ms and needs external input.
  Consequently adding a wake descriptor only to a readiness wait is not enough;
  the actual following operation must also avoid blocking, including concurrent
  readers/writers and the analogous accept race. This trial does not implement
  descriptor flag ownership, nonblocking guest semantics or a complete solution.
- `trial-pthread-cancel-skips-resource-unwind`: a worker owns a real pthread
  mutex across a blocking read, as guest syscall callers can own locks across
  fd operations. Deferred cancellation lets join succeed with PTHREAD_CANCELED,
  but `pthread_mutex_trylock` still returns EBUSY. The registry completion
  cleanup alone cannot unwind its caller's locks or perform `do_exit` resource
  release. Therefore naked pthread cancellation was rejected rather than wired
  into the stop path. This harness models the caller-lock boundary; it is not
  execution of a real guest syscall or proof against carefully scoped
  cancellation with a complete cleanup design.

The original `blocked-realfs-read-stop-gap` continues to confirm that the
**shipped patched** realfs read is not woken by `guest_threads_request_stop` and
join returns EBUSY until external input arrives. The runner now prints
`CONFIRMED LIMITATION` for this case and the three rejected trials instead of
printing a misleading bare PASS. Successful assertions here mean the limitation
was reproduced, **not** that stop works. A reliable wake mechanism, actual
connect/accept integration and Darwin validation are still outstanding.

### 2. Supervisor/drain/reset: child ownership fix; no complete supervisor

New production changes in `embedded-lifecycle.patch`, `kernel/exit.c`:

- `find_new_parent` uses `pid_get_task_zombie(1)` in embedded mode. After init
  becomes a zombie, the ordinary `pid_get_task(1)` deliberately returns NULL.
  A later child exit could previously dereference that NULL while moving its
  own children onto the new parent's list. Init's retained allocation/group
  must continue owning descendants until the missing supervisor reaps them.
- `do_exit` skips child-list movement when `new_parent == current`. On the last
  exiting init thread, selecting retained init as its own replacement parent
  otherwise moves entries onto the list currently being iterated; with multiple
  children the safe-iteration macro can revisit entries indefinitely.

`embedded-init-zombie-child-ownership` extracts both patched code fragments,
uses the upstream's actual list macros, and checks two children surviving init's
own exit, a later child's descendants moving to zombie init, parent pointers,
and the unchanged CLI lookup behavior. This is component coverage, not full
`do_exit`/spontaneous PID 1 guest coverage. Existing unlocked notification and
registry join probes still pass.

`busy-mount-preserved-until-reference-drain` extracts upstream
`mount_remove_locked`, checks EBUSY with two and then one outstanding reference,
checks that the mount stays linked and umount is not called, and verifies that
only releasing the last reference permits removal and calls umount outside the
lock. Reference owners are shims; **there is no implemented global reference
drain**. Worker joins do not themselves release zombie/kernel/tty owners. No
mount/PID/tty tables are cleared, no registry rearm exists, and no supervisor
thread or global reset is claimed. Implementing these remains necessary.

### 3. Boot rollback: construction-failure signal rollback implemented only

New production changes in `embedded-lifecycle.patch`, `kernel/init.c`:

- `establish_signal_handlers` now returns a guest errno and captures the previous
  SIGUSR1/SIGPIPE actions atomically with each installation using `sigaction`.
  Failed SIGUSR1 installation prevents task construction. Failed SIGPIPE
  installation restores SIGUSR1 before returning; restoration errors propagate.
- `become_first_process` invokes `restore_signal_handlers` if `construct_task`
  fails, before returning. Restoration tries both actions even if restoring
  SIGPIPE fails, and returns a restoration error rather than hiding it behind
  the construction error. No task pthread exists in this path.

`construction-failure-restores-host-signal-dispositions` installs real host
handlers, injects ENOMEM from task construction, invokes the extracted actual
boot functions, and checks both handlers were restored. The additional
`boot-signal-install-and-restore-errors` injects EIO at each of the two installs
and two restores, verifies error propagation and construction admission, and
verifies restoration of SIGUSR1 is attempted even when SIGPIPE restore fails.
The probe restores its process's original actions on completion.

This is **not complete signal ownership**: successful boot still installs
process-wide handlers, has no stop-time release, and would conflict with a host
that concurrently changes the same dispositions. The native bridge remains
disabled. The saved construction-local actions are not advertised as a
successful-session restoration record.

Complete boot rollback is still missing: the construction-failure branch does
not unmount the caller's root or reset PID allocation; first-exec failure still
dispatches through the prior `run_first_process`/`do_exit` path without a supervisor
that reaps init and drains root references. The unchanged first-exec probe only
proves dispatch/original exec errno reporting. No no-worker exec rollback or
full spontaneous PID 1 teardown is claimed. No additional cleanup API with
unverified ownership preconditions was exposed.

### 4. Wiring and validation boundary

Runner start/stop/restart/reset, real guest stdout/stderr and readiness remain
unwired because block 1 is still unresolved. Prior installer and explicit channel
errors are preserved. No Dart file changed.

Commands actually run:

```
python3 runtime/shellbox/tests/lifecycle-probes.py /data/workspace/shellbox-validation
bash -n runtime/shellbox/build-ios-libs.sh
git diff --check
```

The final probe run compiled and executed 15 C probes successfully: 11 component
assertion suites and 4 confirmed limitations, **not 15 lifecycle passes**. The
runner also checked/applied/reverse-checked all four patches against temporary
inputs from the pinned git objects, then repeated all four reverse checks in
build-script order. Shell syntax and tracked whitespace checks passed. The two
modified untracked text artifacts were also checked separately for trailing
whitespace. Initial new harness compile errors (missing stdbool/stddef includes
and an object-like sigaction macro renaming its struct tag) were corrected;
they are not kernel failure evidence.

A dependency-complete `cc -fsyntax-only` attempt for the patched `kernel/init.c`
and `kernel/exit.c` failed because the installed environment lacks `sqlite3.h`.
The extracted changed functions compile with `-Wall -Wextra -Werror`; no whole
translation-unit, library build or link success is inferred from that. Apple
SDK, Flutter and Xcode checks, actual guest execution, simulator and real-device
validation were **not run**.

On Mac, first compile/link the complete patched libraries and check these added
signal error paths and child ownership changes. Lifecycle acceptance still
requires implementing the unresolved wake/supervisor/drain/reset/rollback paths,
then verifying idle input/full output, real pending connect/accept, timers,
construction/exec failures, spontaneous PID 1 exit and repeated boot in one
responsive Runner PID. Readiness, real Node/DSH probes, log framing/redaction and
all keep/reset cases remain required before enabling native/Dart wiring. The
three failed trials above do not justify reporting architectural impossibility
or a completed Phase C.

## Round 5 — 会话式运行模型论证（2026-11-13）

**第一步结论：常驻 guest + 多次服务启动有现成源码依据；但“现有原语加
per-task pending 检查就能有界停止服务”不可行。第一步未通过，因此本轮停在
论证，不进入第二步 start 切片或第三步 stop-service。** 这不是会话模型在架构
上不可能的证明，也不是要求再次补完整个 guest teardown 才能 start。实际阻塞
是服务本身的 I/O 中断和退出完成判定，下面给出新的服务范围探针和证据。

基线仍为 `feature/ios-shellbox-dynamic-island` / `10e20b32339349102c662b755e42109622577315`。
`git fetch origin main` 再次失败：`.git/FETCH_HEAD: Read-only file system`。
保留指定工作树继续本轮；没有新建分支、commit 或 push。已核对前四轮笔记、
Round 4 日志的试验/错误输出与任务书最后的产品决策边界，没有重新设计全局关机。
本轮仅追加本节及原 `lifecycle-probes.py` 的四个探针；生产补丁、构建脚本、
插件及 Dart 的原有内容不变。下述上游文件行号均指实际核对的 pinned commit
`5dfc962fe5e03fe5bc6b869b8744312ebe6af627`；补丁行号单独标明。

### 1. Host 到 guest 的控制路径：可行，有原语，尚无插件 API

- 本仓库 `app/ios/Runner/ShellBoxKernel.c:4-14` 确实只有三个转发函数，不能据此
  推断上游没有 spawn/kill。上游 `kernel/init.c:172-189` 的
  `become_new_init_child` 在当前 host 线程构造 PID 1 的子 task，并设置 TLS
  `current`；`kernel/exec.c:674-681` 的 `do_execve` 接收 host 参数；
  `kernel/task.c:249-257` 的 `task_start` 开始 guest 执行（现有补丁改为返回错误）。
- 更直接的证据是 pinned `tests/integration/sbm_api_test.c:12-23,221-267,295-335`：
  先 boot 常驻 init，然后多次构造会话、接 PTY、exec、start。这个测试使用
  realfs，不是本应用的 fakefs/Node 验证，不能当作本项目已运行 guest。
- `kernel/signal.c:95-102,104-145` 的 `deliver_signal` / `send_signal` 和
  `:160-172` 的 `send_group_signal` 可供内核调用；`:951-964,1031-1042` 的
  guest kill 系统调用还依赖调用者 `current` 的 uid/euid 等权限上下文。
  不能把 `sys_kill` 直接扔给任意 GCD 线程，也不能把 guest pid 交给 host kill。
- 最小新增控制路径：在 Kernel C 桥暴露串行的 create-child/exec/start 与针对
  已登记服务 task/group 的信号操作；锁内查询 PID，按已有 `send_group_signal`
  的所有权方式发送，拒绝 PID 1，避免 task 指针越过锁的有效期。一次 start
  必须记录其服务身份直到退出完成，不能对已经复用的数字 PID 发迟到命令。
  或让 guest 内常驻父进程接受命令、fork/exec/wait 并发送 guest kill；这需要
  新控制协议和真实应答，并非已有 Flutter 接口。两条路都不是本轮已实现 API。
- `become_new_init_child` 自带 `// locking?` 和 init 非 NULL 的 assert
  (`kernel/init.c:173-175`)；插件不能用无锁“先查 init 再创建”跨过 init 退出。
  初版入口需要串行启动和与 PID 1 退出同步的存活检查/构造所有权。

新 `session-new-child-keeps-init-and-clears-signals` 提取真实函数，以构造器和
PID lookup shim 连续创建两个子 task，断言 parent 为同一 init、TLS current
切换及 pending/blocked/waiting/queue/clear_tid/vfork 清理。它验证函数契约，
不执行真实 PID 分配、PTY、exec、Node 或并发 init 退出。

### 2. 杀掉阻塞的 Node：目前不可行；pending 检查只是有界的局部修复

需要区分 **发送成功、syscall 返回、进程退出、服务线程全部结束**。

- `kernel/signal.c:61-91` 先置 pending/入队，再对目标 pthread 发 SIGUSR1。
  `util/sync.c:103-118` 的 handler 仅在 `should_unwind` 已置位时 longjmp；
  `fs/real.c:202-241`、`fs/sock.c:489-509` 不建立这个 unwind 区域。
  `kernel/signal.c:562-603` 在 guest 执行路径消费 pending；
  `kernel/calls.c:239-244,1159` 的退出检查/receive_signals 要等 syscall 返回。
  在 read 内重试，CPU poke 无法让执行路径到达它们。
- 因此服务 SIGKILL 的局部修复应在 **目标 task 的 sighand 锁下**检查
  `sigset_has(current->pending, SIGKILL_)`，并考虑已开始的
  `current->group->doing_group_exit`，返回 guest `-EINTR` 让 syscall 调用层
  正常 unwind，再处理 guest 信号。不要在底层持有调用者资源时直接 do_exit。
  若支持 SIGTERM 等其他信号，需要遵守 blocked/action/handler 语义，不能把
  任意 pending 都当致命信号。跨线程读取不能裸读 pending 或悬空 sighand。
- 不能置 `guest_threads_request_stop()`：它关闭整个 guest 的线程准入且没有
  rearm。会杀掉 init 后续 fork/Node 新线程的能力。另造 per-service flag 仍需
  定义所有线程/后代的归属和清除时机，不能凭空解决唤醒。
- 新 `session-pending-kill-eintr-scope` 从已打补丁的 `realfs_read` 提取函数，
  仅在临时 C 字符串里把全局谓词换为 task-local SIGKILL 的布尔 shim。
  第一次 host read 注入 EINTR 并置目标 pending，候选函数只读一次就返回
  `-EINTR`；另一个 task 继续成功读。对照原补丁函数，全局 stopping=false 时
  即使目标 pending=true 仍读第二次。**这个 EINTR 修复本身是有界补丁。**
- 新 `trial-session-pending-kill-before-host-entry` 使用同一提取函数和候选
  谓词，在检查后暂停，置目标 pending，再放行 host read。确定性 shim 模拟
  host 唤醒已在进入 read 前消费，但 guest pending 仍保留；read 卡住，完成 fd
  在 50ms 内不可读。只有测试外部写入输入 pipe 才返回，1000ms 内收尾并 join。
  50ms 不是数学上的无限证明；无外部写入的空 pipe 没有返回条件，剩余代码
  也没有下一次检查或唤醒。断言通过的是 **候选仍有缺口**，不是 stop 成功。
- 与 Round 4 的区别：新试验不置全局 stop、不实现/重试那三种唤醒机制，
  只检查“持久的 task pending 是否能让服务范围的 retry guard 足够”，并用
  上一探针证明 EINTR 成功路径确实改善。未把此候选写进生产补丁。
- `fs/sock.c:499` 直接 connect；返回 EINTR 时不重试，但同样没有原子化的
  pending-check/进入阻塞。`:578-585` 的 accept 另有 restart 逻辑。
  本轮未运行真实 socket/connect 或 Node；不能声称这些路径能有界退出。
  guest 中用 HTTP 控制命令也只覆盖能回到事件循环的服务，不覆盖同步 read
  或其他卡住的线程，不能替代要求中的 kill。

另一个会话模型专属的完成判定问题：`kernel/exit.c:339-347` 发组内 SIGKILL，
`:352-417` 等待并有限次重发后，`:419-472` **仍会把阻塞线程摘出 group，
延后释放 mm/fd**。这发生在普通服务的 do_exit_group，不只 halt_system。
因此服务 leader zombie、wait 返回、exit_hook、端口不响应，都不能单独证明
没有遗留服务线程持有文件或还能写盘。已有 registry 也只有全局 join-stopped，
没有服务范围的 completion fence；不能为了等 node 而 join 常驻 init。

会话模型减少了需要处理的任务范围，但还需要服务范围的可中断 I/O 等待，
或证明服务所用的全部阻塞路径已经可中断，以及服务后代/线程的完成核验。
非阻塞 host 操作 + 可唤醒等待 + guest 阻塞语义是待实现方案，**没有被本轮
证明不可实现**；仅改 EINTR 谓词不足。本项未通过，所以不启动第二、三步。

### 3. 同 guest 再起 Node：可行；全局 teardown 不需要，服务资源仍需回收

`become_new_init_child` 和上述 integration 示例已支持每次新 task/exec。
正常第二次服务启动不调用 mount_root/become_first_process，不复位 PID cursor、
mounts、tty 表，也不清 registry 全局 stopping。每次只分配服务自己的 fd、PTY、
task/group、环境，关闭/释放旧服务自己的资源。新探针验证的是子 task 初始化，
不是已经证明第二次 Node 能运行。

不能照抄示例的睡眠 init：`tests/integration/sbm_api_test.c:29-34` 明说每次
会话留下 task/tgroup/PID zombie。`kernel/exit.c:728-765` 的 wait/reap 路径
依赖真实父子关系；要让 PID 1（或实际服务父进程）持续 wait，并接收孤儿，
不能只依赖退出通知。`kernel/task.c:45-52` 分配器循环寻找空 PID，常驻会话
长期不 reap 会耗尽 PID；这不是重新 boot 才遇到的问题。服务之外的用户任务
是否停止、DSH 子进程是否属于该服务也必须明确。第 2 项未完成前不能授权重启。

### 4. 不重启内核的 reset：数据删除可行，完整 reset 契约未通过

`fs/fake.c:645-682` 的 unlink 和 `:685-720` 的 rmdir 同时操作 data 与 meta.db，
错误 rollback、成功 path_unlink/commit/orphan 检查；`:723-755` 的 rename 也走
数据库事务。可在 guest 内用文件系统 syscall 删除指定数据树，或用有 guest
上下文的专用遍历调用相同 fs_ops。不能 host rm active/data 后留下 meta.db，
也不能在已挂载 root 下运行 import/替换整棵 active。

新增 `session-fakefs-unlink-metadata-and-failure` 提取 pinned fakefs_unlink，
shim 普通非 bind 路径，验证 host 删除成功才更新 metadata/orphan，host 删除
失败返回原错误且 rollback、不改 metadata，readonly 返回 EROFS。它不执行
SQLite，不验证递归、keep-list、symlink/hardlink 或崩溃原子性。

keep-list 可用 guest 路径分段匹配实现：命中保留根就不进入；其祖先仅遍历
不删除；其余节点按 lstat 类型后序 unlink/rmdir，不跟随 symlink，不跨出
预定数据树/进入挂载点。保留 inode 和 hardlink 关系，不做 host 复制。
不是字符串 startsWith（例如 /a/b 不保留 /a/bad），失败须报告实际错误，
递归删除不是全树事务，不得声称失败完全未改数据。

现有 Dart `runtime_bridge.dart:486-500` 的 keep wire 是组名，不是任意绝对路径；
Android 权威映射仅作为兼容证据读取：`RuntimeInstaller.kt:277-280` 将两组映射
到 root/.dsh/dsh-go、skills、root/.agents/skills，以及 profiles、cordis.patch.yml、
.env。本轮未改 Android，也没有把这些未经 iOS payload 核对的路径硬接进去。

**第 2 项的服务资源未静止时不能 reset**：旧线程/fd 能继续写已删或重建的文件。
此外现有 reset 文档语义是删除运行环境供重新安装；常驻内核下清数据不能修复
损坏 Node/基础 rootfs，不能偷偷宣称等价。数据 reset 的具体范围、默认配置恢复
和该契约的取舍需后续明确。当前继续返回原 reset 错误，不做任何删除。

### 5. PID 1 自发退出：可探测正常 do_exit 完成；不是任意卡死的 watchdog

本轮核对的 `embedded-lifecycle.patch:99-109,122-128` 在最后 init group
线程退出时置 zombie、跳过 halt_system、释放 pids_lock 后调用 notify。
此前的 `init-exit-unlocked-notification` 和 `embedded-init-zombie-child-ownership`
探针仍通过，分别检查通知 status/锁外调用及后续 child 归属。这是已有真实补丁
可复用的部分，无须实现全局 drain/reset 才能报告 init 退出。

边界：通知在 do_exit 的资源释放之后；pinned `kernel/exit.c:54-58,99-147`
先 drain 引用、释放 mm/files/sighand 再进入该分支。init 卡在 syscall、资源释放
卡住、host 崩溃、信号所有权冲突不等于完成 do_exit，不能保证立即或有界收到
此 callback；本轮没有完整 guest 自发退出测试。

若以后接线，callback 只提交 status/事件到独立控制队列：进入 terminal error，
清除 baseUrl/token/就绪与版本可用状态，拒绝同 Runner 的 start/restart/reset，
错误原因明确区分 PID 1 已退出与服务退出。这个 error 由 init 退出事件置位，
本进程内不清除，只能新 Runner 会话重新初始化；恢复文案/产品路径由协调者决定。
不要在 callback join 自己、恢复 installed、重启 guest，也不要把 guest 已死
写成所有子任务已结束。以上是建议状态契约，**本轮插件未实现新状态/错误码**。

### 6. 仍未解决的部分与阶段边界

| 项目 | 论证结果 / 余项 |
| --- | --- |
| 创建 guest 服务/发送信号 | 原语可行；桥接入口、并发 init 退出、服务身份和真实命令响应未实现 |
| 阻塞 Node 的有界退出 | 未通过；pending 修复 EINTR 重试，不能解决进入 host call 的窗口；真实 connect 未验证 |
| 服务重启 | 可绕开内核 teardown；reaping、后代归属和服务线程完成核验仍需实现 |
| 数据 reset/keep | fakefs 原语可行；未实现遍历/keep；不能替代整套运行环境 reset，且目前不能证明停止所有写入者 |
| PID 1 退出报告 | 正常 do_exit 可复用 notify；不是卡死探测；插件 terminal error 未接线 |
| boot + 真实 readiness/status | 第二步未执行；无真实 Node/DSH 版本、认证、URL/token 或日志；未改 Dart |

会话模型确实移除了“正常 stop 必须拆 guest 内核”的五系统耦合，不应继续把
全局 drain/reset 作为 start 的必备门槛。但这不消除服务范围内的阻塞、回收和
错误态契约。后续若接受只能启动的产品切片，应由协调者另定验收边界；本轮
不能自行把第一步未通过改成产品接受了只启动模式。

### Linux 验证与 Mac 边界

实际运行：

```
python3 runtime/shellbox/tests/lifecycle-probes.py /data/workspace/shellbox-validation
bash -n runtime/shellbox/build-ios-libs.sh
git diff --check
```

最终共 19 组：14 组组件断言通过、5 组确认限制。新增 4 组为 pending EINTR
范围、pending 保留仍丢失 host-entry 唤醒、二次 child 初始化、fakefs unlink
成功/失败事务顺序；它们没有证明 Node/DSH 或服务 stop 可用。原 15 组保留，
既有 Round 4 三组仅随完整回归执行，未修改或开展新实现试验。

四补丁在 pinned git 对象的临时副本上按顺序 check/apply/reverse-check，联合
应用后再按构建顺序重复四次 reverse-check，通过。只增加提取 fs/fake.c，
继续按需提取输入与头文件，没有全量源码展开到 2GB /tmp。最初 child harness
重复定义 misc.h 已有的 IS_ERR/PTR_ERR 导致 -Werror 编译失败，移除重复定义
后通过；这是测试脚手架问题，不是内核失败证据。shell 和 whitespace 检查通过。

没有 Apple SDK、Flutter、Xcode，未运行 iOS 库编译/link、真实 guest、Node/DSH、
模拟器或真机验证。Mac 后续不能仅跑旧的“全局二次 boot”清单来验会话模型：
需验证一次 boot 多次服务运行、真正 wait/reap 与线程完成、read/connect 下的
服务退出、旧服务不再写盘、keep 的内容/元数据、正常 init 退出后的 terminal
error，以及真实 readiness/auth、日志脱敏和 host 信号共存。当前尚未提供这些
行为的生产实现，云 Mac 编译成功也不能把本轮标记为 Phase C 完成。

## Round 6 — 设计先行：服务唤醒与完成边界（2026-11-13）

本轮起点仍为 `10e20b32`；原改动全部保留。fetch 再次因只读
`.git/FETCH_HEAD` 失败，未建立或切换分支。先记录以下设计，再写实现。
不重做 Round 4 三种机制或 Round 5 四组研究；旧探针仅作回归。

### 设计与可验证范围

- 服务身份是独立分配的对象，不用数字 PID、tgroup 链或全局 stopping。
  root worker 显式带入服务身份，后续 guest_thread_create 从 worker TLS
  继承，覆盖 fork/task 与由该 worker 创建的 timer。外部 supervisor 建立的
  worker 必须显式传身份；不把 init 纳入服务。服务内禁止隐式脱离该身份。
- 每服务持有一个非阻塞唤醒 pipe；stop 写入一次持久字节，读端持续 POLLIN，
  所有 waiter 都可见，任何线程都不 drain；避免一个 waiter 消费其他线程的唤醒。
  stop 在 registry 锁内关闭服务准入，永不清除；写入失败返回 host errno，
  不标记 wake_sent，允许 supervisor 重试同一请求。新服务分配新对象；不 rearm
  全局 stop。全部已登记 worker 真正 join 后才能销毁 pipe 与服务对象。
- fence 只结算指定服务；worker cleanup 的 done 仅表示可 join，成功 join
  才减服务 outstanding。stop 后 outstanding 非零返回 EBUSY，不等 init，
  不用 leader zombie/wait/组链替代。对未结束 worker 不阻塞 join。
- I/O 候选：host 描述符必须由桥独占 open-file-description 的 flag 所有权，
  从创建到关闭持续 O_NONBLOCK，禁止“poll 后改回阻塞再 read”，也不能每次
  临时切换 flags（dup 共享 flags，其他 worker 能落入切换窗口）。guest
  O_NONBLOCK 单独存储，F_GETFL 不暴露内部 bit；F_SETFL 保留内部 bit。
  现有 realfs_getflags/setflags 直接透传 host，且 recvfrom/recvmsg 用 host
  O_NONBLOCK 推断 guest 语义，必须一起修改后才可接入现有 fd。
- read：每次检查 stop/task fatal pending，再做一次非阻塞 read；正数立即
  返回实际字节（不凑满、不丢数据），0 只来自实际 EOF；EAGAIN 对 guest
  nonblock 原样返回，对 blocking 在 [fd,POLLIN; wake,POLLIN] 上等待。
  就绪只是重试提示，重试依然必须非阻塞；EINTR 回检查点；stop 返回 EINTR，
  不冒充 EOF。stdio pipe 同路。write 的部分成功也必须保留实际结果，不能
  在写入后因 stop 改报 EINTR；大于 PIPE_BUF 的 blocking pipe write 还需按
  guest 契约处理，暂不接入。pread/pwrite 对普通文件见下述边界试验。
- connect：仅首次调用 connect；EINPROGRESS 等待 POLLOUT+wake，醒后用
  SO_ERROR 判断成功/失败，不以 writable 当成功，不循环重复 connect。
  guest nonblock 保持 EINPROGRESS。stop 不私自 close guest fd，未完成连接
  由正常 guest 退出释放。accept：EAGAIN 等待 POLLIN+wake，每次非阻塞重试；
  接受成功后交回 fd 所有权，后续 guest copyout/分配失败按原路径关闭。
  accepted host fd 也须在发布前设内部 nonblock，guest accept 默认 blocking。
- sys_connect/sys_accept 的 AF_LOCAL 分支还有 sock_io_full 及 unix_got_peer
  条件等待；完整接入必须沿用同一服务身份，处理握手部分字节与 pending
  清理，不能只替换外层 host call。sock_read/sock_write/recv* 也不是 realfs_read。
- task pending 的检查须在 sighand 锁内，仅 SIGKILL/已开始 group exit 等确实
  致命条件；不把任意 pending 当终止。仅 service stop 的持久 pipe 能消除
  service stop 的检查/等待窗口；独立 guest 信号还需原子屏蔽 SIGUSR1、检查、
  pselect/ppoll 恢复 mask 的交接，不能声称普通 poll 自动修复 pending 窗口。
  本轮候选探针只证明 service stop，不声称实现独立 signal 交接。

### 必须先验证的 host 调用边界

“host fd 有 O_NONBLOCK”不等于所有类型 read 都非阻塞。realfs_open 可打开
普通文件，fakefs 复用 realfs fdops；不能把磁盘 read/pread 的阻塞偷偷等同于
pipe/socket 的 EAGAIN。新探针将分别验证可等待的 pipe/socket 候选以及
普通文件 host-read 尚未返回时的 fence。如果仍有无法由 wake 打断的 host
调用，按本轮红线停在组件实现，不接通 start，也不将受限 I/O helper 接入
真实 fdops 冒充完整方案。该边界试验不同于 Round 4 的“就绪后阻塞 read”：
本轮候选每次操作确实保持 O_NONBLOCK，并核实 host flags。

### 实现结果：fence 组件完成；I/O 候选未接入，整体目标未完成

`embedded-lifecycle.patch` 只扩展 `util/guest_threads.[ch]`，保留此前其他
补丁内容。新增 guest_service_new/thread_create/request_stop/join_stopped/
destroy 与 wake_fd/stopping；原 guest_thread_create 自动继承注册 worker 的
TLS service，NULL 身份保留旧行为。创建和 stop 在同一 registry_lock 下，
所以 stop 不会越过一个尚未计入 outstanding 的成功创建。创建失败不增加计数。
现有 task_start、sys_clone 和 timer_set 已走 guest_thread_create，故从服务
worker 发起的这些 host worker 创建不需要另建一个 task 指针索引。

状态所有权：supervisor new 分配服务并持有唯一外部 lifetime 所有权；
request_stop 置 stopping、关闭准入；成功写入才置 wake_sent，两者都不清除。
失败返回 host errno（探针注入 EINTR）；不自动无限重试，调用者可以再次请求。
每服务只写一次一个字节，不 drain、不因多次 stop 填满 pipe。两个 pipe 端点
都保持到 destroy；worker 注册增加 outstanding，只有成功 pthread_join
才减少它。done 仍由最外层 cleanup 发布，不能直接充当 fence 成功。
join_stopped 只处理该服务，未 stop 返回 EINVAL，有未 join 成员返回 EBUSY，
pthread_join 错误原样返回。destroy 在 fence 失败时保留对象与端点，成功后
才释放；外部 supervisor 必须串行 stop/fence/destroy，并在 destroy 前放弃
其他外部 handle 使用。这个约束不能靠在释放后的裸指针上做 NULL 检查解决。

这证明的是**已登记服务 worker 的 host-thread completion**。没有建立真实
Node root worker/guest service 的控制入口，没有在真实后代树上验证身份覆盖，
没有替代 guest wait/reap、guest fd/mm teardown，也没有声称 PID zombie 的
资源已被回收。由服务外 supervisor 创建的 worker 仍需显式传服务身份。
本轮没有使用全局 stopping 实现服务 stop，init 后续创建准入保持原状。

I/O 最小候选位于**原有 lifecycle-probes.py 内的 service6_io C 字符串**，
以同一个真实 registry 编译执行；不是另起一个测试文件，也没有把未通过的
候选安装进生产 fs/real.c 或 fs/sock.c。read 使用真实 O_NONBLOCK pipe，
connect/accept 用确定性 transport shim 模拟 EINPROGRESS/EAGAIN/SO_ERROR，
等待使用真实 poll + 服务 wake pipe。connect shim 不是真实 TCP/UNIX socket，
accept shim 用一个可读 pipe 字节表示连接并 dup 出 endpoint；它不证明 Darwin
accept flag 继承、sockaddr copyout、真实连接或 AF_LOCAL 握手正确。

### 新探针与红线证据

新增七组（`--round6-only` 可只运行本轮；默认仍执行原有回归）：

1. `service6-nonblocking-read-connect-accept`：每条路径两个 worker，分别在
   EAGAIN/EINPROGRESS 后、检查完成而 poll 尚未进入时用 semaphore 暂停；
   supervisor stop 后放行测试调度 gate，不向输入/连接注入数据，不 drain
   满 pipe。持久 wake 同时释放两个 waiter；fence 在单调时钟 1 秒断言期限
   内成功，结果为 EINTR。另覆盖 stop 在检查后、非阻塞 read 前到达。
   放行调度 gate 不属于外部 I/O 救援；测试没有把线程永远暂停后要求它退出。
2. `service6-data-eof-and-transport-errors`：read 分两次读出 abcdef，第二次
   返回实际短读 4 字节而不凑满缓冲区；只有关闭 writer 才返回 EOF；空 pipe
   的 guest nonblock 保持 EAGAIN；connect 仅调用一次 host connect，以
   SO_ERROR 区分成功/ECONNREFUSED，guest nonblock 保持 EINPROGRESS；accept
   保持 EAGAIN/返回 endpoint；fatal_pending 布尔 shim 验证检查点。
   pending shim 不是对真实 sighand/signal 原子交接的实现。
3. `service6-fence-inheritance-and-live-init`：parent 创建 child 后自己返回，
   child 仍阻塞。stop 后 fence/destroy 都返回 EBUSY，wake fd 仍有效；拒绝
   服务内新创建。只在对照探针释放该 child 后成功；init 一直阻塞到该服务
   destroy 以及另一个新服务的 fence 完成之后。最后释放 init、全局 join
   只是独立探针进程的资源清理，不是服务 fence 的实现。
4. `trial-service6-nonblocking-regular-file-still-in-host-call`：真实临时普通
   文件 fstat 确认 S_ISREG、fcntl 确认 O_NONBLOCK、poll 确认 readable。
   候选 read 的一次 host 调用替换为“等待 host 存储完成后才返回字节”的
   确定性 shim；其内部没有观察服务 wake。stop 后 wake 确实可读，但完成 fd
   在 50ms 观察中不可读，fence/destroy 均 EBUSY；只有释放 storage gate
   才在 1000ms 内收尾。**50ms 只是一段观察，不是无限等待证明**。代码级
   缺口是 read 返回前没有下一次 stop 检查，也没有等待服务 wake 的位置；
   storage gate 可以任意迟延。这不是在 Linux 上制造实际磁盘卡死。
5. `service6-readiness-consumed-before-nonblocking-retry`：第一次 read 返回
   EAGAIN 后提供一个字节，poll 就绪；第二次 read 前另一 reader 抢走它，
   再 stop。重试仍为 O_NONBLOCK，返回 EAGAIN 后立即看到 stop，无救援输入，
   fence 在 1 秒断言期限内完成。这是本轮**成功的新方案**，不同于 Round 4
   poll 后调用阻塞 read 的失败试验；没有重新试那种失败写法。
6. `service6-wake-write-failure-and-retry`：编译实际 registry 源码，仅替换
   write，注入 EINTR。stop 返回错误、准入仍关闭、wake 未谎报成功；再次
   请求成功后 wake 持续可读，重复十万次 stop 不会重复写满 pipe。
7. `service6-guest-blocking-read-until-data`：guest blocking 的空 pipe 不把
   内部 EAGAIN/假 EOF 返回给调用者；写入 abc 后返回恰好三字节，保留正常
   guest 阻塞语义。该数据路径探针不是 stop 无输入测试。

普通文件边界的外部契约依据：[Linux man-pages 的 open(2) 源文档](https://kernel.googlesource.com/pub/scm/docs/man-pages/man-pages/+/52b7bab3a44fb5d2d464fa8acd6beee3b62269aa/man/man2/open.2)
明确说明普通文件/块设备的 O_NONBLOCK 不阻止等待设备活动。这里据此构造
允许的 host latency shim；不能把 shim 当作 Darwin 文件系统实测，更不能
从它推出 pipe/socket 非阻塞方案不可能。pinned 源码中的可达路径是
`fs/real.c:120-128,202-241` 的普通文件 open/read/pread/write/pwrite，
`fs/fake.c:1230-1232` 将 realfs_fdops 复制为 fakefs_fdops；因此不能以
“Node 的所有 read 都是 pipe/socket”排除普通文件读取。

**红线结果：本轮不能证明服务全部 host I/O 都有退出上限，未接通 start。**
非阻塞 pipe 的 readiness race 已解决于候选，connect/accept 状态机的 shim
也通过，但这不等于真实服务退出。write/pread/pwrite 未接入；未声称验证
部分写、满 stdout/stderr 的退出。服务 fd flag 虚拟化、sock_read/recv*/send*、
AF_LOCAL 部分握手及条件等待、独立 pending signal 的原子交接均未接入。
不把普通文件任意改报 EAGAIN/EINTR/EOF，也不把普通文件排除在服务写盘者
之外来制造成功。不引入服务外 I/O worker 来藏掉未完成写入：那只会把
未完成者移出 fence，不能满足无遗留写盘者的条件。可等待文件系统 API 或
明确约束 host 存储延迟的契约未验证；这仍是剩余工作，不是体系不可能证明。

### Linux 验证与交付界限

最初新增 regular-file harness 漏掉 stdlib.h，mkstemp 在 -Werror 下编译失败；
补上声明后通过。该错误是脚手架错误，未作为 host I/O 失败证据。
完整回归与本轮单独运行都使用按需提取的 pinned 文件，不全量展开源码包。
旧 Round 4/5 探针没有更改或开展新机制尝试，只随默认命令回归。
本轮实际改变的是本笔记、embedded-lifecycle.patch 与原 lifecycle-probes.py；
既有 Runner/build 脚本/fakefs patch 改动均保留，未改 Dart 或其他产品入口。
最终命令与结果见下方完成记录。没有 Apple SDK、Flutter、Xcode；未运行新补丁
的 iOS 编译/link、真实 guest/Node/DSH、Mac/模拟器或真机验证。协调者此前
四补丁 Mac 编译结果不覆盖这次新增加的 service registry API。

完成记录（实际执行）：

```
python3 runtime/shellbox/tests/lifecycle-probes.py /data/workspace/shellbox-validation
python3 runtime/shellbox/tests/lifecycle-probes.py /data/workspace/shellbox-validation --round6-only
bash -n runtime/shellbox/build-ios-libs.sh
git diff --check
```

完整回归 **26 组：20 组组件断言通过、6 组确认限制**；其中本轮新增
**6 组组件断言通过、1 组确认限制**。本轮定向执行在修复声明错误及完善
多 waiter 断言后通过；既有回归行为未改。runner 每次都完成四补丁按顺序
check/apply/reverse-check，以及联合应用后按构建顺序重复 reverse-check。
Shell 语法、git diff --check、两个未跟踪文本的额外行尾空白检查、Python
语法检查通过。上限断言是 shim 中的 1 秒 fence 收尾与 1000ms 完成观察，
不是对生产 guest/host 存储的时间保证。

未 commit、push、建 PR；没有临时工作树/分支需要清理。临时 C harness 及
按需源码副本由 TemporaryDirectory 清理。`/tmp/phasec6-edit.py` 和
`/tmp/phasec6-wake.py` 仅为本轮补丁编辑脚本，完成后删除。

## Round 7 — 选 B 第 1 轮：常驻 guest 的生命周期接线（2026-11-13）

本节是本轮实现与验收边界；前六轮的“不允许接通 start / 必须先实现严格有界
关停”是历史结论，不再是产品门禁。遵照 2026-11-13 09:30 的选 B 决策：保持
ShellBox `5dfc962fe5e03fe5bc6b869b8744312ebe6af627`、Ubuntu 24.04.5、
Node 24.22.3 和既有 218112716 字节 payload，不引 litter-ish、Rust host 或
异步 I/O 改造。普通文件 host read 可能迟迟不返回，**不承诺严格有界停止**。
本轮落地接线；选 B 的第 2 轮仅处理本轮验证暴露的问题。

基线仍为 `feature/ios-shellbox-dynamic-island` / `10e20b32`，所有接手时的
未提交文件保留。开工核对了状态、分支、上游和 HEAD；`git fetch origin main`
因 `.git/FETCH_HEAD: Read-only file system` 失败，不能从最新 origin/main 建立
工作分支，因此保留协调者指定工作树。没有 reset、stash、commit、push、tag、
PR、工作流、签名或 Android 源文件改动。

### 接线与所有权

- `install` 保留并使用 Phase B/C 的 bundle manifest、完整流式 SHA256/字节数
  校验、`fakefs_import`、同卷 staging 发布及 marker；成功才返回 installed。
  相同归档可重复 install，不重新导入；不同归档或不明 active 不覆盖。
  boot 后也不替换 mounted active。数据 reset 不修复/重装系统，不能借 reset
  绕过 `shellbox_upgrade_requires_reset`；基础载荷升级不在本轮范围。
- `ShellBoxKernel.c` 一生只尝试一次 boot：mount fakefs `active/data`、构造
  PID 1、准备所需 /dev 节点和 /proc。PID 1 是执行 `do_wait(WNOHANG)` 的
  常驻内核 task/host worker，负责回收直接子进程和被收养的 zombie；不运行会
  退出的 init shell，不新增 guest supervisor 进程。构造与回收由 init_lock
  串行化。失败保留现场并报告 terminal boot error，不再次 mount/init、不假装
  回滚成功。内核、mount、信号 disposition 与 PID 1 随 Runner 进程生存。
- 每次服务用 `guest_service_new` + `guest_service_thread_create` 建立唯一身份，
  entry worker 构造 PID 1 子 task 后绑定自身 registry owner，`do_execve` 后
  `task_run_current`；克隆、timer 和 stdout/stderr pump 继承服务身份。
  新增的 bind-owner / has-owner / current-service-stopping 只是 registry 接线，
  没有改变 read/connect/accept 的阻塞模型。启动过程中收到 stop 的 entry
  在执行 guest 命令前检查 stop；检查后则由登记 task 接收 guest SIGKILL。
- `start` 拒绝已有 live 会话，在同一 guest 内启动 `/usr/local/bin/dsh web
  --host 127.0.0.1 --port <系统选出的空闲端口> --no-open`。环境使用固定
  HOME/PATH，并按键值传递 env，不拼进 shell；不接受重写 HOME/PATH、
  LD_PRELOAD、NODE_OPTIONS。phoneStorage、safe profile、关闭 visualReplies
  尚无对应 iOS 实现，显式返回 `shellbox_start_options_unsupported`，不吞参数。
- 服务脚本先执行真实 guest Node，断言 `process.version === 'v24.22.3'`，
  才输出版本标记并 exec DSH。就绪要求收到这个实际输出、DSH 输出中的实际
  127.0.0.1 URL/token（端口须匹配本次选择），以及临时内存 cookie HTTP 会话完成 token 兑换/重定向后的
  回环响应 2xx/3xx；同时 command leader 尚未退出。就绪探针窗口 180 秒，
  失败走 stop，失败不报告 running。端口选择有 close/bind 竞争，失败须真实
  暴露，不能把“选择过空闲端口”写成 DSH 已监听。
  mount/exec 自身也可能受存储延迟影响；180 秒是 launch 返回后的 readiness
  窗口，不是 boot/存储调用的严格上界。
- `stop` 置服务 stopping，向该身份仍登记的 guest task 发送 SIGKILL，poll
  `guest_service_join_stopped`。不向 host 发送 SIGTERM，不调用 halt、全局
  admission stop、pthread_cancel 或强制 unmount。**只有所有服务 worker
  真正完成且 join 后**，才回收 zombie、destroy 服务句柄并进入 stopped。
  leader 退出、端口关闭、日志中断都不是这个 fence。stdout/stderr pump 同样
  属于服务 registry，读到 EOF 并完成后才允许下一服务复用日志分帧器。
- 超时取 **5 秒**：与评估中 litter-ish 的等待窗口对齐，限制用户等待停止请求
  的时间，而不是证明内核已停止。平台线程使用 monotonic dispatch deadline；
  fence 轮询也使用 systemUptime。即便控制队列在锁/存储中阻塞，UI 定时器
  仍进入 StopBlocked，保留 operationPending、原服务和 guest，不释放资源。
  原请求仍在执行时重试返回当前 blocked/busy；它返回后可重试同一服务句柄。
  deadline 后实际完成仍可如实变为 stopped，绝不以超时推定成功。
- `restart` 是同 guest 的 stop + start。StopBlocked 立即拒绝，不创建第二会话。
  start readiness 用 generation 隔离迟到 HTTP 回调，不能让上次启动的回调把
  下一次启动标成 running。服务自然退出由 status 检查触发同一 stop/fence。
- `reset` 只删除 `/root` 中未保留的数据，不删除 active、不清内核、不重新
  import。只能在无 live 会话、无 pending 操作时运行，StopBlocked 直接拒绝。
  按已存在的组名映射：uiAndSkills 保留 `.dsh/dsh-go`、`.dsh/skills`、
  `.agents/skills`；pluginsAndSettings 保留 `.dsh/profiles`、
  `.dsh/cordis.patch.yml`、`.dsh/.env`。保留根、后代与祖先按路径边界匹配。
  载荷检查确认有 GNU `/usr/bin/find`，**没有 Python**；实际执行 guest find
  的 `-xdev -depth … -delete`，不跟随 symlink、不 host rm、不复制 inode。
  删除通过 fakefs unlink/rmdir 更新 metadata。失败可有部分数据已删除，明确
  返回 `shellbox_reset_failed`；reset 命令超时也走服务 stop/fence，可能 blocked。
  iOS UI 明确说明“只清用户数据”，不再提供声称释放整套载荷空间的卸载入口。

### 状态、错误、日志与 UI

Native wire 与 Dart `RuntimePhase` / `LocalRuntimeServicePhase` 一一对应：
`notInstalled / installing / installed / starting / running / stopping /
stopped / stopBlocked / resetting / error`（Dart 保留旧 unimplemented 兼容值）。
boot 是 starting 内部的一次动作；ready 对应通过真实 readiness 的 running。

```
notInstalled -> installing -> installed
installed / stopped -> starting (首次 boot 或复用 guest) -> running
starting / running -> stopping -> stopped
                       | 5s / fence错误
                       v
                  stopBlocked -> stopping (重试原服务) -> stopped / stopBlocked
stopped / installed -> resetting (临时数据服务) -> stopped / error / stopBlocked
boot failure -> error（本 Runner 不重试 boot，须用户结束应用进程再进入）
```

`operationPending` 由 main 在调度控制操作前置位，实际控制结果回到 main 后
清除；UI 超时不清除仍在执行的操作。服务句柄只在 kernelQueue 访问，成功
fence/destroy 才设 NULL。`stopBlocked` 由 deadline/停止失败置位，只有真实
fence 成功才清除；清不掉时只保留重试和用户主动结束整个应用进程的路径。
原生重复 start/install/reset 均受相同生产谓词约束。Dart EngineControl 显式
排除 stopBlocked，不能把“不忙且不运行”解释为已停止。

错误码包括 `shellbox_stop_blocked`、`shellbox_stop_request_failed`、
`shellbox_already_active`、`shellbox_boot_failed`、`shellbox_launch_failed`、
`shellbox_readiness_failed`、`shellbox_reset_active`、`shellbox_reset_failed`。
拒绝返回当前状态 details，但移除 token，避免异常诊断带出凭据。
只有正常 status 的 running 包含实际 endpoint/token；安装身份来自真实 manifest
和 marker digest，Node 版本仅在实际断言后提供，不编造 DSH version。

stdout/stderr 用独立管道持续排空；按换行拼接、EOF 刷尾，避免 UTF-8/凭据
跨 chunk 被拆开。超过 64KiB 的整行丢到下一换行，写固定省略提示。入 2000 条
进程级 ring 前，屏蔽 env 值（包括多行各段）、观察到的 token、credential
赋值尾部、Bearer/Basic、常见 provider token、JWT、URL userinfo 和 PEM 私钥块；
先去 ANSI。没有文件日志或原始 NSError/env 日志。序号在 main 按收到的行分配，
只供排序/去重，跨 start/reset/Flutter engine 注册不归零，不改 guest 格式。
Dart 每次轮询取 logSnapshot，按 seq 排序并只发 watermark 之后的日志事件。
这些识别规则不是“任意秘密可被自动识别”的保证，诊断外发仍须人工检查。

设置引擎页、开屏安装页和安装状态 sheet 有 StopBlocked 说明与可点的“重试
停止”；重试中保持恢复卡，不能把 stopping 展示成安装完成后自动离开。
说明明确：应用切换器上滑是**用户主动结束整个 Runner 进程**，不是应用把
仍使用中的资源强制 free。中英文输入在 shellbox_lifecycle_{zh,en}.arb。

### 分层 gate 与本轮实际结果

1. **Linux 组件 gate（本轮已执行）**：
   `python3 runtime/shellbox/tests/lifecycle-probes.py /data/workspace/shellbox-validation`
   成功：原 26 组保持 **20 通过 + 6 确认限制**；新增 4 组生产状态谓词/真实
   registry 探针和 1 组 reset 命令选择/遍历探针，总计 **25 通过 + 6 确认限制**。
   四个状态组覆盖超时 StopBlocked、拒绝初始化、拒绝 reset、重试同一句柄并
   在完成后重开服务 admission；还检查 entry owner 绑定和 TLS stopping。
   reset 组执行生产 header 中的命令，在临时 host 树验证四种 keep 组合、
   symlink 外部哨兵、相似前缀和保留 inode/hardlink。它不是 fakefs SQLite
   执行，不能写成 iOS reset 通过。原 service6 非阻塞 shim 仍只是原有实验，
   本轮没有将其改造成生产 I/O。
2. **源码/构建输入 gate（本轮已执行部分）**：探针准备阶段对四补丁联合
   check/apply/reverse-check，再按构建顺序做已应用反向检查，全部通过。
   `bash -n runtime/shellbox/build-ios-libs.sh`、`git diff --check`、
   `python3 app/tool/l10n_merge.py --check` 均通过。
   新 ShellBoxKernel.c 以 `cc -fsyntax-only -Wall -Wextra -Werror -DGUEST_ARM64=1`
   对临时 patched pin 头文件通过；缺 sqlite3 开发头，使用临时**仅 opaque
   SQLite 类型声明**，只证明这份 C 的有限语法，不是完整构建/链接或 ObjC 验证。
   `python3 app/tool/l10n_merge.py --no-gen` 已合并中英文输入；普通生成命令
   在合并后因 Flutter 不存在失败。尝试把 Flutter 工具放到 /tmp 也因 GitHub
   DNS 无法解析失败。**生成的 Dart l10n 类尚未更新，必须先在 Mac 跑下面的
   生成命令才能编译新增文案 getter；没有手改生成类。**
   新增/更新的 Dart 状态、日志和 EngineControl 测试未运行（无 Flutter/Dart）。
3. **Mac 编译/模拟器 gate（未运行）**：协调者必须先生成文案并跑 Dart 检查，
   四补丁新 checkout 与同 checkout 重复构建均通过，两个 SDK 每个 5 库、
   Runner 编译/链接均成功，然后真实模拟器 install/start/stop/restart/reset。
   前轮库已编译的证据不涵盖本轮接线，Linux shim 成功不算此 gate 通过。
4. **iPhone gate（未运行）**：真机就绪、长期 DSH HTTP、前后台、存储延迟、
   重复服务周期、日志和 reset keep 需要真实设备通过；模拟器不能代替。

### 协调者 Mac 待验清单

```bash
# 必须在 Flutter SDK 可写的 Mac 环境，先生成新增文案 getter。
python3 app/tool/l10n_merge.py
python3 app/tool/l10n_merge.py --check
(cd app && flutter pub get && flutter analyze)
(cd app && flutter test test/runtime/shellbox_runtime_service_test.dart test/state/engine_control_test.dart)
bash runtime/shellbox/build-ios-libs.sh third_party/shellbox-src "$RUNNER_TEMP/shellbox-ios-libs"
bash runtime/shellbox/build-ios-libs.sh third_party/shellbox-src "$RUNNER_TEMP/shellbox-ios-libs"
(cd app && flutter build ios --debug --no-codesign)
(cd app && flutter build ios --simulator --debug)
```

- 检查新 entry registry API 的符号、Runner C/ObjC 编译、两个 SDK 的实际链接，
  特别是 do_wait、realfs stdio fd、输出 pump 与 GCD block 捕获；不引 host 库。
- install：新装、同 hash、缺/坏 manifest/archive、低磁盘、导入失败和 Runner
  中途退出；marker 不能领先真实导入成功，fakefs mode/uid/gid/link/rdev 正确。
- start：实际 Node v24.22.3、DSH 输出 URL/token 格式与回环 HTTP；重复请求
  拒绝且带当前状态，不输出 token；端口竞争/错误 Node/exec 失败不能 running。
- 同 Runner PID 多次 stop/start 与 restart：PID 1、mount、guest 身份不变，
  zombie 不积累、服务 task/timer/output worker 退出完成才释放句柄。
- 注入慢普通文件 read：5 秒进入 stopBlocked，start/restart/install/reset
  拒绝；保留 fd/mm/服务，重试不创建第二个实例。解除阻塞后重试能 stopped。
  另测请求本身等内核锁时 UI 定时器、重试期间 ownership 与失败路径。
- stdout/stderr：split UTF-8、分块 token、多行 secret、PEM、ANSI、无尾换行、
  超长行、2000 条淘汰、跨 engine 注册/stop/reset 序号递增与快照不重复。
- reset：无保留、两个单组、双组；真实 fakefs 元数据、inode/hardlink、symlink
  和 mount 边界；权限/空间/删除错误必须返回失败并承认部分修改。保持基础
  payload 与 PID 1，随后同 guest start；失败/超时不能当成成功清空。
- UI：开屏、状态 sheet、设置页 blocked 与重试可点；重试中不自动“安装完成”
  跳页；数据 reset 不宣传重装/释放系统空间。用户上滑结束应用后的新 Runner
  才能重新初始化 guest。unsupported 启动选项须可见，不静默忽略。

**本轮交付尾记：**做了 install 延续接线、常驻 PID 1/单服务、真实版本与回环
readiness、5 秒 stop/fence/StopBlocked、同 guest restart、keep 数据 reset、
真实 stdout/stderr 脱敏与 seq、Dart/UI 接线。Linux **25 通过、6 确认限制**，
四补丁与静态输入检查通过。未做异步 I/O、内核拆卸/强制释放、换运行时、
Android/工作流/签名、commit/push；未声称 iOS 编译/模拟器/真机通过。
还剩：Mac 先补 l10n 生成，再按上述编译、模拟器与真机 gate 验收；选 B 第 2
轮只修这些验收发现的问题。当前是待 Mac 验证的接线工作树，不是已验收本地模式。

本轮接线收尾核对了 payload 中的真实 `dsh-web-app` 与
`dsh-client-connection` 源码：URL 来自 `authenticatedUrl(baseUrl)` 的 query
process token；未登录 index 返回 401，token 请求会设置 cookie 并重定向。
因此 readiness 使用实际观察到的 token 发起仅内存的 ephemeral cookie 兑换，
不请求无 token 的 root 后错误地期待 200，也不把临时凭据写到磁盘日志。
最后复核仍为 25 通过、6 限制；C 有限语法、四补丁、shell、文案输入和 diff
检查通过。未做 iOS/Flutter 验证或提交推送；剩余仍是 Mac 先生成 l10n，再按
上一节执行双 SDK/Runner 编译、模拟器与真机清单。

## Round 8 diagnostics — Option B Round 2, final round

### Evidence and scope

D1 establishes sequential DSH restarts, not concurrent instances or an app
restart: app PID 37287 stayed alive, with one readiness connection to 63979
and subsequently one to 64300. The original trigger remains unpinned; neither
a Restart-button tap nor an automatic caller can be inferred from those logs.
This round records the caller of subsequent requests.

ShellBox remains pinned at 5dfc962, Node at 24.22.3. No Android native files,
workflows, signing, or guest I/O changes. Existing uncommitted Round 7 work
is retained on the requested branch. No commit, push, reset, or stash.

### A — implemented; Apple integration verification pending

Files: app/ios/Runner/ShellBoxPlugin.m, ShellBoxKernel.c/h;
app/lib/runtime/runtime_bridge.dart, runtime_state.dart,
shellbox/shellbox_runtime_bridge.dart, state/engine_control.dart. Tagged caller files:
state/{access_state,permission_default_repair,phone_state,plugin_reload}.dart;
ui/chat/chat_screen.dart; ui/engine/engine_screen.dart;
ui/features/permission_page.dart; ui/onboarding/local_install.dart;
ui/plugins/plugin_actions.dart; ui/safe_mode/safe_mode_actions.dart;
ui/settings/personalization_page.dart; ui/share_code/import_sheet.dart;
ui/shell/{root_gate,sessions_drawer}.dart; ui/web/local_web_screen.dart.

Native start/reset/install additionally reject a retained service handle even
if the phase says error. The pending-operation predicate is checked first,
avoiding a handle read during a worker's publication. Restart keeps
stop-then-start and the generation guard. Interrupted readiness logs its
captured original caller and returns shellbox_start_interrupted. StopBlocked
continues to retain resources and forbid restart; only a successful completion
fence admits another service. DSH restart does not boot another kernel.

On ShellBox, Dart restart/ensureStarted and the stop confirmation query native
status instead of trusting a stale polled Dart phase. Other runtimes retain
their existing channel behavior. Caller metadata uses a Dart Zone, so overlapping
asynchronous actions cannot overwrite each other's tags. Callers include
engine_screen.restart, engine_screen.stop, ensureStarted.chat,
ensureStarted.web, safe_mode.retry, phone_toggle, plugin_reload,
permission_repair, access_apply, share_import, personalization,
auto_start.launch, and onboarding/drawer/plugin actions. Untagged direct calls
explicitly say runtime.direct; transitions use the accepted operation's source.

Exact format: prefix "shellbox.lifecycle " followed by one sorted JSON object.
Illustrative values, NOT a collected guest line:

    shellbox.lifecycle {"appPid":37287,"dshPid":2,"event":"transition","flutterLifecycle":"resumed","guestInitPid":1,"phase":"running","runtimeInstanceId":"<native UUID>","source":"engine_screen.restart","startedAt":"<ISO-8601 UTC>","timestamp":"<ISO-8601 UTC>","webPort":64300}

Field names: event, timestamp, appPid, runtimeInstanceId, guestInitPid, dshPid,
webPort, startedAt, flutterLifecycle, source, phase. Runtime Instance ID is
allocated natively for the resident boot attempt, stays stable across DSH
restarts, and changes only for a new resident runtime. startedAt is the
accepted DSH start timestamp. Before init/start some values are null/zero.
dshPid is the last observed guest command PID, not a liveness claim; phase and
the completion fence determine ownership/liveness. At launch completion the
command may still be the provisioning shell.

Events cover lifecycle requests, transitions, selected port, launch completion,
Flutter lifecycle changes, rejection/error codes, and start.interrupted.
No arguments/env dumps, credential URLs, API keys, tokens or message content.
These lines enter the native guest-log ring and Dart's logSnapshot/events;
diagnostics_bundle.dart already falls back to bridge.logs/localRuntimeLogs.
Existing guest-output redaction remains.

Linux exercises running rejecting a second start with the original handle
retained, then actual service completion/destruction and successful creation
of another service. This is component evidence, not an Objective-C integration
test. The caller-tag channel test checks source survives asynchronous stop/start.

### B — startup provisioning implemented; guest HTTPS/chat NOT verified

Files: app/ios/Runner/ShellBoxPlugin.m and the exact-startup-JavaScript fixture
in runtime/shellbox/tests/lifecycle-probes.py.

The required Node version-check process now provisions files through guest fs
syscalls before launching DSH, preserving fakefs metadata:

- Missing/empty /etc/resolv.conf gets nameserver 1.1.1.1 followed by
  nameserver 8.8.8.8, each on its own line. These public resolvers do not depend
  on the Mac's private network. Networks blocking public DNS need follow-up;
  universal reachability is not claimed.
- Missing/empty /etc/hosts gets 127.0.0.1 localhost and ::1 localhost.
- Missing/empty /etc/ssl/certs/ca-certificates.crt gets PEM roots exported from
  the pinned Node's built-in tls.rootCertificates, using trust roots already
  shipped inside Node rather than a new downloaded binary.

Nonempty files are preserved. Failure exits before DSH launches, not silent
success. Both fresh and already-installed copies receive this on their next
confirmed stop/start. No reinstall or payload rebuild is required, so
payload/MANIFEST.json and the 218 MB archive are unchanged. No proxy or
provider/model/credential changes. Node normally also has built-in trust roots:
an absent system CA file alone does not establish that Node TLS was failing.
DNS remains the leading diagnosed mechanism; a system CA bundle is now supplied.

Expected literal guest markers: DSH_GO_NETWORK_CONFIG=ready followed by
DSH_GO_NODE=v24.22.3. These are NOT observed post-change guest-log evidence.
The Linux fixture executes the exact embedded JavaScript with guest fs mapped
to a fixture, checks empty-file repair, PEM output, markers, and preservation
of nonempty files. It does not exercise guest DNS/TLS or the pinned guest Node.

Coordinator Mac check: rebuild app, confirmed stop/start on existing install,
inspect all three files, capture actual model-listing outcome and a chat turn
with llmMs > 0 and decodeTokens > 0. No post-change guest log is available on
this Linux VM. No successful DeepSeek guest-log line or new failure error can
yet be reported. If listing fails, report its exact new error; the provisioning
marker alone does not establish network success.

### C — removal fallback implemented; guest stderr NOT verified

Files: runtime/shellbox/remove-unshipped-preload.patch, build-ios-libs.sh,
and tests/lifecycle-probes.py.

Preferred binary shipping was not feasible: the verified pinned checkout has
no zero_free source and a source search did not identify a verifiable matching
implementation. No speculative replacement/unverified arm64-glibc binary is
shipped. A reproducible fifth patch removes both LD_PRELOAD=/lib/zero_free.so
injections (kernel/exec.c and xX_main_Xx.h). The build script applies it after
existing patches and accepts both pristine and already-patched checkouts.
Stderr is not filtered.

Security/correctness assessment: removing an injection of a nonexistent library
does not change allocator or memory-access behavior observed in D2: ld.so was
already ignoring it. It introduces no allocator implementation and changes no
ownership rules. It does not fix or conceal use-after-free. The intended
protection is explicitly lost: freed memory is no longer scrubbed by zero_free
(and was not scrubbed in the verified installed rootfs). Keys/tokens in freed
buffers can remain until reuse and be exposed by memory disclosure or a
same-process compromise. This is acceptable for this app's current sandboxed,
single-user runtime as a disclosed limitation, not a secure-erasure guarantee.
A verified scrubber would need independent allocator/Node testing. Upstream's
comment also mentions V8 stale-pointer mitigation; generic zeroing is not a
memory-safety proof.

Linux checks five-patch apply/reverse/rebuild and absence of the preload
assignment in both patched entrypoints. Mac must rebuild the ShellBox static
libraries; restarting an old app cannot apply this source patch. No fresh
guest log was collected here: warning disappearance and continued Node/DSH
operation are NOT claimed. Coordinator must capture fresh stderr without
"LD_PRELOAD cannot be preloaded", plus Node 24.22.3 and DSH readiness.

### D — implemented; simulator/phone foreground acceptance pending

Files: app/lib/app.dart, runtime/runtime_state.dart, state/engine_control.dart,
test/state/engine_control_test.dart.

iOS lifecycle events are logged natively. On resumed, query native status and
refresh Dart unless a later query/event superseded that snapshot. Running
creates a fresh authenticated local DSH connection through the existing
connection provider. Starting remains starting; polling connects when running.
Resume issues no start/restart/stop/reset and destroys no native resources.
Stopped/installed/error can subsequently start through existing user/auto-start
policy; ensureStarted first checks native status. StopBlocked remains visible
and does not start. Suspension itself never sets stopped.

Tests start with stale Dart error and verify native running/stopped/StopBlocked
replace it; resume itself never starts. Subsequent ensureStarted is admitted
only for native stopped. Apple simulator and real iPhone validation were not
run on Linux.

### E — fixed in test harness; production polling unchanged

File: app/test/runtime/shellbox_runtime_service_test.dart.

Instrumented reproduction with Flutter 3.50.0 and repository Flutter 3.47.7:
first-listener assertions passed, subscription.cancel() returned, and the
subsequent fake-clock tester.pump(2s) never returned. Converted the pure
channel/timer test to plain asynchronous waits. Round 7's guest-log polling
test also stalled in the widget-clock setup and now uses real waits.
Original assertions remain: deduplication, notices, cancellation halting polls,
resubscription, ordered logs and no snapshot duplication. Production polling
was not changed. This isolates the observed stall to the widget-clock test
setup; no upstream fake-clock root cause or native-resource cause is claimed.

### Linux verification and open acceptance

Flutter 3.47.7 / Dart 3.13.5 (revision matches app/.metadata); SDK installed
outside the repo. CJK fonts installed for the existing test-font contract.
The initial accidental Flutter 3.50.0 check reported widespread existing
Material/Cupertino deprecations; no app code was changed to silence them.
SDK-created lockfile/analyzer edits were restored; generated l10n files were
produced by Flutter from the Round 7 ARB inputs.

- flutter analyze --no-pub (in app): exit 0, "No issues found!", 5.6 s.
- flutter test --no-pub with shellbox_runtime_service_test.dart,
  engine_control_test.dart, onboarding/parallel_setup_test.dart,
  onboarding/runtime_setup_diagnostics_test.dart,
  onboarding/runtime_setup_keep_test.dart and shell/root_gate_autostart_test.dart:
  exit 0, 63 tests passed, 8 s. Includes the original channel cases,
  new source-tag case, all resume cases, remote onboarding and launch policy.
- Final two-file-only run: exit 0, 17 tests passed in 4 s, no hang.
- python3 runtime/shellbox/tests/lifecycle-probes.py
  /data/workspace/shellbox-validation: exit 0; 29 PASS lines (including patch
  chain and the three Round 8 checks), 6 CONFIRMED LIMITATION lines,
  3 TRIAL REJECTED lines, 1 EXPECTED LIMITATION and 1 RESTORED status.
  These counts are component evidence, not iOS acceptance.
- python3 app/tool/l10n_merge.py --check: exit 0, 73 parts / 7339 keys.
- git diff --check: exit 0.

Raw Linux command outputs (outside git): /data/workspace/round8-probes-final.log,
round8-tests-two-files.log, round8-tests-validation.log,
round8-analyze-app-final.log. No credentials were used in these checks.

Still open: Apple compilation/link, fresh guest stderr and real DNS/TLS/model
listing/chat-token evidence for B/C, and simulator plus physical iPhone
background/foreground acceptance. No B/C post-change guest-log lines exist
here to prove success; these checks must be supplied by the coordinator.
