# Phase B: Runner payload delivery (Linux implementation, Mac verification pending)

Changed files:

- `app/ios/Runner.xcodeproj/project.pbxproj:10-12,58-60,158-160,264-266`: three resource references/build entries and Runner navigator entries.
- `app/ios/Flutter/ShellBox.xcconfig:12`: force-load `libfakefs_tools.a`, link the SDK-specific static `libarchive.a` alongside existing sqlite3/zlib.
- `runtime/shellbox/build-ios-libs.sh:29-43,69-106`: CMake dependency, pinned source acquisition, repeatable Meson setup, SDK evidence probes, per-SDK libarchive build, fakefs tools compilation and license copy. Both existing patches and pin remain unchanged.
- This notes file.

Runner Copy Bundle Resources copies the existing archive and `payload/MANIFEST.json` directly from the checkout, using paths relative to `app/ios` (SOURCE_ROOT). They land at the root of Runner.app with their original names. This is the smallest mechanism: no Flutter asset duplication, download, custom copy phase, or runtime installer. Missing input fails the build. Xcode handles resource dependencies and copying. The app grows by approximately **218 MB** (218,112,716 bytes compressed payload, about 208 MiB), plus the manifest and native library code. No archive is added to git; the existing `payload/*.tar.gz` ignore remains intact. Phase C must resolve the bundle resource URL; the manifest's historical absolute build paths are provenance, not runtime paths.

New native dependency: **libarchive 3.8.11**, BSD-2-Clause and per-file notices, downloaded from https://www.libarchive.org/downloads/libarchive-3.8.11.tar.xz with SHA256 `a3dc0872b1b39da34dc18ef1b944f0f11ffd37425d70ae04be679279f1cf43d2`. Version/hash/license evidence: [Homebrew formula](https://raw.githubusercontent.com/Homebrew/homebrew-core/master/Formula/lib/libarchive.rb). Build option evidence: [upstream versioned CMakeLists](https://github.com/libarchive/libarchive/blob/v3.8.11/CMakeLists.txt). The source archive and builds stay in the supplied output directory outside the checkout. Upstream COPYING is copied into Runner as `libarchive-COPYING`; retain it when distributing. CMake is a new build tool dependency.

The Homebrew bottle is a macOS build, not an iOS library. It remains a host tool dependency inherited from ShellBox; it is never passed into the Runner link. Libarchive is cross-compiled separately for iphoneos and iphonesimulator (arm64, minimum 13.0), with SDK zlib, optional compression/crypto/XML/regex/iconv dependencies disabled, and no CLI programs/tests. gzip tar import/export remains supported. ShellBox's pinned `tools/fakefs.c` becomes `libfakefs_tools.a`; its `tools/fakefs.h` remains available under the existing ShellBox source header search path. `util/fchdir.c` is already in libish; compiling another copy would duplicate symbols.

**SDK evidence limitation:** no Apple SDK exists on this Linux server. Public SDK availability of libarchive was not established here, and no claim that it is absent is made. The script records a real public-header + `-larchive` compile/link probe for each selected SDK in `*-archive-probe.log` before building the static alternative. The static source build avoids assuming SDK/private-library availability and supplies both headers and code. The coordinator must inspect those logs and actual SDK files; if public SDK support is proven, using it could remove the new static dependency in a later revision. A probe failure alone does not prove the dylib is absent from devices.

Install/start/stop remain explicitly unimplemented. No plugin, channel test, Android file, workflow, signing setting, or onboarding behavior changed.

Linux validation performed:

- `bash -n runtime/shellbox/build-ios-libs.sh` and `git diff --check`: passed.
- Python JSON parsing and independent SHA256/size comparison against MANIFEST: passed, 218112716 bytes and `b55564360f41aa14ddd57a9807771ae06de0ca7961ec33fdc9d0d4597d72ac65`.
- `git ls-files 'payload/*.tar.gz'`: empty; `git check-ignore payload/*.tar.gz`: archive ignored.
- Python checks of unique PBX object IDs, resource membership and checkout-relative input paths: passed. Not an Xcode parser result.
- Both patches passed clean `git apply --check`, apply, and reverse-check on temporary copies of the relevant files from the pinned local ShellBox checkout. No source checkout was modified. Full build rerun idempotency still needs Mac verification.
- Flutter/Dart unavailable: the eight channel tests were not run. No macOS compile/link, iOS build, simulator execution, fakefs import/export, or device result is claimed. Source download/CMake compilation were not run here (shell network DNS is unavailable).

## Coordinator: exact Mac checks

From the repository root on the cloud Apple Silicon Mac, with the pinned ShellBox checkout and payload already placed:

```bash
export RUNNER_TEMP="${RUNNER_TEMP:-$TMPDIR/dsh-phaseB}"
mkdir -p "$RUNNER_TEMP"
NAME=rootfs-ubuntu24.04.5-node24.22.3-dsh0.2.2-rc.1-arm64.tar.gz
shasum -a 256 "payload/$NAME"
python3 -m json.tool payload/MANIFEST.json > /dev/null
for SDK in iphoneos iphonesimulator; do
  ROOT="$(xcrun --sdk "$SDK" --show-sdk-path)"
  echo "$SDK: $ROOT"
  find "$ROOT/usr" -name '*archive*.tbd' -o -name archive.h
 done
bash runtime/shellbox/build-ios-libs.sh third_party/shellbox-src "$RUNNER_TEMP/shellbox-ios-libs"
# Repeat with the SAME source and output: both patches + Meson/CMake must tolerate rerun.
bash runtime/shellbox/build-ios-libs.sh third_party/shellbox-src "$RUNNER_TEMP/shellbox-ios-libs"
cat "$RUNNER_TEMP/shellbox-ios-libs/ios-arm64-archive-probe.log"
cat "$RUNNER_TEMP/shellbox-ios-libs/iossim-arm64-archive-probe.log"
for TARGET in ios-arm64 iossim-arm64; do
  DIR="$RUNNER_TEMP/shellbox-ios-libs/build-$TARGET"
  xcrun nm -g "$DIR/libfakefs_tools.a" | grep -E 'fakefs_(import|export)'
  xcrun lipo -info "$DIR/libarchive.a"
  test -s "$DIR/libarchive-COPYING"
done
plutil -lint app/ios/Runner.xcodeproj/project.pbxproj
(cd app && flutter pub get && flutter test test/runtime/shellbox_runtime_service_test.dart)
(cd app && flutter build ios --debug --no-codesign)
APP=app/build/ios/iphoneos/Runner.app
cmp "payload/$NAME" "$APP/$NAME"
cmp payload/MANIFEST.json "$APP/MANIFEST.json"
cmp "$RUNNER_TEMP/shellbox-ios-libs/build-ios-arm64/libarchive-COPYING" "$APP/libarchive-COPYING"
xcrun otool -L "$APP/Runner"
(cd app && flutter build ios --simulator --debug)
APP=app/build/ios/iphonesimulator/Runner.app
cmp "payload/$NAME" "$APP/$NAME"
cmp payload/MANIFEST.json "$APP/MANIFEST.json"
```

Expected hash is above. Require all eight channel tests, both unsigned builds and bundle comparisons to pass. Inspect link output for wrong-platform Homebrew libraries, missing symbols, duplicate fchdir/gadget symbols and unexpected dynamic libarchive dependency. Inspect CMake caches for SDK-only zlib paths. The SDK probe binaries are compile/link artifacts, not runnable iOS tests. Native installation and real-device lifecycle testing belong to Phase C; a successful Runner build does not establish runtime import or startup behavior. No Apple ID or signing is needed for these checks.
