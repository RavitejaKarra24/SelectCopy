#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"
ARGS=(--disable-xctest)
# Swift 6.4's Command Line Tools ship Testing but the default SwiftPM build
# engine doesn't discover its macro plugin. Full Xcode needs no workaround.
SWIFTC=$(xcrun --find swiftc)
PLUGIN="$(dirname "$SWIFTC")/../lib/swift/host/plugins/testing/libTestingMacros.dylib"
if [[ "$SWIFTC" == */CommandLineTools/* && -f "$PLUGIN" ]]; then
  ARGS+=(-Xswiftc -load-plugin-library -Xswiftc "$PLUGIN")
fi
swift test "${ARGS[@]}" "$@"
