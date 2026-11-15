#!/usr/bin/env bash
# Resolve Flutter, refresh the generated iOS package, and return the executable
# path on stdout. Keep every diagnostic off stdout so callers can safely use
# command substitution to capture the path.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
APP="$ROOT/app"

log() {
  printf '%s\n' "$*" >&2
}

flutter_bin=""
if candidate="$(command -v flutter 2>/dev/null)"; then
  if [[ -n "$candidate" && -x "$candidate" ]]; then
    flutter_bin="$candidate"
  fi
fi
if [[ -z "$flutter_bin" && -n "${HOME:-}" && -x "$HOME/flutter/bin/flutter" ]]; then
  flutter_bin="$HOME/flutter/bin/flutter"
fi
if [[ -z "$flutter_bin" && -n "${FLUTTER_ROOT:-}" && -x "$FLUTTER_ROOT/bin/flutter" ]]; then
  flutter_bin="$FLUTTER_ROOT/bin/flutter"
fi

if [[ -z "$flutter_bin" ]]; then
  log "Flutter SDK not found: no executable 'flutter' on PATH, at \$HOME/flutter/bin/flutter, or at \$FLUTTER_ROOT/bin/flutter."
  log "Install Flutter or add its bin directory to PATH, then rerun this command."
  log "Exited with status code 127"
  exit 127
fi

# FLUTTER_ROOT is read by Xcode's xcode_backend.sh. Derive it from the
# executable that was actually found instead of trusting a stale environment
# value that might point at a different SDK.
FLUTTER_ROOT="$(cd "$(dirname "$flutter_bin")/.." && pwd -P)"
export FLUTTER_ROOT

log "Using Flutter SDK: $FLUTTER_ROOT"
log "Refreshing Flutter iOS dependencies in $APP"
status=0
(cd "$APP" && "$flutter_bin" pub get && "$flutter_bin" build ios --config-only --no-pub) >&2 || status=$?
if [[ "$status" -ne 0 ]]; then
  log "Flutter iOS preparation failed (exit $status); the package product was not generated."
  exit "$status"
fi

generated_xcconfig="$APP/ios/Flutter/Generated.xcconfig"
generated_package="$APP/ios/Flutter/ephemeral/Packages/FlutterGeneratedPluginSwiftPackage/Package.swift"
missing=0
if [[ ! -f "$generated_xcconfig" ]]; then
  log "Missing generated Flutter Xcode configuration: $generated_xcconfig"
  missing=1
fi
if [[ ! -f "$generated_package" ]]; then
  log "Missing package product 'FlutterGeneratedPluginSwiftPackage': $generated_package"
  missing=1
fi
if [[ "$missing" -ne 0 ]]; then
  log "Open app/ios/Runner.xcworkspace and ensure flutter pub get completed before Xcode builds."
  exit 1
fi

# This is the only stdout output: callers can capture the executable without
# mixing in Flutter's progress or diagnostics.
printf '%s\n' "$flutter_bin"
