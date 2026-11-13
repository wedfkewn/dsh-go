#!/usr/bin/env bash
set -euo pipefail
artifacts="$SRCROOT/NativeNodeArtifacts"
[[ -d "$artifacts/NodeMobile.xcframework" && -d "$artifacts/engine" ]] || {
  echo 'error: Run runtime/native-node/prepare-ios.sh with the pinned payload before building Runner.' >&2
  exit 1
}
case "$PLATFORM_NAME" in
  iphoneos) slice=ios-arm64 ;;
  iphonesimulator) slice=ios-arm64-simulator ;;
  *) exit 0 ;;
esac
if [[ " $ARCHS " != " arm64 " ]]; then
  echo 'error: NodeMobile 24.20.0 requires an arm64 Runner build' >&2
  exit 1
fi
framework="$TARGET_BUILD_DIR/$FRAMEWORKS_FOLDER_PATH/NodeMobile.framework"
resources="$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH/NativeNode"
mkdir -p "$framework" "$resources"
rsync -a --delete "$artifacts/NodeMobile.xcframework/$slice/NodeMobile.framework/" "$framework/"
rsync -a --delete "$artifacts/engine/" "$resources/"
cp "$SRCROOT/../../runtime/native-node/"{supervisor,engine-worker}.mjs "$resources/"
if [[ "${CODE_SIGNING_ALLOWED:-NO}" == YES && -n "${EXPANDED_CODE_SIGN_IDENTITY:-}" ]]; then
  codesign --force --sign "$EXPANDED_CODE_SIGN_IDENTITY" "$framework"
elif [[ "$PLATFORM_NAME" == iphonesimulator ]]; then
  codesign --force --sign - "$framework"
fi
