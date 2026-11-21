#!/usr/bin/env python3
"""Guards the release workflows must keep, checked from the repository.

These are properties a green run would otherwise claim silently:

  * an unsigned IPA is published only when its archive/audit step passed
    (check-archive.sh writes the .ipa before it exits on a failed audit);
  * the Full archive embeds the prepared runtime ZIP;
  * the Remote Only job refuses a checkout with a prepared engine;
  * the live SSH job cannot pass by skipping the PTY cases, and it keeps the
    fixture's diagnostics even when the pty probe fails before any test runs.

`ci.yml` runs this next to the generated-file checks. Standard library only:
the checks job's venv carries Pillow and numpy, not a YAML parser.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
WORKFLOWS = ROOT / ".github" / "workflows"
IOS = WORKFLOWS / "ios-compile.yml"
SSH_LIVE = WORKFLOWS / "ssh-live.yml"
ARCHIVE = ROOT / "tooling" / "ios" / "check-archive.sh"

problems: list[str] = []


def fail(message: str) -> None:
    problems.append(message)


def job(text: str, name: str) -> str:
    """The lines of one top-level job, or '' when it is missing."""
    starts = [m.start() for m in re.finditer(r"\n  ([a-z][a-z0-9-]*):\n", text)]
    if not starts:
        return ""
    for index, start in enumerate(starts):
        header = text[start : text.index("\n", start + 1)]
        if header.strip() == f"{name}:":
            end = starts[index + 1] if index + 1 < len(starts) else len(text)
            return text[start:end]
    return ""


def step(body: str, name: str) -> str:
    """One `- name: <name>` step's lines, or '' when it is missing."""
    pattern = re.compile(
        r"^      - name: " + re.escape(name) + r"\n(.*?)(?=^      - name: |\Z)",
        re.MULTILINE | re.DOTALL,
    )
    match = pattern.search(body)
    return match.group(0) if match else ""


def need(where: str, block: str, needle: str, what: str) -> None:
    if not block:
        fail(f"{where}: step or job not found")
    elif needle not in block:
        fail(f"{where}: {what} (missing {needle!r})")


ios = IOS.read_text(encoding="utf-8")
live = SSH_LIVE.read_text(encoding="utf-8")
archive = ARCHIVE.read_text(encoding="utf-8")

# Full archive: runtime ZIP embedded, IPA only after a passing audit.
engine = job(ios, "engine")
full_archive = step(engine, "Archive as for TestFlight, and look inside")
need("ios-compile engine", full_archive, "id: archive", "the archive step has no id to gate the upload on")
need("ios-compile engine", full_archive, "DSH_IOS_BUNDLE_RUNTIME: 'YES'", "the Full archive does not embed the runtime ZIP")
full_upload = step(engine, "Keep the unsigned app")
need("ios-compile engine", full_upload, "steps.archive.outcome == 'success'", "the Full IPA upload does not wait for the audit")

# Every simulator check builds the app itself, so each one needs the embedded
# runtime ZIP. Without it the Debug app keeps the loopback download source and
# fails with ios_download_network on a runner that serves no such URL.
for smoke in (
    "Run the engine inside the app",
    "Launch the real app",
    "Drive other apps with the phone runner",
    "Call the browser and system tools inside the app",
):
    block = step(engine, smoke)
    need("ios-compile engine", block, "DSH_IOS_BUNDLE_RUNTIME: 'YES'", f"{smoke!r} builds without the runtime ZIP")
    need("ios-compile engine", block, "id: smoke_", f"{smoke!r} has no id for the verdict step")

# The build verdict and the simulator verdicts are reported apart, so that a red
# simulator check is not read as a broken build or the reverse.
need("ios-compile engine", step(engine, "Report the build and the simulator results apart"), "verdict/build.txt", "the build verdict is not written apart from the smoke verdicts")
need("ios-compile engine", step(engine, "Report the build and the simulator results apart"), "verdict/smoke.txt", "the smoke verdicts are not written separately")
need("ios-compile engine", step(engine, "Keep the two verdicts apart"), "ios-verdicts", "both verdicts are not kept as their own artifact")

# Each packaged app publishes a small text manifest (identity, contents, checksums)
# so the archive can be reviewed without pulling the whole .ipa.
need("ios-compile engine", step(engine, "Keep the Full package manifest"), "full-package-manifest.txt", "the Full manifest is not kept as its own artifact")
need("ios-compile remote-only", step(job(ios, "remote-only"), "Keep the Remote Only package manifest"), "remote-only-package-manifest.txt", "the Remote Only manifest is not kept")
for needle, what in (
    ("bundle id:", "the manifest has no bundle id"),
    ("version:", "the manifest has no version"),
    ("ipa sha256:", "the manifest has no checksum"),
    ("runtime.zip:", "the manifest never shows the embedded runtime"),
    ("engine framework", "the manifest never shows the engine frameworks"),
):
    if needle not in archive:
        fail(f"check-archive.sh: package manifest lost {needle!r}: {what}")


# The shared host-core case is real coverage: its sources moved to
# runtime/shared/host (plus runtime/ohos/host for the lifecycle header), and the
# build script must point there instead of the removed app/ohos tree.
HOST_CORE = ROOT / "runtime" / "tests" / "ohos" / "host-core.py"
host_core = HOST_CORE.read_text(encoding="utf-8")
if "app/ohos" in host_core:
    fail("host-core.py: still builds from the removed app/ohos tree")
if "runtime/shared/host" not in host_core:
    fail("host-core.py: does not build the host core kept at runtime/shared/host")
addons = step(job(ios, "compile"), "Check where the engine looks for its addons")
need("ios-compile compile", addons, "host-core.py --ios", "the iOS addon layout is no longer checked")
need("ios-compile compile", addons, "host-core.py --out", "the default host profile is no longer checked")
shared = step(engine, "Check the shared host profiles")
need("ios-compile engine", shared, "inputs.regression_only", "the shared host profiles are not rechecked")
need("ios-compile engine", shared, "host-core.py --ios", "the shared host check lost its iOS mode")

# Remote Only: no prepared engine, and the same upload gate.
remote = job(ios, "remote-only")
need("ios-compile remote-only", remote, "app/ios/Engine/.ready", "the job does not refuse a prepared engine")
remote_archive = step(remote, "Archive and audit the Remote Only app, unsigned")
need("ios-compile remote-only", remote_archive, "id: archive", "the Remote Only archive step has no id")
need("ios-compile remote-only", remote_archive, "check-archive.sh --remote-only", "the job does not run the Remote Only audit")
remote_upload = step(remote, "Keep the Remote Only unsigned app")
need("ios-compile remote-only", remote_upload, "steps.archive.outcome == 'success'", "the Remote Only IPA upload does not wait for the audit")

# The audit script itself: the Remote Only mode has to forbid engine artefacts.
for needle in (
    'mode=remote-only',
    'DSH_REMOTE_ONLY=true',
    'Remote Only carries $name.framework',
    'Remote Only carries the dsh-runtime resources',
):
    if needle not in archive:
        fail(f"check-archive.sh: Remote Only audit lost {needle!r}")

# Live SSH: PTY may not skip its way to green, and the log survives the probe.
live_job = job(live, "live")
need("ssh-live", live_job, "DSH_APP_LIVE_SSHD_REQUIRE_PTY: '1'", "the fixture's pty probe is not required")
run = step(live_job, "Run the live SSH, SFTP and PTY tests")
for needle, what in (
    ("with-sshd.sh", "the live tests do not run against a real sshd"),
    ("set -o pipefail", "tee would hide a failed fixture"),
    ("~[1-9]", "a skipped PTY case would pass the job"),
    ("ssh-live.log", "the step does not keep one log for the fixture and the tests"),
):
    need("ssh-live", run, needle, what)
log_step = step(live_job, "Keep the live test log")
need("ssh-live", log_step, "always()", "the log is not kept on failure")
need("ssh-live", log_step, "ssh-live.log", "the log artifact points somewhere else")

if problems:
    for problem in problems:
        print(f"workflow guards: {problem}", file=sys.stderr)
    sys.exit(1)
print("workflow guards: archive gating, Remote Only audit and the live PTY gate are in place")
