#!/usr/bin/env bash
# Re-sign an already-built Runner.app (for example the output of
# `flutter build ios --release --no-codesign`) with a real Apple identity and
# per-bundle provisioning profiles, then optionally package an .ipa.
#
# It signs nested code from the inside out and never uses `codesign --deep`,
# because a recursive re-sign hides unsigned or wrongly signed nested code.
# Finish by running tooling/ios/verify-ipa.py on the result.
#
#   tooling/ios/sign-app.sh --app build/ios/iphoneos/Runner.app \
#     --identity "Apple Development: Example (TEAMID)" \
#     --profiles ~/Desktop/profiles --team-id TEAMID --output ~/Desktop/DSH.ipa
#
# The profiles directory holds one .mobileprovision per signed bundle
# (Runner, Runner.ShareExtension, Runner.PetLiveActivity). They are never
# committed to the repository.
set -euo pipefail

app=""
identity=""
profiles_dir=""
team=""
output=""
adhoc=0
timestamp_flag="--timestamp=none"

usage() {
  sed -n '2,16p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
  exit "${1:-2}"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --app) app="${2:?}"; shift 2 ;;
    --identity) identity="${2:?}"; shift 2 ;;
    --profiles) profiles_dir="${2:?}"; shift 2 ;;
    --team-id) team="${2:?}"; shift 2 ;;
    --output) output="${2:?}"; shift 2 ;;
    --adhoc) adhoc=1; shift ;;
    --timestamp) timestamp_flag="--timestamp"; shift ;;
    -h|--help) usage 0 ;;
    *) echo "unknown argument: $1" >&2; usage ;;
  esac
done

[[ -n "$app" && -d "$app" && "${app##*.}" == "app" ]] || { echo 'error: --app must be an existing .app directory' >&2; exit 2; }
if [[ "$adhoc" == 0 ]]; then
  [[ -n "$identity" ]] || { echo 'error: --identity is required unless --adhoc' >&2; exit 2; }
  [[ -d "$profiles_dir" ]] || { echo 'error: --profiles directory is required unless --adhoc' >&2; exit 2; }
fi

work="$(mktemp -d "${TMPDIR:-/tmp}/dsh-sign.XXXXXX")"
trap 'rm -rf "$work"' EXIT

echo "Preparing bundle and profile layout"
python3 - "$app" "$profiles_dir" "$team" "$adhoc" "$work" <<'PY'
import os, pathlib, plistlib, shutil, subprocess, sys

app = pathlib.Path(sys.argv[1]).resolve()
profiles_dir = pathlib.Path(sys.argv[2]).resolve() if sys.argv[2] else None
team = sys.argv[3]
adhoc = sys.argv[4] == '1'
work = pathlib.Path(sys.argv[5])

def load_plist(path):
    with open(path, 'rb') as f:
        return plistlib.load(f)

def decode_profile(path):
    return plistlib.loads(subprocess.check_output(['security', 'cms', '-D', '-i', str(path)]))

profiles = []
if profiles_dir:
    cache = work / 'profiles'
    cache.mkdir()
    for index, item in enumerate(sorted(profiles_dir.glob('*.mobileprovision'))):
        copy = cache / f'{index}.mobileprovision'
        shutil.copy2(item, copy)
        value = decode_profile(copy)
        profiles.append((copy, value))

bundles = [app] + sorted(p for p in app.rglob('*.appex') if p.is_dir())
records = []
for bundle in bundles:
    info = load_plist(bundle / 'Info.plist')
    bundle_id = info['CFBundleIdentifier']
    record = {'path': str(bundle), 'id': bundle_id}
    if not adhoc:
        match = None
        for path, profile in profiles:
            ents = profile.get('Entitlements', {})
            app_id = ents.get('application-identifier', '')
            team_ok = bool(team) and team in profile.get('TeamIdentifier', [])
            # A wildcard profile would put TEAM.* into the signed
            # application-identifier entitlement. Xcode archive export normally
            # resolves an explicit App ID; require the same precision here so a
            # profile mismatch cannot be hidden behind a wildcard.
            if team_ok and app_id == f'{team}.{bundle_id}':
                match = (path, profile)
                break
        if match is None:
            sys.exit(f'error: no exact provisioning profile authorizes {team}.{bundle_id}')
        path, profile = match
        expiry = profile.get('ExpirationDate')
        import datetime
        if not isinstance(expiry, datetime.datetime) or expiry <= datetime.datetime.now(expiry.tzinfo):
            sys.exit(f'error: provisioning profile for {bundle_id} is expired')
        shutil.copy2(path, bundle / 'embedded.mobileprovision')
        ents = profile.get('Entitlements', {})
        ent_file = work / (bundle.name + '.entitlements')
        with open(ent_file, 'wb') as f:
            plistlib.dump(ents, f)
        record['entitlements'] = str(ent_file)
    records.append(record)

with open(work / 'records.json', 'wb') as f:
    import json
    f.write(json.dumps(records).encode())
print('bundles: ' + ', '.join(r['id'] for r in records))
PY

records="$work/records.json"

sign() { # sign TARGET [ENTITLEMENTS]
  local target="$1" entitlements="${2:-}"
  local args=(--force --sign "$identity" "$timestamp_flag")
  [[ -n "$entitlements" ]] && args+=(--entitlements "$entitlements" --generate-entitlement-der)
  if [[ "$adhoc" == 1 ]]; then
    args=(--force --sign - --timestamp=none)
  fi
  echo "  sign ${target#$app/}"
  /usr/bin/codesign "${args[@]}" "$target"
}

if [[ "$adhoc" == 0 ]]; then
  echo "Signing with: $identity"
else
  echo "Signing ad-hoc (simulator/local testing only)"
fi

# 1. Frameworks, deepest first, so an outer bundle never seals unsigned inner code.
# macOS ships bash 3.2, which has no mapfile; read the sorted list instead.
find "$app" -type d -name '*.framework' | awk -F/ '{print NF"\t"$0}' | sort -rn | cut -f2- > "$work/frameworks.txt"
while IFS= read -r framework; do
  [[ -n "$framework" ]] || continue
  sign "$framework"
done < "$work/frameworks.txt"

# 2. Any remaining Mach-O inside an extension or the app that is not a bundle
#    executable; frameworks are already done.
python3 - "$app" "$records" > "$work/machos.txt" <<'PY'
import json, pathlib, plistlib, sys
app = pathlib.Path(sys.argv[1])
records = json.load(open(sys.argv[2]))
execs = set()
for record in records:
    bundle = pathlib.Path(record['path']).resolve()
    with open(bundle / 'Info.plist', 'rb') as handle:
        name = plistlib.load(handle).get('CFBundleExecutable')
    if name:
        execs.add(str(bundle / name))
mags = {b'\xfe\xed\xfa\xce', b'\xce\xfa\xed\xfe', b'\xfe\xed\xfa\xcf', b'\xcf\xfa\xed\xfe',
        b'\xca\xfe\xba\xbe', b'\xbe\xba\xfe\xca', b'\xca\xfe\xba\xbf', b'\xbf\xba\xfe\xca'}
for path in app.rglob('*'):
    if (not path.is_file() or str(path.resolve()) in execs
            or any(part.endswith('.framework') for part in path.parts)):
        continue
    try:
        with open(path, 'rb') as handle:
            if handle.read(4) not in mags:
                continue
    except OSError:
        continue
    print(path)
PY
while IFS= read -r macho; do
  [[ -n "$macho" ]] || continue
  sign "$macho"
done < "$work/machos.txt"

# 3. Extensions, then the app last so its CodeResources seals all nested code.
python3 - "$records" > "$work/sign-order.txt" <<'PY'
import json, sys
records = json.load(open(sys.argv[1]))
for record in reversed(records):
    print(f"{record['path']}\t{record.get('entitlements', '')}")
PY
while IFS=$'\t' read -r path entitlements; do
  [[ -n "$path" ]] || continue
  sign "$path" "${entitlements:-}"
done < "$work/sign-order.txt"

echo "Verifying every nested code object"
verify_args=("$app")
if [[ "$adhoc" == 1 ]]; then
  verify_args+=(--allow-adhoc)
else
  verify_args+=(--require-profiles)
  [[ -n "$team" ]] && verify_args+=(--team-id "$team")
  verify_args+=(--signing-identity "$identity")
fi
python3 tooling/ios/verify-ipa.py "${verify_args[@]}" 2>&1 | tee "$work/verify.log" || {
  echo 'error: verification failed; fix the reported items before installing' >&2
  exit 1
}

if [[ -n "$output" ]]; then
  stage="$work/Payload"
  mkdir -p "$stage"
  cp -R "$app" "$stage/"
  rm -f "$output"
  # Skip resource forks/xattrs so the archive carries no AppleDouble "._" entries.
  ( cd "$work" && /usr/bin/ditto -c -k --keepParent --norsrc --noextattr --noqtn --noacl Payload "$output" )
  echo "IPA: $output"
  python3 tooling/ios/verify-ipa.py "$output" "${verify_args[@]:1}"
fi
echo 'OK: signed app verified inside out (no codesign --deep was used)'
