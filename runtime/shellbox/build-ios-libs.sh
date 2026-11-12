#!/usr/bin/env bash
# Build-only skeleton, uncompiled/unverified. Intended host: macos-15 ARM64.
# Adapted from pinned ShellBox .github/workflows/static-libs.yml:102-157.
# No workflow, signing, Runner, rootfs or DSH startup is provided.
set -euo pipefail
source_dir="${1:?usage: bash build-ios-libs.sh SOURCE_CHECKOUT OUTPUT_DIRECTORY}"
output_dir="${2:?provide a fresh output directory outside the source checkout}"
expected=5dfc962fe5e03fe5bc6b869b8744312ebe6af627
if [[ "$(uname -s)" != Darwin || "$(uname -m)" != arm64 ]]; then
  echo 'error: requires macOS arm64 (upstream runner: macos-15)' >&2
  exit 1
fi
[[ "$(git -C "$source_dir" rev-parse HEAD)" == "$expected" ]] || {
  echo 'error: ShellBox commit differs from pinned source' >&2
  exit 1
}
source_dir="$(cd "$source_dir" && pwd)"
# Dependency installation exactly as upstream; no installation on Linux.
brew install llvm lld ninja libarchive meson
mkdir -p "$output_dir"
cd "$output_dir"
build() {
  local name="$1" sdk="$2" min="$3" sysroot
  sysroot="$(xcrun --sdk "$sdk" --show-sdk-path)"
  cat >"$name.ini" <<CROSS
[binaries]
c = 'clang'
cpp = 'clang++'
ar = 'ar'
strip = 'strip'
pkg-config = 'pkg-config'

[built-in options]
c_args = ['-arch', 'arm64', '-isysroot', '$sysroot', '$min']
c_link_args = ['-arch', 'arm64', '-isysroot', '$sysroot', '$min']
cpp_args = ['-arch', 'arm64', '-isysroot', '$sysroot', '$min']
cpp_link_args = ['-arch', 'arm64', '-isysroot', '$sysroot', '$min']

[host_machine]
system = 'darwin'
cpu_family = 'aarch64'
cpu = 'aarch64'
endian = 'little'
CROSS
  meson setup "build-$name" "$source_dir" -Dguest_arch=arm64 \
    --buildtype=release --cross-file "$name.ini"
  ninja -C "build-$name" libish.a libish_emu.a libfakefs.a
}
build ios-arm64 iphoneos '-miphoneos-version-min=13.0'
build iossim-arm64 iphonesimulator '-mios-simulator-version-min=13.0'
# Output: build-{ios-arm64,iossim-arm64}/{libish.a,libish_emu.a,libfakefs.a}.
# TODO: verify actual SDK/tool resolution, VDSO and final Xcode link on macOS.
