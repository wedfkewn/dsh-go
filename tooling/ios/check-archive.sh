#!/usr/bin/env bash
# An archive is how a TestFlight build gets made, and it isn't `flutter build ios`: another
# action, other folders, the Release settings Xcode adds for installing. It can't be run here
# (no signing, and Release doesn't run on the simulator), so this builds one without signing and
# looks inside for what a phone would need to get to its first frame.
#
# Two variants share it:
#   check-archive.sh                 Full: app/ios/Engine prepared, engine embedded
#   check-archive.sh --remote-only   Remote Only: no Engine, and the app must not carry any
#                                    engine framework or runtime archive
# Run from the repository root on macOS. Everything goes up as annotations.
set -uo pipefail

mode=full
case "${1:-}" in
  '') ;;
  --remote-only) mode=remote-only ;;
  *)
    printf 'usage: %s [--remote-only]\n' "$0" >&2
    exit 2
    ;;
esac
if [ "$mode" = full ] && [ ! -f app/ios/Engine/.ready ]; then
  printf '::error title=archive::the Full archive needs app/ios/Engine; run tooling/ios/prepare-engine.sh, or pass --remote-only\n'
  exit 1
fi

note() { printf '::notice title=%s::%s\n' "$1" "$(printf '%s' "$2" | tr '\n' ' ' | cut -c1-900)"; }
fail() { printf '::error title=archive::%s\n' "$(printf '%s' "$1" | tr '\n' ' ' | cut -c1-900)"; failed=1; }
failed=0

# Archive can also be run independently of the Flutter build wrapper. Prepare
# the pinned native inputs before Xcode reads its conditional xcconfig.
bash tooling/ios/build-phone-self-runner.sh || { fail 'phone native library preparation failed'; exit 1; }

archive="$RUNNER_TEMP/Runner.xcarchive"
log="$(mktemp)"
flutter_args=(build ios --release --no-codesign --config-only)
if [ "$mode" = remote-only ]; then
  flutter_args+=(--dart-define=DSH_REMOTE_ONLY=true)
fi
(cd app && flutter "${flutter_args[@]}") >"$log" 2>&1 || {
  tail -20 "$log"
  fail "flutter couldn't write the configuration: $(tail -3 "$log")"
  exit 1
}
if [ "$mode" = remote-only ]; then
  # The Dart side hides local-engine entries behind this define; fail before the long
  # archive if the configuration didn't take it. Flutter stores DART_DEFINES in
  # Generated.xcconfig as comma-separated base64 entries.
  defines="$(sed -n 's/^DART_DEFINES=//p' app/ios/Flutter/Generated.xcconfig | head -1)"
  decoded="$(printf '%s' "$defines" |
    python3 -c 'import base64, sys; print(",".join(base64.b64decode(part).decode("utf-8", "replace") for part in sys.stdin.read().strip().split(",") if part))' 2>/dev/null)"
  case "$decoded" in
    *DSH_REMOTE_ONLY=true*) ;;
    *) fail "the Remote Only configuration is missing DSH_REMOTE_ONLY=true (DART_DEFINES=${defines:-empty})" ;;
  esac
fi
xcodebuild archive -workspace app/ios/Runner.xcworkspace -scheme Runner -configuration Release \
  -destination 'generic/platform=iOS' -archivePath "$archive" \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO >"$log" 2>&1
status=$?
tail -5 "$log"
if [ "$status" -ne 0 ]; then
  grep -E 'error:|\(Xcode\):|\*\* ARCHIVE' "$log" | awk '!seen[$0]++' | head -8 | cut -c1-600 \
    | sed -e 's/%/%25/g' -e 's/^/::error title=archive::/'
  exit 1
fi

app="$archive/Products/Applications/Runner.app"
[ -d "$app" ] || { fail "no Runner.app in the archive"; exit 1; }
frameworks="$app/Frameworks"
note 'archive variant' "$mode"
note 'archive frameworks' "$(ls "$frameworks" | tr '\n' ' ')"

engine_frameworks='DshNodeHost DshFlock DshRequireBuiltin DshGuest DshGuestBridge'
if [ "$mode" = remote-only ]; then
  # Remote Only connects to other hosts; every one of these is code it never loads.
  for name in $engine_frameworks NodeMobile; do
    [ -e "$frameworks/$name.framework" ] && fail "Remote Only carries $name.framework"
  done
  [ -e "$app/dsh-runtime" ] && fail 'Remote Only carries the dsh-runtime resources'
  runtime_file="$(find "$app" \( -name 'runtime.zip' -o -name 'runtime-download.json' \) | head -3 | tr '\n' ' ')"
  [ -n "$runtime_file" ] && fail "Remote Only carries a runtime archive or download source: $runtime_file"
  note 'archive engine' 'none: no engine framework and no runtime archive'
else
  # What the engine opens itself, by these exact paths, when it starts.
  for name in $engine_frameworks; do
    [ -f "$frameworks/$name.framework/$name" ] || fail "the engine needs $name.framework/$name"
  done
  guest="$frameworks/DshGuest.framework"
  for name in DshGuest DshGuestBridge; do
    if [ -f "$frameworks/$name.framework/$name" ]; then
      lipo "$frameworks/$name.framework/$name" -verify_arch arm64 || fail "$name has no arm64 slice"
    fi
  done
  for name in LICENSE.txt SOURCE.txt iSH-LICENSE.md iSH-LICENSE.IOS iSH-build.patch iSH-job-runtime.patch; do
    [ -s "$guest/$name" ] || fail "DshGuest is missing its source/license notice: $name"
  done
  # A Full app that installs its local engine in the app carries one of these.
  [ -f "$app/dsh-runtime/runtime.zip" ] || [ -f "$app/dsh-runtime/runtime-download.json" ] ||
    fail 'the Full app has no dsh-runtime archive or download source'
  note 'archive engine' 'engine frameworks embedded, runtime archive or download source present'
fi
note 'archive size' "$(du -sh "$app" | cut -f1), top level: $(ls "$app" | grep -vE '\.(png|car|nib|storyboardc|lproj)$' | head -30 | tr '\n' ' ')"

# The Rust library is linked into Runner, not a loose executable or dylib. The
# read-only C ABI identity is referenced by Swift and survives Release stripping.
phone_identity='dsh-phone-core:1;idevice=3854a5df4a5a6dee71ffce4d8befc2ea356a8065'
strings "$app/Runner" >"$log"
grep -Fxq "$phone_identity" "$log" || fail 'Runner is missing the pinned CoreDevice native build identity'
for name in LICENSE.idevice.txt THIRD_PARTY_CRATES.json NOTICES.txt SOURCE.json; do
  [ -s "$app/PhoneSelfRunnerNotices/$name" ] || fail "phone native source/license notice missing: $name"
done
python3 -I -B tooling/ios/phone-self-runner/license_inventory.py --verify "$app/PhoneSelfRunnerNotices" \
  || fail 'phone native source/license texts or complete inventory coverage are invalid'
note 'archive phone native' 'checked linked build identity and packaged source/license notices; no pairing or clipboard data is packaged'

# Dart's compiled code, and the snapshot symbols the engine looks for in it.
binary="$frameworks/App.framework/App"
if [ -f "$binary" ]; then
  note 'archive App' "$(du -h "$binary" | cut -f1) $(lipo -archs "$binary"), exports: $(nm -gU "$binary" | awk '{print $NF}' | head -8 | tr '\n' ' ')"
  nm -gU "$binary" | grep -qE "kDartSnapshotText|kDartIsolateSnapshotInstructions" || fail "App.framework/App exports no Dart snapshot"
else
  fail "App.framework/App is missing"
fi

assets="$frameworks/App.framework/flutter_assets"
[ -d "$assets" ] || fail "flutter_assets is missing"
[ -f "$assets/kernel_blob.bin" ] && fail "flutter_assets has kernel_blob.bin: a Debug build's Dart in a Release app"
note 'archive assets' "$(ls "$assets" | head -14 | tr '\n' ' ')"

# Native assets (objective_c is what shared_preferences reads through): each one Dart was compiled
# to look for has to be in the app.
manifest="$assets/NativeAssetsManifest.json"
if [ -f "$manifest" ]; then
  note 'archive native assets' "$(tr -d ' \n' <"$manifest")"
  for name in $(grep -oE '[A-Za-z0-9_.-]+\.framework/[A-Za-z0-9_.-]+' "$manifest" | sort -u); do
    [ -f "$frameworks/$name" ] || fail "native asset $name is in the manifest and not in the app"
  done
else
  note 'archive native assets' 'no NativeAssetsManifest.json'
fi

# What dyld has to find before main.
for binary in "$app/Runner" "$frameworks"/*.framework/*; do
  [ -f "$binary" ] && [ -x "$binary" ] || continue
  otool -L "$binary" 2>/dev/null | awk 'NR>1 {print $1}' | grep '^@rpath/' | while read -r lib; do
    [ -e "$frameworks/${lib#@rpath/}" ] || [ -e "/usr/lib/swift/$(basename "$lib")" ] || case "$lib" in
      @rpath/libswift*) ;;
      *) echo "$(basename "$binary") needs $lib" ;;
    esac
  done
done | sort -u >"$log"
if [ -s "$log" ]; then fail "missing at launch: $(cat "$log")"; else note 'archive links' 'everything linked is in the app'; fi

# Code outside a framework: the App Store refuses it, and a tool that signs the app afterwards
# leaves it unsigned, which a phone then won't load.
loose="$(find "$app" \( -name '*.dylib' -o -name '*.so' -o -name '*.node' \) -not -path '*/Frameworks/*.framework/*' | sed "s|$app/||" | head -10 | tr '\n' ' ')"
[ -n "$loose" ] && fail "code outside a framework: $loose"
for framework in "$frameworks"/*.framework; do
  name="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$framework/Info.plist" 2>/dev/null)"
  [ -n "$name" ] && [ -f "$framework/$name" ] || fail "$(basename "$framework") has no Info.plist naming its executable"
done

# The same app as an unsigned .ipa, for a phone: a signing tool (Xcode, or one that signs with
# an Apple ID) still has to sign it before it installs.
ipa="DSH-Go-unsigned.ipa"
artifact='ios-unsigned-ipa'
if [ "$mode" = remote-only ]; then
  ipa="DSH-Go-remote-only-unsigned.ipa"
  artifact='ios-remote-only-unsigned-ipa'
fi
mkdir -p "$RUNNER_TEMP/ipa/Payload"
cp -R "$app" "$RUNNER_TEMP/ipa/Payload/"
(cd "$RUNNER_TEMP/ipa" && /usr/bin/ditto -c -k --keepParent Payload "$RUNNER_TEMP/$ipa")
note 'archive ipa' "$(du -h "$RUNNER_TEMP/$ipa" | cut -f1), unsigned, in the $artifact artifact"

# A text-only description of what was packaged, so the archive can be reviewed
# without pulling the whole .ipa: identity, contents, and checksums.
plist="$app/Info.plist"
read_plist() { /usr/libexec/PlistBuddy -c "Print :$1" "$plist" 2>/dev/null || echo 'unknown'; }
manifest_out="$RUNNER_TEMP/$mode-package-manifest.txt"
{
  echo "variant: $mode"
  echo "commit: ${GITHUB_SHA:-unknown}"
  echo "bundle id: $(read_plist CFBundleIdentifier)"
  echo "version: $(read_plist CFBundleShortVersionString) ($(read_plist CFBundleVersion))"
  echo "minimum os: $(read_plist MinimumOSVersion)"
  echo "app size: $(du -sh "$app" | cut -f1)"
  echo "ipa: $(basename "$ipa") $(wc -c <"$RUNNER_TEMP/$ipa" | tr -d ' ') bytes"
  echo "ipa sha256: $(shasum -a 256 "$RUNNER_TEMP/$ipa" | cut -d' ' -f1)"
  echo "top level: $(ls "$app" | tr '\n' ' ')"
  echo "frameworks: $(ls "$frameworks" | tr '\n' ' ')"
  for name in $engine_frameworks NodeMobile; do
    if [ -e "$frameworks/$name.framework" ]; then
      echo "engine framework $name: present"
    else
      echo "engine framework $name: absent"
    fi
  done
  if [ -f "$app/dsh-runtime/runtime.zip" ]; then
    echo "runtime.zip: $(wc -c <"$app/dsh-runtime/runtime.zip" | tr -d ' ') bytes sha256 $(shasum -a 256 "$app/dsh-runtime/runtime.zip" | cut -d' ' -f1)"
  elif [ -f "$app/dsh-runtime/runtime-download.json" ]; then
    echo "runtime download source: $(tr -d '\n' <"$app/dsh-runtime/runtime-download.json" | cut -c1-400)"
  else
    echo "runtime: none"
  fi
  echo "audit: $( [ "$failed" -eq 0 ] && echo 'looks whole' || echo 'failed' )"
} >"$manifest_out" 2>/dev/null
note 'archive manifest' "$(wc -l <"$manifest_out" | tr -d ' ') lines in $manifest_out"

note 'archive' "$( [ "$failed" -eq 0 ] && echo 'looks whole' || echo 'see the errors')"
exit "$failed"
