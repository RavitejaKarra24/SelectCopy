#!/usr/bin/env bash
# Adapted from the macos-spm-app-packaging template (no external frameworks).
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"
CONFIGURATION=${1:-release}
swift build -c "$CONFIGURATION"
BIN_DIR=$(swift build -c "$CONFIGURATION" --show-bin-path)
APP="$ROOT/build/SelectCopy.app"
mkdir -p "$ROOT/build"
# Only remove our generated bundle, never the build directory.
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN_DIR/SelectCopy" "$APP/Contents/MacOS/SelectCopy"
cp "$BIN_DIR/select_copy" "$ROOT/build/select_copy"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
chmod +x "$APP/Contents/MacOS/SelectCopy" "$ROOT/build/select_copy"
/usr/bin/plutil -lint "$APP/Contents/Info.plist"
# An identity can be supplied for stable permissions across rebuilds.
IDENTITY=${SIGNING_IDENTITY:--}
if [[ "$IDENTITY" == "-" ]]; then
  /usr/bin/codesign --force --sign - --identifier local.select-copy.agent "$APP"
else
  /usr/bin/codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP"
fi
/usr/bin/codesign --verify --strict "$APP"
printf 'Built %s\nCLI: %s\n' "$APP" "$ROOT/build/select_copy"
