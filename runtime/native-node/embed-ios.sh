#!/usr/bin/env bash
set -euo pipefail
artifacts="$SRCROOT/NativeNodeArtifacts"
if [[ ! -e "$artifacts" ]]; then
  echo "note: NativeNodeArtifacts isn't prepared; this build connects to remote hosts only."
  exit 0
fi
if [[ ! -d "$artifacts/NodeMobile.xcframework" || ! -d "$artifacts/engine" ]]; then
  echo 'error: NativeNodeArtifacts is incomplete; rerun runtime/native-node/prepare-ios.sh with the pinned payload.' >&2
  exit 1
fi
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
cp "$SRCROOT/../../runtime/native-node/"{supervisor,engine-worker,pnpm-ios,pnpm-worker}.mjs "$resources/"
# NodeMobile on iOS has no POSIX flock addon, and this runtime is a single DSH
# process per app container, so the session write claim is already exclusive.
# Rewrite the entry after the copy (never in NativeNodeArtifacts) so device and
# simulator builds use the browser worker's single-process behaviour.
cp "$SRCROOT/../../runtime/native-node/flock-ios.mjs" \
  "$resources/node_modules/@deepseek-ai/node-addon-system/lib/flock.js"
if [[ "${CODE_SIGNING_ALLOWED:-NO}" == YES && -n "${EXPANDED_CODE_SIGN_IDENTITY:-}" ]]; then
  codesign --force --sign "$EXPANDED_CODE_SIGN_IDENTITY" "$framework"
elif [[ "$PLATFORM_NAME" == iphonesimulator ]]; then
  codesign --force --sign - "$framework"
fi
