#!/usr/bin/env bash
# Prepare the signed app's optional native runtime inputs from pinned sources.
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
archive=${1:?usage: prepare-ios.sh SHELLBOX_PAYLOAD [NODEMOBILE_ZIP]}
version=24.20.0-0
output="$root/app/ios/NativeNodeArtifacts"
stage=$(mktemp -d "${TMPDIR:-/tmp}/dsh-native-node.XXXXXX")
trap 'rm -rf "$stage"' EXIT
zip=${2:-"$stage/node-mobile.zip"}
if [[ $# -lt 2 ]]; then
  curl --fail --location --retry 2 "https://github.com/digidem/nodejs-mobile/releases/download/v$version/nodejs-mobile-ios-$version.zip" -o "$zip"
fi
printf '%s  %s\n' f97c5f368f5982fdc062b0f97d96d7696f94dbaf286fbd0d3c515b596088bca8 "$zip" | shasum -a 256 -c -
printf '%s  %s\n' b55564360f41aa14ddd57a9807771ae06de0ca7961ec33fdc9d0d4597d72ac65 "$archive" | shasum -a 256 -c -
curl --fail --location --retry 2 "https://raw.githubusercontent.com/digidem/nodejs-mobile/v$version/LICENSE" -o "$stage/NodeMobile-LICENSE.txt"
printf '%s  %s\n' c373dabed995013e091b1908996a69a1647ef19d400e6c1fd4b7fb06d8bc0f66 "$stage/NodeMobile-LICENSE.txt" | shasum -a 256 -c -
unzip -q "$zip" 'NodeMobile.xcframework/*' -d "$stage"
# Only the JS dependency tree is needed. Exclude native binaries, including
# addons and platform executables with misleading extensions.
tar -xf "$archive" -C "$stage" opt/dsh usr/local/lib/node_modules/pnpm
# pnpm is a JS bundle. The app cannot fork it, so engine-worker runs this copy
# in a worker thread; see pnpm-ios.mjs.
mkdir -p "$stage/opt/dsh/vendor"
mv "$stage/usr/local/lib/node_modules/pnpm" "$stage/opt/dsh/vendor/pnpm"
rm -rf "$stage/usr/local"
python3 - "$stage/opt/dsh" <<'PY'
import pathlib
import sys

root = pathlib.Path(sys.argv[1]).resolve()
for item in root.rglob('*'):
    if item.is_symlink():
        if not item.resolve().is_relative_to(root):
            item.unlink()
        continue
    if item.is_file():
        with item.open('rb') as f:
            magic = f.read(4)
        if item.suffix in {'.node', '.so', '.dylib', '.dll', '.exe', '.a'} or magic == b'\x7fELF':
            item.unlink()
PY
cat > "$stage/opt/dsh/node_modules/node-addon-require-builtin/lib/index.js" <<'JS'
// NodeMobile is started with --expose-internals. Use its own loader.
exports.requireBuiltin = name => require(name);
JS
mkdir -p "$output"
rsync -a --delete "$stage/NodeMobile.xcframework/" "$output/NodeMobile.xcframework/"
rsync -a --delete "$stage/opt/dsh/" "$output/engine/"
cp "$stage/NodeMobile-LICENSE.txt" "$output/engine/"
cp "$root/runtime/native-node/"{supervisor,engine-worker,pnpm-ios,pnpm-worker}.mjs "$output/engine/"
