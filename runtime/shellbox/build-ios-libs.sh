#!/usr/bin/env bash
# Build libraries for Runner. iOS compilation requires macOS ARM64.
# Adapted from pinned ShellBox .github/workflows/static-libs.yml:102-157.
# No signing or runtime startup is performed.
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
# Keep math.S definitions matching gen.c; bits.S duplicates break force-load.
# Accept an already-patched checkout so device/simulator rebuilds are repeatable.
patch_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
for patch_name in fix-duplicate-gadgets.patch fix-node24-v8-flags.patch; do
  patch_file="$patch_dir/$patch_name"
  if git -C "$source_dir" apply --check "$patch_file"; then
    git -C "$source_dir" apply "$patch_file"
  else
    git -C "$source_dir" apply --reverse --check "$patch_file"
  fi
done
# Upstream host tools plus CMake for the new iOS libarchive source build.
brew install llvm lld ninja libarchive meson cmake
mkdir -p "$output_dir"
cd "$output_dir"
output_dir="$PWD"
# Pinned source, never a Homebrew macOS bottle in the iOS link.
archive_tar=libarchive-3.8.11.tar.xz
if [[ ! -f "$archive_tar" ]]; then
  curl --fail --location https://www.libarchive.org/downloads/"$archive_tar" -o "$archive_tar"
fi
printf '%s  %s\n' a3dc0872b1b39da34dc18ef1b944f0f11ffd37425d70ae04be679279f1cf43d2 "$archive_tar" | shasum -a 256 -c -
if [[ ! -d libarchive-3.8.11 ]]; then
  tar -xf "$archive_tar"
fi
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
  local meson_options=(setup)
  if [[ -f "build-$name/meson-private/coredata.dat" ]]; then
    meson_options+=(--reconfigure)
  fi
  meson "${meson_options[@]}" "build-$name" "$source_dir" -Dguest_arch=arm64 \
    --buildtype=release --cross-file "$name.ini"
  ninja -C "build-$name" libish.a libish_emu.a libfakefs.a
  # Record SDK evidence without using private SDK stubs or host libraries.
  printf '%s\n' '#include <archive.h>' 'int main(void) { return archive_read_free(archive_read_new()); }' > "$name-archive-probe.c"
  if xcrun --sdk "$sdk" clang -arch arm64 -isysroot "$sysroot" "$min" \
      "$name-archive-probe.c" -larchive -o "$name-archive-probe" > "$name-archive-probe.log" 2>&1; then
    echo "$sdk: SDK libarchive compile/link probe passed" | tee -a "$name-archive-probe.log"
  else
    echo "$sdk: SDK libarchive unavailable through public headers/link; using static source build" | tee -a "$name-archive-probe.log"
  fi
  local options=() option
  for option in MBEDTLS NETTLE OPENSSL MD LIBB2 LZ4 LZO LZMA ZSTD BZip2 LIBXML2 BSDXML EXPAT WIN32_XMLLITE PCREPOSIX PCRE2POSIX LIBGCC CNG TAR CPIO CAT UNZIP XATTR ACL ICONV TEST; do
    options+=("-DENABLE_$option=OFF")
  done
  cmake -S "$output_dir/libarchive-3.8.11" -B "archive-$name" -G Ninja \
    -DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_SYSROOT="$sysroot" \
    -DCMAKE_C_COMPILER="$(xcrun --sdk "$sdk" --find clang)" \
    -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=13.0 \
    -DCMAKE_BUILD_TYPE=MinSizeRel -DBUILD_SHARED_LIBS=OFF \
    -DENABLE_ZLIB=ON -DZLIB_INCLUDE_DIR="$sysroot/usr/include" \
    -DZLIB_LIBRARY="$sysroot/usr/lib/libz.tbd" "${options[@]}"
  cmake --build "archive-$name" --target archive_static
  cp "archive-$name/libarchive/libarchive.a" "build-$name/libarchive.a"
  # fchdir is already in libish.a; do not define it a second time.
  xcrun --sdk "$sdk" clang -arch arm64 -isysroot "$sysroot" "$min" -O2 \
    -DGUEST_ARM64=1 -I"$source_dir" -I"$output_dir/build-$name" \
    -I"$output_dir/libarchive-3.8.11/libarchive" \
    -c "$source_dir/tools/fakefs.c" -o "build-$name/fakefs-tools.o"
  xcrun --sdk "$sdk" ar rcs "build-$name/libfakefs_tools.a" "build-$name/fakefs-tools.o"
  cp libarchive-3.8.11/COPYING "build-$name/libarchive-COPYING"

}
build ios-arm64 iphoneos '-miphoneos-version-min=13.0'
build iossim-arm64 iphonesimulator '-mios-simulator-version-min=13.0'
# Output per SDK: libish.a, libish_emu.a, libfakefs.a, libfakefs_tools.a,
# libarchive.a and libarchive-COPYING. Final Runner link must be verified on Mac.
