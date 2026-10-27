#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
mkdir -p "$ROOT/build/module-cache" "$ROOT/build/native-acceptance/runtime-implementation-evidence"
/usr/bin/xcrun swiftc -swift-version 5 -O -parse-as-library -module-cache-path "$ROOT/build/module-cache" -framework AppKit "$ROOT"/SourcesShared/*.swift "$ROOT/tests/CleanupTrashSafetyTests.swift" "$ROOT/tests/NativeQARuntimeTests.swift" -o "$ROOT/build/native-acceptance/runtime-implementation-evidence/NativeQARuntimeTests"
"$ROOT/build/native-acceptance/runtime-implementation-evidence/NativeQARuntimeTests"
