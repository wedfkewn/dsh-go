# ShellBox + Node 24 feasibility validation

Date: 2026-11-12. ShellBox: `5dfc962fe5e03fe5bc6b869b8744312ebe6af627`. dsh-Go baseline: `288234ae52fdfcfc2b0a0388763c371d0b09ea7d`, branch `feature/ios-shellbox-dynamic-island`. Machine: Debian 13.7, Linux x86_64 (`uname -m`, `/etc/os-release`, `git rev-parse HEAD` executed). Validation only; no app implementation, commit or push.

Evidence paths beginning `ShellBox/` mean `/data/workspace/shellbox-validation/`; other repository paths mean `/data/workspace/dsh-go/`. Each conclusion carries one of the four required English labels. Chinese execution markers are used only for counting actual tests: 已实际验证 / 未测试. Reading code is never counted as a pass.

(you ran it on this machine) Read stage-1 `docs/ios/architecture-audit.md`, CONTRIBUTING.md and docs/architecture.md. Initial status: branch above, `?? docs/ios/`; existing audit preserved. `git fetch origin main` failed: `cannot open '.git/FETCH_HEAD': Read-only file system`; remote freshness is unavailable. No branch or worktree created because only this report is authorized.

## 1. License conclusion

(you read code/docs but did not run it) Read **all** of ShellBox/LICENSE.md (35 lines) and LICENSE.IOS (12 lines). LICENSE.md:1-5 specifies GPLv3 plus LICENSE.IOS, with contributions after `0e3a4144f93135c4fd618c8397d2cfd87194f69f` additionally GPLv2; lines 7-32 enumerate authors agreeing to relicense past contributions. This is not evidence that every historical contribution is universally GPLv2. The file retains the upstream name “iSH”; that is what it actually says.

(you read code/docs but did not run it) LICENSE.IOS:1-12 is an undertaking by the iSH copyright holders not to pursue violations arising **solely** from GPLv2/v3 conflicts with App Store terms, conditional on otherwise complying with GPL, expressly including source and license text. It does not grant a general proprietary embedding exception, waive corresponding-source obligations, promise App Review acceptance, cover every third-party dependency, or expressly mention AGPL. Its coverage of all fork contributors and an AGPL combined app is legally uncertain. I am not a lawyer.

(you read code/docs but did not run it) For distribution, plan to provide corresponding source for covered code and modifications/build integration, GPL text, preserved copyright/attribution and modification notices. Static linking does not itself create a closed-source exception. A combined application containing proprietary parts needs a legal boundary/rights analysis or separate permissions; do not assume merely publishing ShellBox source satisfies a combined-work obligation. App Store non-enforcement is narrower than a blanket license waiver. Legal interpretation remains provisional; see final primary-license references below.

(you read code/docs but did not run it) dsh-Go/LICENSE is AGPLv3; ASSETS.md:3-15 excludes Deepy, whale-girl and brand assets, permits repository build/test/run, and requires replacement names/assets for modified redistribution. Code licensing does not authorize an IPA with those assets. GPLv3/AGPLv3 have a section-13 combined-work provision: combination is possible, with AGPL network-interaction requirements applying to the combination; this is a combined-work compliance issue, not automatic incompatibility. LICENSE.IOS does not resolve dsh-Go AGPL/App Store or proprietary-component uncertainty.

## 2. Node 24 verdict

(you read code/docs but did not run it) **UNKNOWN — no evidence verifies Node 24 under this ShellBox commit; explicit version claims cover Node 22.** This is not a demonstrated Node 24 failure.

(you read code/docs but did not run it) Whole-tree text search (Python recursive scan, excluding .git and validation logs; results in ShellBox/validation-whole-repo-search.log; broader Node/V8 scan: validation-node-all.log, 814 matching lines) found Node 22 references in README.md:21, README_arm64.md:278, kernel/mmap.c:104, fs/real.c:813 and benchmark/assets/shellbench.sh:107; no explicit Node 24 claim. README_arm64_zh.md:115-125 mirrors the V8 discussion. README_arm64.md:124-136 claims a nine-instruction code-cave patch for InterpreterEntryTrampoline derived constructors, low-address pages, large lazy reservations, flags and exit cleanup. This is an external **binary patch claim**, not a generic V8 source fix or proof of Node 24 applicability. Searches found references to the cave in kernel/calls.c:1115-1116 but did not locate a reproducible patch script, original binary checksum or Node/V8 version mapping in this checkout. An embedding rootfs must not be assumed to include it.

(you read code/docs but did not run it) Actual loader kernel/exec.c:415-435 maps the first 1 MiB for basename `node` as **read/write** zero pages, best-effort (not inaccessible hardware guard pages). kernel/mmap.c:100-126 has V8-cage-shaped reservation heuristics, explicitly discussing Node 22. kernel/exec.c:840-858 injects `--jitless`, `--no-lazy`, `--max-old-space-size=512`, `--no-concurrent-marking`, `--no-concurrent-recompilation`, `--no-lazy-compile-dispatcher`, `--predictable`. Lines 860-870 conditionally load `/lib/wasm-polyfill.js` and `/lib/fetch-polyfill.js` if present; file names are not proof those shims are supplied. These are basename-based, not Node-24-version-tested adaptations. jitless does not establish full Wasm or npm native-addon compatibility.

(you read code/docs but did not run it) CI does **not pin a Node major/version**: ShellBox/tests/integration/full.sh:128-130 installs distro `nodejs`; :168-171 runs only `node -e 'console.log("NODE-OK", process.version)'`. tests/integration/rootfs.sh:44,54,59 specifies Alpine 3.22.5 aarch64, Rocky 9 aarch64 and Ubuntu 26.04 arm64 rootfs URLs. ShellBox/.github/workflows/integration.yml:1-9,27-65 makes this a nightly/manual network matrix on macos-15. ci.yml's smoke is separate, not a Node-24 gate. No CI run logs were fetched, so actual resolved Node versions and run outcomes are unknown; workflow definitions are not test passes.

(evidence shows it fails or conflicts) Node 22 conflicts with the current DSH declaration: runtime/locks/dsh-0.2.2-rc.1/package-lock.json:532-634, specifically :633, requires `>=24.9.0`. runtime/build-runtime.sh:44-45 selects DSH 0.2.2-rc.1 and Node 24.22.1. ShellBox's Node 22 documentation cannot satisfy that requirement.

(you read code/docs but did not run it) Treat apparent success cautiously: ShellBox/kernel/fs.c:260-335 filters V8 fatal stderr (host `ISH_V8_NO_MUTE=1` bypass), kernel/signal.c:353-425 can turn fatal abort states into successful termination, and kernel/calls.c:615-641 uses fixed Node text-address ranges for fault recovery. These address/binary-dependent assumptions warrant Node 24 testing but do not prove incompatibility. Exit zero alone is insufficient; require asserted results, complete output and sustained HTTP service.

## 3. What actually ran here

(you ran it on this machine) `uname -m` → `x86_64`; `/etc/os-release` → Debian GNU/Linux 13.7. `which` and Python `shutil.which` found cc/gcc, ar, make, pkg-config, python3, git/curl/sh/bash/node/npm; meson, ninja, clang, lld/ld.lld, qemu-aarch64, aarch64-linux-gnu-gcc, flutter, dart, xcodebuild and pod absent. Evidence: ShellBox/validation-tools.log and the executed `which` commands. No system packages or toolchains installed.

(you ran it on this machine) Ran `python3 validation-host.py` from ShellBox; exact commands and stdout/stderr are retained in ShellBox/validation-host.py and validation-host.log. The following are **host-native x86_64 Debian only; zero ShellBox passes**. Version probes establish availability only, not git clone, npm install or guest compatibility.

| Item | Result | Label |
|---|---|---|
| Host sh | `sh -c` → SH-OK | 已实际验证 PASS (you ran it on this machine) |
| Host bash | `bash -c` → BASH-OK | 已实际验证 PASS (you ran it on this machine) |
| Host git | `git --version` → 2.47.3 | 已实际验证 PASS (you ran it on this machine) |
| Host curl | `curl --version` → 8.14.1, x86_64 | 已实际验证 PASS (you ran it on this machine) |
| Host node | `node -p` → v22.23.3, x64, V8 12.4.254.21-node.57 | 已实际验证 PASS (you ran it on this machine) |
| Host npm | `npm --version` → 10.9.9 | 已实际验证 PASS (you ran it on this machine) |
| Host subprocess | Node execFileSync(/bin/sh) throws spawnSync EPERM, exit 1 (error object also contains CHILD-OK/status 0; not a clean pass) | 已实际验证 FAIL (evidence shows it fails or conflicts) |
| Host local TCP | Python HTTPServer socket creation rejected: [Errno 1] Operation not permitted; client not reached | 已实际验证 FAIL (evidence shows it fails or conflicts) |
| Host DNS | socket.getaddrinfo(github.com,443) → [Errno -3] Temporary failure in name resolution | 已实际验证 FAIL (evidence shows it fails or conflicts) |
| Host HTTPS | curl --noproxy "*" -I --max-time 10 https://github.com → exit 6, Could not resolve host | 已实际验证 FAIL (evidence shows it fails or conflicts) |
| ShellBox build/run | 未测试: no Meson/Ninja/Clang/LLD, wrong host architecture, no prepared ARM64 rootfs or built ish executable found (`find build ...` returned no files) | (cannot be tested here) |
| ShellBox Node 24 + DSH | 未测试: guest engine/rootfs absent; host Node is 22, not 24 | (cannot be tested here) |

(you read code/docs but did not run it) No build was attempted because required tools are absent. Even adding Meson/Ninja alone would not make this host valid: ShellBox/meson.build:62-67 selects gadgets by **host** CPU and only gadgets-aarch64 exists; README.md:93 explicitly requires arm64. QEMU-aarch64 is also absent and would not be a supported native-host test. README_arm64.md:181-182 says rootfs is not shipped. The rootfs download definitions are inputs, not an installed guest. No inside-ShellBox shell, git, curl, npm, subprocess or network execution occurred.

## 4. Untested iOS build-chain checklist

All five checklist rows have the literal limitation **(no macOS/Xcode/device here — no exceptions)**. Their conclusion label is (cannot be tested here).

| Item | Result | Label |
|---|---|---|
| arm64 static libraries | 未测试 (no macOS/Xcode/device here — no exceptions) | (cannot be tested here) |
| Xcode linking / install / signing | 未测试 (no macOS/Xcode/device here — no exceptions) | (cannot be tested here) |
| C embedding interface | 未测试 (no macOS/Xcode/device here — no exceptions) | (cannot be tested here) |
| PTY sessions / restart / teardown | 未测试 (no macOS/Xcode/device here — no exceptions) | (cannot be tested here) |
| rootfs initialisation on iOS | 未测试 (no macOS/Xcode/device here — no exceptions) | (cannot be tested here) |

(you read code/docs but did not run it) Toolchain requirements read from the fixed checkout:

| Source | Actual requirements / scope |
|---|---|
| ShellBox/.github/workflows/static-libs.yml:47-157 | macos-15 runner; brew llvm, lld, ninja, libarchive, meson. xcrun selects iphoneos and iphonesimulator SDK paths; no exact Xcode or SDK version pinned. clang/clang++, ar, strip, pkg-config cross file; `-arch arm64`, Darwin/aarch64 little endian, minimum iOS/device and simulator 13.0. Meson release `-Dguest_arch=arm64`; Ninja named libish.a/libish_emu.a/libfakefs.a targets. No explicit Apple target triple in cross file, no signing/export/install step. |
| ShellBox/.github/workflows/ci.yml:13-113 | macos-15; same brew dependencies; host Meson/Ninja + meson test, downloaded rootfs smoke, and separate iphoneos arm64 library cross-build (minimum 13.0). Comments explicitly remove Linux CI because gadgets need ARM64 host. No Xcode version selection, signing or device run. |
| ShellBox/.github/workflows/integration.yml:27-65 | macos-15; same brew dependencies; release host CLI; network package installs in Alpine/Rocky/Ubuntu; nightly/manual. No iOS linking or signed-device validation. |
| ShellBox/meson.build:1-3,43-67,1718 | GNU C11 compiler; threads, sqlite3; optional rt/m/dl; ARM64 host gadgets; platform source chosen from host system. Linux platform/linux.c exists, but is not x86_64 gadget support. |
| ShellBox/vdso/arm64/meson.build:3-41 | Linux guest VDSO uses Clang `-target aarch64-linux-gnu -fuse-ld=lld`, freestanding/no stdlib. macOS needs ELF cross compilation even when device libraries are Mach-O. If no compiler exists, build declares an empty VDSO stub; that is not proof of working guest. |
| ShellBox/README.md:61-91; README_arm64.md:138-215 | Python3, Meson/Ninja, Clang/LLD, sqlite3, libarchive (host fakefsify). ARM64 host. Embedder supplies app, terminal, rootfs and wrappers. Generic Ninja cross-build includes host fakefsify and is explicitly unsuitable for phone; build named library targets. |

(you read code/docs but did not run it) Actual C declarations read: ShellBox/kernel/init.h:7-12 exposes `mount_root`, `become_first_process`, stdio helpers; fs/tty.h:209 declares `struct tty *pty_open_fake(struct tty_driver *driver)`. README_arm64.md:146-148 describes `do_execve`/`task_start` and references a **different repository's** ServerBox example; it is not a local Swift/Flutter wrapper. README_arm64.md:140-142 says ISHShellExecutor and DebugServer were removed. Static library building needs no signing identity; a signed IPA/device installation does, but no identity/profile or phone is available here (environment supplied by user). No claimed exact Xcode version can be extracted from a floating macos-15 runner.

## 5. DSH downgrade analysis

(you read code/docs but did not run it) Directory enumeration of runtime/locks found exactly two DSH lock directories: `dsh-0.2.1-rc.4` and `dsh-0.2.2-rc.1`. There is no rc.2 lock directory, though runtime/patches/pins.json:42 has historical rc.2 pins. Current build selects rc.1 of 0.2.2 (build-runtime.sh:44), installs its versioned lock (:301-325) and applies current patches (:446-448). Historical pins do not mean those releases remain buildable with today's entire patch set.

(you read code/docs but did not run it) Concrete lock comparison (`python3` json load of both `packages` maps): old DSH entry at runtime/locks/dsh-0.2.1-rc.4/package-lock.json:504 has **no engines field**; that is no positive Node 22 guarantee. Commander in the old lock (:7213-7219) requires >=22.12.0. Scanning all old lock engines found no constraint mentioning 24. Both locks still require platform-specific native modules; absence of a Node constraint does not validate their ShellBox ABI/runtime behavior.

(you read code/docs but did not run it) Direct dependency comparison of those DSH entries shows old cordis ~4.0.5 vs new ~4.1.0, schemastery ~3.18.5 vs ~3.19.0. New direct packages absent from the old DSH dependency list are `dsh-experimental-forge-bundle`, `dsh-experimental-liveshare`, `dsh-official-bundles`, `dsh-personalized-recommendations` (new lock :561-563 and the rest of :532-627; old :504 onward). Downgrade loses those **declared bundles at this entry point**; their exact user-visible behavior cannot be reconstructed from lock metadata. It also replaces the many rc.1-versioned engine packages with rc.4, not just one Node launcher.

(evidence shows it fails or conflicts) Python count over runtime/patches/pins.json found 136 patch entries pinned for 0.2.2-rc.1, 54 for 0.2.1-rc.4, 3 for 0.2.1-rc.2. The current patcher runtime/lib/rtbuild.py:360-388 requires a pin for **each current diff**, and terminates at a missing version pin. First example: attachment-direct-boundary.diff has only new-version pins (pins.json:3-9). Therefore simply overriding DSH_VERSION to rc.4 is not a supported build path. This conclusion follows from code, not an executed runtime build.

(you read code/docs but did not run it) Specific protocol/behavior differences visible in current patches, without inventing upstream source history:

| Evidence | What must be re-audited or lost if omitted |
|---|---|
| runtime/patches/session-format-error.diff:1-10 | Maps persistence SessionFormatUnsupportedError to stable `session/format-unsupported`; no rc.4 pin in current pins map. Old native-client error behavior is not established. |
| runtime/patches/session-queue-steer-deletion.diff:1-6 | Adds deletion admission check on session controller `steer`; removing it removes this explicit guard, unless old engine independently provides equivalent behavior (not evidenced). |
| runtime/patches/terminal-job-cancel.diff:1-26 | Prevents repeated forwarding of background job cancellation; adaptation to old tool-terminal needs review. |
| runtime/patches/cordis-effect-dispose-completion.diff:1-28 | Ensures all owned cleanup runs before rethrow; old/new Cordis versions differ and old target is unpinned. |
| runtime/patches/fs-create-exclusive.diff; pins.json:41-58 | Even a patch pinned for both releases has different before/after hashes. Shared patch name does not establish identical upstream API/layout. |
| runtime/patches/web-composer-mobile-newline.diff:1-11 | Mobile input fix explicitly targets 0.2.2-rc.1 bundled UI; old bundle parity is unverified. |

(you read code/docs but did not run it) These are concrete patch/protocol risks, not a claim that every old release has each bug. Locks contain metadata/integrity, not full engine source; a full HTTP/SSE/mux/session-persistence compatibility comparison is unavailable without retrieving and reviewing the old package tree and exercising the current client/bridge. No such fetch/build/test occurred. Only rc.4 is an evidenced **candidate for a separate porting audit**, not a validated downgrade. No evidenced ready-to-run Node 22 downgrade path exists here.

## 6. Alternatives (docs-only)

(you read code/docs but did not run it) No alternatives were installed or tested; no route was switched. ShellBox/README.md:5-16 names upstream iSH and contrasts its removed i386 backend. The stage-1 audit docs/ios/architecture-audit.md:184 names iSH/UTM as candidates needing independent investigation; :236-237 proposes the remote-client track. Primary web documents were read on 2026-11-12; web-rendered line numbers below refer to the tool's returned page text, not a pinned checkout.

| Alternative | Documentation evidence and preliminary judgement | Label |
|---|---|---|
| iSH | [Own README](https://github.com/ish-app/ish), rendered lines 228-254,271: x86 usermode Linux, i386 Alpine, Xcode app/team setup, threaded interpreter rather than emitted machine-code JIT. [Own LICENSE.md](https://raw.githubusercontent.com/ish-app/ish/master/LICENSE.md), lines 1-5 and [LICENSE.IOS](https://raw.githubusercontent.com/ish-app/ish/master/LICENSE.IOS), lines 1-12: GPLv3, contribution GPLv2 relicensing, conditional App Store non-enforcement. An iOS app is evidenced; a drop-in embedding SDK and Node 24 support are not. No evidence here that changing to i386 solves this Node requirement. | (you read code/docs but did not run it) |
| UTM / UTM SE | [Own README](https://github.com/utmapp/UTM), rendered lines 240-260,277-279: QEMU full-system emulation; Apache-2.0 frontend with (L)GPL components, not a wholly Apache dependency closure. Normal UTM uses JIT with iOS jailbreak/version-dependent workarounds; SE uses slower threaded interpretation without JIT. [Own iOS installation docs](https://docs.getutm.app/installation/ios/), rendered lines 100-103: SE available on App Store without jailbreak. An independent VM app is evidenced, a compact embeddable ShellBox replacement and Node 24 pass are not. A Linux VM could be investigated separately, but these docs do not settle Node compatibility or integration cost. | (you read code/docs but did not run it) |
| Remote-client track | Existing dsh-Go audit :11,236 and docs/architecture.md local-connection/API discussion: reuse Dart client against an external engine, leaving local Linux feasibility separate. Does not require local Node/JIT; does require an external DSH host and future iOS client/device verification. This is a planning option, not a completed iOS app. dsh-Go AGPL and asset constraints remain. | (you read code/docs but did not run it) |

## 7. Recommendation

(you read code/docs but did not run it) **do the remote-client closed loop first**. This matches the audit's dependency order (docs/ios/architecture-audit.md:236-237): Node 24 is unknown, Node 22 conflicts with current DSH, downgrade is not prepared, and static libraries/rootfs/licensing still need independent gates. This recommendation authorizes no implementation in this validation task and does not abandon ShellBox.

(cannot be tested here) **Single next experiment:** on an **Apple Silicon ARM64 Mac**, build this exact ShellBox commit as its host CLI with Meson/Ninja, Clang/LLD, sqlite3/libarchive and the aarch64-linux-gnu ELF VDSO target; prepare an ARM64 Linux rootfs with a checksum-pinned Node **24.22.1** binary matching its libc (or a precisely recorded >=24.9.0 version). In one bounded harness run the unmodified ShellBox loader with host `ISH_V8_NO_MUTE=1`, print process.version/V8, assert a derived-constructor fixture, npm subprocess execution, and a long-lived local HTTP server returning a known body to a guest/host client. Verify output completeness and process lifetime, not just exit zero; retain full stderr and binary hashes, and explicitly report whether the claimed nine-instruction patch is present. Do not silently patch around failure. This settles initial Node 24 CLI/runtime feasibility for that binary; a pass still does not settle all native modules, DSH or iOS behavior. Subsequent product validation would require Xcode/iphoneos SDK and a signed iPhone/iPad harness, which this report did not build.

(you read code/docs but did not run it) Legal evidence supplement: dsh-Go/LICENSE:540-559 contains AGPL's actual combination/network clause. The host's `/usr/share/common-licenses/GPL-3`:195-244,249-285,310-329 and :552 onward supplies GPLv3 notice, modified-work, corresponding-source, installation-information and AGPL-combination text, read locally. Combined GPL portions retain GPL terms; AGPL portions retain AGPL, with the network source obligation including incorporated GPL source as specified. Independent aggregation differs from linking a single program; closed-source coexistence needs fact-specific review. Preserve legal notices, source delivery/access and applicable installation information, not only a README attribution.

(you ran it on this machine) Network limits: direct shell DNS failed and curl HTTPS failed as recorded in §3. Web tool successfully read the alternative repositories and UTM docs above, but requests for https://www.gnu.org/licenses/gpl-3.0.html and https://www.gnu.org/licenses/agpl-3.0.html both returned timeout-fetch errors. Those online pages were unavailable; legal text conclusions use the actual local texts cited above, not a fabricated successful fetch. No remote CI logs or Node 24 package were obtained.

(you ran it on this machine) Count convention: **6 passing items labelled 已实际验证**, all host-only; 4 executed host failures; **7 items labelled 未测试** (two ShellBox rows + five iOS checklist rows). Zero inside-ShellBox passes. Reading license/source and inventory commands are evidence gathering, not extra passing runtime tests. Scratch scripts/logs reside only in the separate ShellBox checkout.
