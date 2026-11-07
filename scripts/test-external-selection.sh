#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
BUILD=$(mktemp -d /private/tmp/storage-monitor-external-selection.XXXXXX)
trap '/bin/rm -rf "$BUILD"' EXIT HUP INT TERM
/usr/bin/xcrun swiftc -parse-as-library -swift-version 5 -Onone -module-cache-path "$ROOT/build/module-cache" \
  "$ROOT/SourcesGUI/ExternalVolumeSelection.swift" "$ROOT"/SourcesShared/*.swift \
  "$ROOT/tests/ExternalSelectionTests.swift" -o "$BUILD/ExternalSelectionTests"
"$BUILD/ExternalSelectionTests"
