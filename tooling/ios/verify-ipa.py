#!/usr/bin/env python3
"""Verify the layout and code signatures of an iOS .app or .ipa.

This deliberately verifies each nested bundle and Mach-O independently. It
never calls ``codesign --deep`` because recursive signing can hide an unsigned
or incorrectly signed nested executable.
"""

from __future__ import annotations

import argparse
import datetime as dt
import os
import plistlib
import shutil
import subprocess
import sys
import tempfile
import zipfile
from pathlib import Path
from typing import Any, Iterable


MACHO_MAGICS = {
    b"\xfe\xed\xfa\xce",
    b"\xce\xfa\xed\xfe",
    b"\xfe\xed\xfa\xcf",
    b"\xcf\xfa\xed\xfe",
    b"\xca\xfe\xba\xbe",
    b"\xbe\xba\xfe\xca",
    b"\xca\xfe\xba\xbf",
    b"\xbf\xba\xfe\xca",
}

ENGINE_FRAMEWORKS = (
    "NodeMobile.framework",
    "DshNodeHost.framework",
    "DshFlock.framework",
    "DshRequireBuiltin.framework",
    "DshGuest.framework",
    "DshGuestBridge.framework",
)


class VerifyError(Exception):
    def __init__(self, message: str, details: list[str] | None = None) -> None:
        super().__init__(message)
        self.details = details or []


def command(args: list[str], *, check: bool = True) -> subprocess.CompletedProcess[bytes]:
    completed = subprocess.run(args, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if check and completed.returncode != 0:
        detail = (completed.stderr or completed.stdout).decode("utf-8", "replace").strip()
        raise VerifyError(f"{' '.join(args)} failed: {detail}")
    return completed


def load_plist(path: Path) -> dict[str, Any]:
    try:
        with path.open("rb") as source:
            value = plistlib.load(source)
    except (OSError, plistlib.InvalidFileException) as error:
        raise VerifyError(f"cannot read plist {path}: {error}") from error
    if not isinstance(value, dict):
        raise VerifyError(f"plist is not a dictionary: {path}")
    return value


def is_macho(path: Path) -> bool:
    try:
        with path.open("rb") as source:
            return source.read(4) in MACHO_MAGICS
    except OSError:
        return False


def file_description(path: Path) -> str:
    return command(["file", "-b", str(path)]).stdout.decode("utf-8", "replace").strip()


def architectures(path: Path) -> set[str]:
    output = command(["lipo", "-archs", str(path)]).stdout.decode("utf-8", "replace")
    return set(output.split())


def signing_details(path: Path) -> dict[str, str]:
    completed = command(["codesign", "--display", "--verbose=4", str(path)], check=False)
    text = (completed.stderr + completed.stdout).decode("utf-8", "replace")
    details: dict[str, str] = {}
    for line in text.splitlines():
        if "=" in line:
            key, value = line.split("=", 1)
            details[key.strip()] = value.strip()
    if completed.returncode != 0:
        details["_error"] = text.strip()
    return details


def signing_entitlements(path: Path) -> dict[str, Any]:
    completed = command(["codesign", "--display", "--entitlements", ":-", str(path)], check=False)
    if completed.returncode != 0:
        return {}
    payload = completed.stdout
    if not payload.lstrip().startswith(b"<?xml"):
        return {}
    try:
        value = plistlib.loads(payload)
    except plistlib.InvalidFileException:
        return {}
    return value if isinstance(value, dict) else {}


def profile_for(bundle: Path) -> dict[str, Any] | None:
    path = bundle / "embedded.mobileprovision"
    if not path.is_file():
        return None
    decoded = command(["security", "cms", "-D", "-i", str(path)]).stdout
    try:
        value = plistlib.loads(decoded)
    except plistlib.InvalidFileException as error:
        raise VerifyError(f"cannot decode provisioning profile {path}: {error}") from error
    if not isinstance(value, dict):
        raise VerifyError(f"provisioning profile is not a dictionary: {path}")
    return value


def profile_allows_identifier(profile: dict[str, Any], identifier: str) -> bool:
    entitlements = profile.get("Entitlements", {})
    pattern = entitlements.get("application-identifier")
    if not isinstance(pattern, str):
        return False
    if pattern.endswith("*"):
        return identifier.startswith(pattern[:-1])
    return pattern == identifier


def as_list(value: Any) -> list[Any]:
    return value if isinstance(value, list) else []


def safe_extract(archive_path: Path, destination: Path) -> None:
    root = destination.resolve()
    with zipfile.ZipFile(archive_path) as archive:
        for member in archive.infolist():
            target = (destination / member.filename).resolve()
            if target != root and root not in target.parents:
                raise VerifyError(f"IPA contains an unsafe archive path: {member.filename}")
    # Python's zipfile.extractall writes symlink members as regular files. The
    # Flutter/Node payload contains symlinks under node_modules/.bin, and
    # rewriting them changes the sealed resources, producing a false signature
    # failure. ditto is the same extractor Xcode/Apple tooling use and restores
    # symlinks and executable metadata faithfully.
    command(["ditto", "-x", "-k", str(archive_path), str(destination)])


class Verifier:
    def __init__(self, args: argparse.Namespace, app: Path, extracted_root: Path | None) -> None:
        self.args = args
        self.app = app
        self.extracted_root = extracted_root
        self.errors: list[str] = []
        self.code_paths: dict[Path, str] = {}
        self.bundles: list[Path] = []
        self.profiles: dict[Path, dict[str, Any]] = {}
        self.app_info = load_plist(app / "Info.plist")
        self.app_id = self.app_info.get("CFBundleIdentifier")
        self.app_version = self.app_info.get("CFBundleShortVersionString")
        self.app_build = self.app_info.get("CFBundleVersion")

    def fail(self, message: str) -> None:
        self.errors.append(message)

    def require(self, condition: bool, message: str) -> None:
        if not condition:
            self.fail(message)

    @property
    def profiles_required(self) -> bool:
        """Provisioning profiles and device entitlements only apply to device builds.

        Simulator and local ad-hoc builds have no ``embedded.mobileprovision`` and
        no ``application-identifier`` entitlement, so demanding them there would
        produce false failures. Device builds (the default) still require them.
        """
        return self.args.require_profiles or not self.args.allow_adhoc

    def run(self) -> None:
        self.require(isinstance(self.app_id, str) and bool(self.app_id), "main app has no CFBundleIdentifier")
        self.collect_bundles()
        self.collect_macho()
        self.check_bare_native_libraries()
        self.check_required_components()
        self.check_bundle_relationships()
        self.check_macho()
        self.check_signatures()
        self.print_report()
        if self.errors:
            raise VerifyError(f"{len(self.errors)} verification error(s)", self.errors)

    def collect_bundles(self) -> None:
        self.bundles.append(self.app)
        for path in sorted(self.app.rglob("*.appex")):
            if path.is_dir():
                self.bundles.append(path)
        for path in sorted(self.app.rglob("*.framework")):
            if path.is_dir():
                self.bundles.append(path)

    def bundle_executable(self, bundle: Path) -> Path | None:
        info_path = bundle / "Info.plist"
        if not info_path.is_file():
            return None
        info = load_plist(info_path)
        executable = info.get("CFBundleExecutable")
        return bundle / executable if isinstance(executable, str) and executable else None

    def classify_macho(self, path: Path) -> str:
        if path == self.app / str(self.app_info.get("CFBundleExecutable")):
            return "app"
        for extension in self.app.rglob("*.appex"):
            executable = self.bundle_executable(extension)
            if path == executable:
                return "extension"
        for framework in self.app.rglob("*.framework"):
            executable = self.bundle_executable(framework)
            if path == executable:
                return "framework"
        if path.suffix == ".dylib" and path.parent == self.app:
            if self.args.allow_root_debug_dylibs:
                return "debug-dylib"
        return "unexpected"

    def collect_macho(self) -> None:
        for path in sorted(self.app.rglob("*")):
            if path.is_file() and is_macho(path):
                self.code_paths[path] = self.classify_macho(path)

    def check_bare_native_libraries(self) -> None:
        for path in self.app.rglob("*"):
            if not path.is_file():
                continue
            relative = path.relative_to(self.app)
            if path.suffix == ".so":
                self.fail(f"bare shared object is not valid iOS packaging: {relative}")
            if path.suffix == ".dylib" and "Frameworks" in path.parts:
                self.fail(f"bare dylib must be packaged in a signed framework: {relative}")
            if path.suffix == ".node" and is_macho(path):
                self.fail(f"native .node addon is not valid in this iOS payload: {relative}")

    def check_required_components(self) -> None:
        if self.args.require_native_node:
            required = (
                "NativeNode/supervisor.mjs",
                "NativeNode/engine-worker.mjs",
                "NativeNode/node_modules/@deepseek-ai/node-addon-system/lib/flock.js",
                "Frameworks/NodeMobile.framework/NodeMobile",
            )
            for relative in required:
                self.require((self.app / relative).is_file(), f"NativeNode component is missing: {relative}")
            framework = self.app / "Frameworks/NodeMobile.framework"
            if framework.is_dir():
                self.require(
                    self.bundle_executable(framework) == framework / "NodeMobile",
                    "NodeMobile framework executable does not match CFBundleExecutable",
                )

        if self.args.require_engine:
            for name in ENGINE_FRAMEWORKS:
                path = self.app / "Frameworks" / name
                self.require(path.is_dir(), f"DSH Engine framework is missing: Frameworks/{name}")
                executable = self.bundle_executable(path) if path.is_dir() else None
                self.require(executable is not None and executable.is_file(), f"DSH Engine executable is missing: {name}")
            runtime = self.app / "dsh-runtime/runtime.zip"
            self.require(runtime.is_file(), "DSH Engine runtime is missing: dsh-runtime/runtime.zip")
            if runtime.is_file():
                self.check_engine_runtime(runtime)

    def check_engine_runtime(self, runtime: Path) -> None:
        member = "files/node_modules/@dsh-go/ohos-native/index.cjs"
        try:
            with zipfile.ZipFile(runtime) as archive:
                names = archive.namelist()
                self.require(names.count(member) == 1, f"DSH runtime loader member must be unique: {member}")
                if names.count(member) == 1:
                    loader = archive.read(member).decode("utf-8")
                    for expected in (
                        "DshFlock.framework/DshFlock",
                        "DshRequireBuiltin.framework/DshRequireBuiltin",
                    ):
                        self.require(loader.count(expected) == 1, f"DSH runtime loader lacks {expected}")
                    for old in ("libdsh_flock.so", "libdsh_require_builtin.so"):
                        self.require(old not in loader, f"DSH runtime still references old loader path: {old}")
        except (OSError, KeyError, UnicodeDecodeError, zipfile.BadZipFile) as error:
            self.fail(f"cannot inspect DSH runtime.zip: {error}")

    def check_bundle_relationships(self) -> None:
        app_id = str(self.app_id)
        for bundle in self.bundles:
            if bundle == self.app or bundle.suffix == ".framework":
                continue
            info = load_plist(bundle / "Info.plist")
            bundle_id = info.get("CFBundleIdentifier")
            self.require(
                isinstance(bundle_id, str) and bundle_id.startswith(app_id + "."),
                f"extension bundle ID is not under the app ID: {bundle.relative_to(self.app)}",
            )
            self.require(
                info.get("CFBundleShortVersionString") == self.app_version,
                f"extension version differs from the app: {bundle.relative_to(self.app)}",
            )
            self.require(
                info.get("CFBundleVersion") == self.app_build,
                f"extension build number differs from the app: {bundle.relative_to(self.app)}",
            )
            self.require(
                bundle.parent.name in {"PlugIns", "Extensions"},
                f"extension is outside PlugIns/Extensions: {bundle.relative_to(self.app)}",
            )
        for framework in self.app.rglob("*.framework"):
            self.require(framework.parent.name == "Frameworks", f"framework is outside Frameworks/: {framework.relative_to(self.app)}")

    def check_macho(self) -> None:
        for path, kind in sorted(self.code_paths.items(), key=lambda item: str(item[0])):
            relative = path.relative_to(self.app)
            self.require(kind != "unexpected", f"Mach-O is in an unexpected location: {relative}")
            architectures_found = architectures(path)
            self.require(self.args.arch in architectures_found, f"{relative} lacks {self.args.arch} (has {sorted(architectures_found)})")
            description = file_description(path)
            is_dynamic = "dynamically linked shared library" in description
            if kind == "framework":
                self.require(is_dynamic, f"framework executable is not a dynamic library: {relative}")
            elif kind in {"app", "extension"}:
                self.require("executable" in description and not is_dynamic, f"{kind} executable has the wrong Mach-O type: {relative}")
            elif kind in {"debug-dylib", "unexpected"}:
                self.require(is_dynamic, f"dylib has the wrong Mach-O type: {relative}")

    def check_signatures(self) -> None:
        if self.args.unsigned:
            return

        for bundle in sorted((b for b in self.bundles if b != self.app),
                             key=lambda item: len(item.parts), reverse=True):
            self.verify_signature(bundle)
            if self.profiles_required and bundle.suffix == ".appex":
                self.verify_profile(bundle)
                self.verify_entitlements(bundle)
        if self.profiles_required:
            self.verify_profile(self.app)
            self.verify_entitlements(self.app)
        for path in sorted(self.code_paths, key=lambda item: len(item.parts), reverse=True):
            if path not in {self.bundle_executable(bundle) for bundle in self.bundles}:
                self.verify_signature(path)
        # Verify the app last so its sealed resources are checked after all nested code.
        self.verify_signature(self.app)

    def verify_signature(self, path: Path) -> None:
        relative = path.relative_to(self.app)
        checked = command(["codesign", "--verify", "--strict", "--verbose=2", str(path)], check=False)
        if checked.returncode != 0:
            detail = (checked.stderr or checked.stdout).decode("utf-8", "replace").strip()
            self.fail(f"signature verification failed for {relative}: {detail}")
        details = signing_details(path)
        signature = details.get("Signature", "")
        authorities = [
            line for line in details.get("_authority", "").splitlines() if line
        ]
        if not signature and not authorities and not details.get("Authority"):
            self.fail(f"unsigned code object: {relative}")
            return
        if signature == "adhoc" and not self.args.allow_adhoc:
            self.fail(f"ad-hoc signature cannot install on a device: {relative}")
        expected_team = self.args.team_id
        if expected_team and details.get("TeamIdentifier") != expected_team:
            self.fail(f"signature team mismatch for {relative}: expected {expected_team}, got {details.get('TeamIdentifier', 'none')}")
        expected_identity = self.args.signing_identity
        if expected_identity and expected_identity not in details.get("Authority", ""):
            self.fail(f"signing identity mismatch for {relative}: expected authority containing {expected_identity}")

    def verify_profile(self, bundle: Path) -> None:
        relative = bundle.relative_to(self.app)
        profile = profile_for(bundle)
        if profile is None:
            self.fail(f"embedded provisioning profile is missing: {relative}")
            return
        self.profiles[bundle] = profile
        team = self.args.team_id
        if team:
            self.require(team in as_list(profile.get("TeamIdentifier")), f"profile team mismatch: {relative}")
        expiration = profile.get("ExpirationDate")
        self.require(
            isinstance(expiration, dt.datetime) and expiration > dt.datetime.now(expiration.tzinfo),
            f"provisioning profile is expired: {relative}",
        )
        info = load_plist(bundle / "Info.plist")
        bundle_id = info.get("CFBundleIdentifier")
        self.require(
            isinstance(bundle_id, str) and profile_allows_identifier(profile, str(team) + "." + bundle_id),
            f"provisioning profile does not authorize {bundle_id}: {relative}",
        )

    def verify_entitlements(self, bundle: Path) -> None:
        relative = bundle.relative_to(self.app)
        info = load_plist(bundle / "Info.plist")
        bundle_id = info.get("CFBundleIdentifier")
        if not isinstance(bundle_id, str):
            return
        entitlements = signing_entitlements(bundle)
        profile = self.profiles.get(bundle)
        if not entitlements:
            if self.profiles_required:
                self.fail(f"signed bundle has no readable entitlements: {relative}")
            return
        team = self.args.team_id
        if team:
            expected_application_id = f"{team}.{bundle_id}"
            self.require(
                entitlements.get("application-identifier") == expected_application_id,
                f"application-identifier mismatch for {relative}",
            )
            self.require(
                entitlements.get("com.apple.developer.team-identifier") == team,
                f"team entitlement mismatch for {relative}",
            )
            if profile is not None:
                profile_entitlements = profile.get("Entitlements", {})
                self.require(
                    profile_entitlements.get("application-identifier") is not None
                    and profile_allows_identifier(profile, expected_application_id),
                    f"profile does not match signed application identifier: {relative}",
                )
                for group in as_list(entitlements.get("com.apple.security.application-groups")):
                    self.require(
                        group in as_list(profile_entitlements.get("com.apple.security.application-groups")),
                        f"profile does not authorize App Group {group}: {relative}",
                    )
        if profile is not None:
            profile_entitlements = profile.get("Entitlements", {})
            for key in ("get-task-allow",):
                if key in entitlements and key in profile_entitlements:
                    self.require(entitlements[key] == profile_entitlements[key], f"entitlement/profile mismatch for {key}: {relative}")

    def print_report(self) -> None:
        print(f"APP {self.app.name}")
        print(f"BUNDLE_ID {self.app_id}")
        print(f"VERSION {self.app_version} ({self.app_build})")
        for bundle in sorted(self.bundles, key=lambda item: str(item)):
            if bundle == self.app:
                continue
            kind = "extension" if bundle.suffix == ".appex" else "framework"
            print(f"{kind.upper():9} {bundle.relative_to(self.app)}")
        for path, kind in sorted(self.code_paths.items(), key=lambda item: str(item[0])):
            description = file_description(path)
            arches = ",".join(sorted(architectures(path)))
            if self.args.unsigned:
                signature = "unsigned-build"
            else:
                signature = signing_details(path).get("Signature", "cms")
            print(f"CODE {kind:9} {signature:14} {arches:8} {path.relative_to(self.app)} [{description}]")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("path", type=Path, help=".ipa or .app to verify")
    parser.add_argument("--require-native-node", action="store_true", help="require the embedded NodeMobile runtime and JS host")
    parser.add_argument("--require-engine", action="store_true", help="require all DSH Engine frameworks and runtime.zip")
    parser.add_argument("--unsigned", action="store_true", help="verify layout only for a CODE_SIGNING_ALLOWED=NO build")
    parser.add_argument("--allow-adhoc", action="store_true", help="allow simulator/ad-hoc signatures")
    parser.add_argument(
        "--require-profiles",
        action="store_true",
        help="require embedded provisioning profiles and device entitlements even for ad-hoc builds",
    )
    parser.add_argument("--allow-root-debug-dylibs", action="store_true", help="allow Runner.debug.dylib/__preview.dylib in a simulator build")
    parser.add_argument("--team-id", help="expected Apple Team ID")
    parser.add_argument("--signing-identity", help="expected signing authority substring")
    parser.add_argument("--arch", default="arm64", help="required Mach-O architecture (default: arm64)")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    source = args.path.resolve()
    if not source.exists():
        print(f"error: input does not exist: {source}", file=sys.stderr)
        return 2
    if not all(shutil.which(tool) for tool in ("codesign", "ditto", "file", "lipo")):
        print("error: verify-ipa.py requires macOS codesign, ditto, file and lipo", file=sys.stderr)
        return 2

    temporary: tempfile.TemporaryDirectory[str] | None = None
    try:
        if source.is_dir() and source.suffix == ".app":
            app = source
            extracted_root = None
        elif source.is_file() and source.suffix.lower() == ".ipa":
            temporary = tempfile.TemporaryDirectory(prefix="dsh-ipa-")
            extracted_root = Path(temporary.name)
            safe_extract(source, extracted_root)
            apps = [p for p in sorted((extracted_root / "Payload").glob("*.app")) if p.is_dir()]
            if len(apps) != 1:
                raise VerifyError(f"IPA must contain exactly one Payload/*.app, found {len(apps)}")
            app = apps[0]
        else:
            raise VerifyError("input must be an .ipa file or an extracted .app directory")

        verifier = Verifier(args, app, extracted_root)
        verifier.run()
        print("PASS all iOS layout and signature checks")
        return 0
    except VerifyError as error:
        print(f"FAIL {error}", file=sys.stderr)
        for message in getattr(error, "details", []):
            print(f"  - {message}", file=sys.stderr)
        return 1
    except (OSError, zipfile.BadZipFile) as error:
        print(f"FAIL {error}", file=sys.stderr)
        return 1
    finally:
        if temporary is not None:
            temporary.cleanup()


if __name__ == "__main__":
    raise SystemExit(main())
