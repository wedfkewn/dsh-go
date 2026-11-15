#!/usr/bin/env bash
# Starts phone control on an iPhone connected to this Mac: a UI test that doesn't end, which is
# the only thing iOS lets read and drive other apps. Keep this running while you use it.
#
#   tooling/ios/phone-runner.sh <device id>      (xcrun devicectl list devices)
#
# Sign the PhoneRunnerUITests target with the same Team as the app first, in Xcode, so that they
# share the App Group. The phone needs Developer Mode on.
set -euo pipefail

DEVICE="${1:?usage: phone-runner.sh <device id>}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FLUTTER_BIN="$(bash "$ROOT/tooling/ios/ensure-flutter-ios-project.sh")" || exit $?
FLUTTER_ROOT="$(cd "$(dirname "$FLUTTER_BIN")/.." && pwd -P)"
export FLUTTER_ROOT
cd "$ROOT/app"
exec xcodebuild test -workspace ios/Runner.xcworkspace -scheme PhoneRunner -destination "id=$DEVICE" -allowProvisioningUpdates
