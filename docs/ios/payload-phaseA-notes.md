# Phase A: ShellBox local-runtime payload

## State and scope

Round 2, server date 2026-11-12 UTC. Reverified before work:
`43ee14763cfa540e8e0ea475aed0a961ba1239b8`, branch
`feature/ios-shellbox-dynamic-island`; initial status was just this note and
`payload/` from Round 1. Continued on this branch as explicitly requested;
no fetch, commit or push. Round 1 DNS failures were sandbox-only; downloads
succeeded in Round 2 with sandbox disabled. The original blocked manifest is
superseded by an assembled-input manifest, retaining the Round 1 cause.

**Payload assembled; Node 24 under ShellBox: NOT RUN.** No Mac logs have been
received. No iOS build, simulator guest run, or real-device result is claimed.
This Linux server did not compile macOS/iOS code. The coordinator must run the
fixture below on the cloud Mac. A host-CLI pass establishes this engine/payload
combination on Mac ARM64, not Runner embedding or real-device operation.

No app, lifecycle, onboarding, Android, workflow, engine source or pin was
modified. The existing install/start errors remain unimplemented. No signing,
IPA, Apple ID or Actions run. Only this note, the manifest and the explicitly
requested large archive are left untracked in the repository. Fixture and
assembly evidence live separately outside the repository.

## Base decision and evidence

**First probe: Ubuntu Base 24.04.5 arm64, official glibc Node 24.22.3.**
[Node v24 platform policy](https://github.com/nodejs/node/blob/v24.x/BUILDING.md)
lists Linux arm64/glibc as Tier 1. The downloaded official archive's interpreter
is `/lib/ld-linux-aarch64.so.1`; its seven DT_NEEDED entries resolve in this
Ubuntu base, including libstdc++ and libgcc, without extra debs. This is static
assembly evidence, not emulation evidence. Pinned `kernel/exec.c:164-190`
handles PT_INTERP generically. Additionally, pinned
`tests/integration/rootfs.sh:15-30,62-66` explicitly defines glibc guest coverage
and an Ubuntu 26.04 input for upstream integration tests. That strengthens the
case for trying glibc, but is neither an executed test log nor proof for our
Ubuntu 24.04/Node 24 combination. No Node 24 compatibility log was found.

**Fallback once after actual Ubuntu failure: Alpine aarch64.** Pinned
`README.md:91` documents Alpine + `tools/fakefsify`; both `tools/fakefsify.c`
and `tools/fakefs.c` remain present at commit
`5dfc962fe5e03fe5bc6b869b8744312ebe6af627`. Pinned integration smoke defaults
to Alpine and `kernel/exec.c` contains a musl loader accommodation. Against
that, Node's v24 policy marks musl experimental; do not treat an inferred
arm64-musl filename as a supported distribution. The fetched
[Alpine 3.24 aarch64 index](https://dl-cdn.alpinelinux.org/alpine/v3.24/main/aarch64/APKINDEX.tar.gz)
actually advertises `nodejs 24.22.3-r0`, which meets >=24.9.0. It is a fallback
candidate with its own shared-library dependency closure, not assembled yet.
The official Node v24.22.3 SHASUMS has no arm64-musl tarball; the release index
lists only linux-x64-musl. No unverified musl binary was substituted.

Read-only comparison: [shellbox-rootfs](https://github.com/lollipopkit/shellbox-rootfs)
publishes normalized Linux tar images plus a signed manifest. Its trust/delivery
scheme was not adopted and its images were not substituted for our pinned
inputs. Our manifest records provenance, not an app delivery contract.

## Artifact and verified inputs

Archive on this server:

```text
/data/workspace/dsh-go/payload/rootfs-ubuntu24.04.5-node24.22.3-dsh0.2.2-rc.1-arm64.tar.gz
sizeBytes: 218112716
sha256: b55564360f41aa14ddd57a9807771ae06de0ca7961ec33fdc9d0d4597d72ac65
```

Manifest: `/data/workspace/dsh-go/payload/MANIFEST.json`. It includes exact
URLs, sizes, SHA256, upstream verification method, lock integrity for every
installed npm package, patch-file hashes and local lock/assembler hashes.

| Input | Exact version/source | Verification |
| --- | --- | --- |
| Base | [Ubuntu Base 24.04.5 arm64](https://cdimage.ubuntu.com/ubuntu-base/releases/24.04/release/ubuntu-base-24.04.5-base-arm64.tar.gz) | SHA256 `a91d5a93010193712d346d761372b7c9db6dfcf093893161c64ca107f05914f2`, 29936675 bytes; matched official SHA256SUMS |
| Guest Node | [24.22.3 linux-arm64](https://nodejs.org/dist/v24.22.3/node-v24.22.3-linux-arm64.tar.xz) | SHA256 `6e51a2ada00f0011cc266f65d98922b403d7ad88f809ca2aa615a5fe1ce6e86c`, 30991864 bytes; matched official SHASUMS256.txt |
| Assembly host Node | [24.22.3 linux-x64](https://nodejs.org/dist/v24.22.3/node-v24.22.3-linux-x64.tar.xz) | SHA256 `4f2b175a6d53a5c617a80dba2676238a0688cef28c6da4eba35c7d844e66fcfb`, 32064292 bytes; matched official SHASUMS256.txt; excluded from payload |
| DSH | `0.2.2-rc.1`, `runtime/locks/dsh-0.2.2-rc.1/package-lock.json`; locked `https://registry.npmmirror.com/@deepseek-ai/dsh/-/dsh-0.2.2-rc.1.tgz` | npm ci with ignore-scripts, cpu=arm64, os=linux, libc=glibc; lockfile unchanged |
| pnpm | `11.28.5`, `runtime/locks/pnpm-11.28.5/package-lock.json` | same locked npm ci process; guest plugin-install tool, not used to install DSH |

Node index dated 2026-11-10 lists v24.22.3 as the newest 24.x LTS (Krypton),
so the older Android default 24.22.1 was not selected. No Node 25/26 downgrade
or upgrade route was taken. Checksums were fetched from upstream over HTTPS;
no claim of separate GPG signature verification is made.

## Assembly and layout

Temporary assembly files: `/tmp/dsh-phaseA-build/`. Persistent evidence and
copies of the assembly/download scripts: `/data/workspace/dsh-phaseA-evidence/`.
The scripts use the checked-in lockfiles and helper's ELF/patch routines only;
the Android builder was read as a reference, never executed or copied as an
iOS installer. Successful install logs, patch log, source checksum tables,
assembly report and temporary Mac fixture are in the evidence directory.

Host npm was 11.19.1 from verified Node 24.22.3. Both npm ci commands use
`--cpu=arm64 --os=linux --libc=glibc --ignore-scripts --no-audit --no-fund`,
empty separate user/global npmrc files and a private temporary npm cache.
Every installed package cache blob was independently rehashed against the
lock's integrity after install: **595 records** in the manifest, with SHA256,
size and exact locked URL. An initial local npm configuration error from using
one file as both user and global config was fixed before the successful install;
no source failure or alternate package substitution occurred.

The payload applies all **136** patches from the repository series using:

```bash
python3 -I runtime/lib/rtbuild.py patch-dsh \
  --prefix /tmp/dsh-phaseA-build/dsh --dsh-version 0.2.2-rc.1 \
  --out /tmp/dsh-phaseA-build/applied-patches.json
```

Strict before/after pins all matched. These are source fixes in the DSH tree;
Android runtime launch scripts, overlays, direct-engine preload, phone bridge
and phone integration configuration are not included. Applying the pinned
DSH fixes does not enable phone integration in this standalone payload.

Guest layout:

- Ubuntu paths at archive root, with base package metadata and licenses retained.
- `/opt/node`: complete official arm64 distribution (including npm/licenses).
- `/opt/dsh`: locked npm prefix, patched DSH; CLI is `node_modules/@deepseek-ai/dsh/lib/bin.js`.
- `/usr/local/lib/node_modules/pnpm`: locked pnpm package.
- `/usr/local/bin/{node,npm,npx,corepack,pnpm,pnpx}`: guest symlinks.
- `/usr/local/bin/dsh`: shell wrapper executing the locked CLI with guest Node.
- `/opt/phaseA/smoke.cjs`: temporary guest-only compute/HTTP verification script.
- `/dev`, `/proc`, `/sys`, `/tmp`, `/root`: present for engine setup; no Android mounts.

Archive is gzip POSIX pax tar, root paths without an enclosing directory,
root-owned with fixed mtimes. Foreign platform prebuilds and musl ELF variants
were pruned (39 files). No Node binary patch or Node 22 offsets were applied.
736 retained ELF objects were inspected: arm64, interpreters and DT_NEEDED
resolved using guest RUNPATH plus standard guest library directories. This
checks static closure only, not symbol-version compatibility or syscall support.
The archive was read back: 41918 unique members, required Node/DSH/pnpm/smoke
files present. No generated fakefs database was made on Linux.

Pinned `tools/fakefs.c:73-110` imports gzip tar into `guest/data/` +
`guest/meta.db` (SQLite). Import **on the Mac filesystem**, then pass the parent
`guest` to `ish -f`; do not move a Linux-created fakefs database with different
inode associations. Pinned `main.c` already sets guest HOME=/root and PATH;
the fixture does not overwrite the host HOME.

Pinned `xX_main_Xx.h` and `kernel/exec.c` inject Node V8 flags including jitless,
no-lazy and predictable. They also inject `LD_PRELOAD=/lib/zero_free.so`.
That library is absent in this verified glibc payload: no known Node24/glibc
binary was supplied by the pin. A glibc loader warning about its absence must
be retained in stderr. If Node then fails, diagnose from the real log; do not
assume copying a Node22/musl workaround fixes it. README_arm64.md documents
Node22 guard-page/trampoline fixes, not Node24 validation.

## Coordinator: exact Mac transfer and run

Run this **on the cloud Mac** in bash. It asks for the existing SSH target of
this Linux server because this session has not been given that target. No SSH
from this server to the Mac is attempted. Alternatively use the coordinator's
existing transfer channel for the same three files, then run the final command.
The large archive is a temporary handoff, not Runner resource bundling.

```bash
/bin/bash <<'TRANSFER'
set -euo pipefail
read -r -p 'Linux server SSH target (user@host or configured alias): ' DSH_SERVER < /dev/tty
mkdir -p "$HOME/dsh-phaseA-input"
scp "${DSH_SERVER}:/data/workspace/dsh-go/payload/rootfs-ubuntu24.04.5-node24.22.3-dsh0.2.2-rc.1-arm64.tar.gz" "$HOME/dsh-phaseA-input/"
scp "${DSH_SERVER}:/data/workspace/dsh-go/payload/MANIFEST.json" "$HOME/dsh-phaseA-input/"
scp "${DSH_SERVER}:/data/workspace/dsh-phaseA-evidence/run-mac.sh" "$HOME/dsh-phaseA-input/"
/bin/bash "$HOME/dsh-phaseA-input/run-mac.sh"
TRANSFER
```

Fixture prerequisite: clean pinned engine checkout at `~/shellbox-validation`
(or set `SHELLBOX_SRC=/actual/path` for the final command), Meson, Ninja,
pkg-config, Homebrew LLVM/lld and libarchive, Xcode command-line tools. No
prerequisite installation is silently attempted. Configuration/build/import
failures stop with logs; they do not establish Node incompatibility. Existing
integration smoke was inspected, but its broad OS cases do not probe our Node24
payload; the fixture reuses the pinned engine's own host `ish` CLI and importer
without any new app/test target.

Temporary fixture is outside the repo and must not be committed or included in
the formal source submission. The following is its complete reviewable content:

```bash
#!/bin/bash
# TEMPORARY Phase A host-CLI fixture; not an app target or formal submission.
set -euo pipefail
SHELLBOX_SRC="${SHELLBOX_SRC:-$HOME/shellbox-validation}"
INPUT_DIR="${INPUT_DIR:-$HOME/dsh-phaseA-input}"
PATCHES_DIR="${1:-$HOME/dsh-phaseA-input/patches}"
NAME=rootfs-ubuntu24.04.5-node24.22.3-dsh0.2.2-rc.1-arm64.tar.gz
RUN="$(mktemp -d /tmp/dsh-phaseA.XXXXXX)"
printf 'Fixture/log directory: %s\n' "$RUN"
exec > >(tee "$RUN/fixture.log") 2>&1
printf 'Mac fixture start: '; date -u
uname -a
xcodebuild -version
xcrun simctl list devices booted
# This host CLI tests the pinned engine on Mac ARM64. It does not test iOS embedding.
test "$(uname -m)" = arm64
test "$(git -C "$SHELLBOX_SRC" rev-parse HEAD)" = 5dfc962fe5e03fe5bc6b869b8744312ebe6af627
git -C "$SHELLBOX_SRC" diff --exit-code
git -C "$SHELLBOX_SRC" diff --cached --exit-code
# Check cleanliness before applying build-time patches to the pinned checkout.
shopt -s nullglob
patches=("$PATCHES_DIR"/*.patch)
test "${#patches[@]}" -gt 0 || { echo "No patches in $PATCHES_DIR" >&2; exit 1; }
for patch_file in "${patches[@]}"; do
    shasum -a 256 "$patch_file"
    git -C "$SHELLBOX_SRC" apply --check "$patch_file"
    git -C "$SHELLBOX_SRC" apply "$patch_file"
done
test -f "$INPUT_DIR/$NAME"
printf '%s  %s\n' b55564360f41aa14ddd57a9807771ae06de0ca7961ec33fdc9d0d4597d72ac65 "$INPUT_DIR/$NAME" | shasum -a 256 -c - | tee "$RUN/input-sha256.txt"
# Prerequisites only; no package installation or signing in this fixture.
command -v brew
export PATH="$(brew --prefix llvm)/bin:$PATH"
export PKG_CONFIG_PATH="$(brew --prefix libarchive)/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
command -v meson
command -v ninja
command -v ld.lld
pkg-config --exists libarchive
meson setup "$RUN/build" "$SHELLBOX_SRC" -Dguest_arch=arm64 -Dno_crlf=true --buildtype=release > "$RUN/configure.log" 2>&1
ninja -C "$RUN/build" ish tools/fakefsify > "$RUN/build.log" 2>&1
"$RUN/build/tools/fakefsify" "$INPUT_DIR/$NAME" "$RUN/guest" > "$RUN/import.log" 2>&1
# Keep stderr separate and raw. A watchdog bounds a hung guest without requiring GNU timeout.
probe() {
    local label="$1" limit="$2" pid watcher rc
    shift 2
    "$RUN/build/ish" -f "$RUN/guest" "$@" < /dev/null > "$RUN/$label.stdout" 2> "$RUN/$label.stderr" &
    pid=$!
    (
        sleep "$limit"
        if kill -0 "$pid" 2>/dev/null; then
            printf 'TIMEOUT %s after %ss\n' "$label" "$limit" > "$RUN/$label.timeout"
            kill -TERM "$pid" 2>/dev/null || true
            sleep 2
            kill -KILL "$pid" 2>/dev/null || true
        fi
    ) &
    watcher=$!
    set +e
    wait "$pid"
    rc=$?
    kill "$watcher" 2>/dev/null
    wait "$watcher" 2>/dev/null
    set -e
    printf '%s\n' "$rc" > "$RUN/$label.exit"
    printf '\n%s exit=%s\n' "$label" "$rc"
    cat "$RUN/$label.stdout" "$RUN/$label.stderr"
    test ! -f "$RUN/$label.timeout" || { cat "$RUN/$label.timeout"; return 124; }
    return "$rc"
}
probe 01-boot 180 /bin/sh -c 'echo PHASE_A_GUEST_BOOT; /bin/uname -m'
grep -qx PHASE_A_GUEST_BOOT "$RUN/01-boot.stdout"
probe 02-node-version 180 /opt/node/bin/node --version
grep -qx v24.22.3 "$RUN/02-node-version.stdout"
probe 03-js 300 /opt/node/bin/node /opt/phaseA/smoke.cjs
grep -qx 'PHASE_A_JS_OK 499500' "$RUN/03-js.stdout"
grep -qx PHASE_A_HTTP_OK "$RUN/03-js.stdout"
grep -qx PHASE_A_LOOPBACK_CLOSED "$RUN/03-js.stdout"
probe 04-dsh 300 /opt/node/bin/node /opt/dsh/node_modules/@deepseek-ai/dsh/lib/bin.js --version
grep -qx '0.2.2-rc.1' "$RUN/04-dsh.stdout"
printf '\nPHASE_A_MAC_HOST_CLI_PASS\nLogs: %s\n' "$RUN"
```

The script prints its `/tmp/dsh-phaseA.XXXXXX` directory before building.
Logs there: `fixture.log`, `input-sha256.txt`, `configure.log`, `build.log`,
`import.log`, then `01-boot`, `02-node-version`, `03-js`, `04-dsh` each with
`.stdout`, `.stderr`, `.exit` and `.timeout` only if timed out. It stops at the
first unsuccessful layer. Timeouts are 180 seconds for boot/version and 300
seconds for JS/DSH; they are failures to diagnose, never passes. It uses no
VM-service/WebSocket probe, no signing and no interactive DSH startup.

Expected stdout markers (requirements, **not observed log lines**):

```text
PHASE_A_GUEST_BOOT
aarch64
v24.22.3
<process.versions JSON, including node and v8>
PHASE_A_JS_OK 499500
PHASE_A_LOOPBACK <ephemeral port>
PHASE_A_HTTP_OK
PHASE_A_LOOPBACK_CLOSED
0.2.2-rc.1
```

Each probe must exit 0, with raw stderr retained. Only then does the fixture
print `PHASE_A_MAC_HOST_CLI_PASS`. Send the complete printed log directory back,
including failed configure/build/import logs. A fresh host CLI build is done
on the Mac; this session has not proved that build. No Mac `node --version`
line exists yet to quote. Existing simulator boot is logged as context only;
this host fixture does not launch Runner on the simulator.

## Failure handling and handoff

No failing guest layer has yet been established; no base attempt or rerun budget
has been consumed. On actual failure quote the raw lines, classify importer /
boot / loader / V8 / JS-network / DSH, and fix only payload inputs in scope.
Request one rerun after a payload correction. If the same layer still fails,
stop that attempt. Try Alpine once if Ubuntu fails. If both bases show Node24
failure, or the pin cannot boot the payload, report the evidence and stop;
changing the engine pin requires separate verification. A fixture toolchain
failure is not evidence that Node24 is impossible. Do not claim “证实不可行”
without the required guest evidence.

Repository state expected at handoff:

```text
?? docs/ios/payload-phaseA-notes.md
?? payload/
```

No tracked file changed. Archive, manifest, design note remain uncommitted.
Round 2 elapsed time is recorded in the final response; exact token accounting
is not exposed by this session, so no exact token total is claimed.

## Round 3 — Node 24 build-time flag fix (supersedes Round 2 status)

Reverified HEAD `43ee14763cfa540e8e0ea475aed0a961ba1239b8`; same requested
branch. Round 2 sections above describe the original handoff. The embedded
fixture above now reflects Round 3. No payload rebuild, commit or push.

Coordinator-reported Mac run 1 (2026-11-13 01:51 UTC), fixture/log directory
`/tmp/dsh-phaseA.rZDfN8`: boot exit 0, Node version exit 9; JS/DSH not run.
Raw lines supplied by the coordinator (not independently opened on this server):

```text
PHASE_A_GUEST_BOOT
aarch64
ERROR: ld.so: object '/lib/zero_free.so' from LD_PRELOAD cannot be preloaded (cannot open shared object file): ignored.
/opt/node/bin/node: bad option: --no-expose-wasm
```

Coordinator also reports copying the same guest binary to `/tmp/node24`
printed `v24.22.3`, rc=0. This diagnoses the basename-dependent initial-exec
flag injection; it does not establish JS/HTTP/DSH success. Corrected fixture
Mac verification remains **PENDING**, with no iOS or real-device claim.

`runtime/shellbox/fix-node24-v8-flags.patch` removes the single flag occurrence
in pinned `xX_main_Xx.h:238`. Node 24 V8 no longer accepts this flag; its former
Wasm-exposure suppression is no longer available via the removed flag. Every
other injected flag stays unchanged. Probe 03 (compute and loopback HTTP) is
the regression tripwire; no replacement Wasm workaround is introduced.
`build-ios-libs.sh` applies this patch after the duplicate-gadgets patch, using
the same apply-check / reverse-check idempotence pattern. The pin stays 5dfc962.

`rg -n -- 'no-expose-wasm|zero_free|LD_PRELOAD'` found the preload injection in
`xX_main_Xx.h:328-336` and `kernel/exec.c:902-925`. The latter describes zeroing
large malloc/free blocks for V8 Zone reuse. Decision: defer this secondary
warning, keeping both injections and the archive unchanged. Shipping an
unverified library or deleting allocator-related behavior would expand this
single-flag fix. The actual loader explicitly says `ignored`; preserve stderr
in the rerun. The warning is not a pass/fail criterion.

Temporary fixture accepts a patches directory as argument 1 (default
`$HOME/dsh-phaseA-input/patches`), checks pinned HEAD and tracked cleanliness
BEFORE applying every `*.patch`, logs patch hashes, then builds. All four probe
commands/expectations remain unchanged. Use the same clean pinned source as
run 1; the fixture intentionally leaves applied patches visible in that source.
A subsequent invocation requires a clean checkout again; do not discard unrelated
changes to obtain one.

### Exact coordinator rerun commands (on cloud Mac)

Archive and manifest already transferred for run 1 remain valid; no retransmit
of the archive is needed. Copy only the new flag patch into the fixture patches
directory; the host CLI in run 1 already linked without the duplicate-gadgets
patch. Formal iOS library builds apply both through build-ios-libs.sh.

```bash
/bin/bash <<'RERUN'
set -euo pipefail
read -r -p 'Linux server SSH target (user@host or configured alias): ' DSH_SERVER < /dev/tty
mkdir -p "$HOME/dsh-phaseA-input/patches"
scp "${DSH_SERVER}:/data/workspace/dsh-go/runtime/shellbox/fix-node24-v8-flags.patch" "$HOME/dsh-phaseA-input/patches/"
scp "${DSH_SERVER}:/data/workspace/dsh-phaseA-evidence/run-mac.sh" "$HOME/dsh-phaseA-input/"
/bin/bash "$HOME/dsh-phaseA-input/run-mac.sh" "$HOME/dsh-phaseA-input/patches"
RERUN
```

The printed fresh `/tmp/dsh-phaseA.XXXXXX` directory contains all raw logs as
listed above. Required results remain exactly `v24.22.3`,
`PHASE_A_JS_OK 499500`, `PHASE_A_HTTP_OK`, `PHASE_A_LOOPBACK_CLOSED`, and
`0.2.2-rc.1`, all probes exit 0. If the corrected probe fails, return its stdout,
stderr and exit file; do not claim success or make another engine change.
