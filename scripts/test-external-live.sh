#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
BUILD=$(mktemp -d /private/tmp/storage-monitor-external-live.XXXXXX)
trap '/bin/rm -rf "$BUILD"' EXIT HUP INT TERM
/usr/bin/xcrun swiftc -parse-as-library -swift-version 5 -Onone -module-cache-path "$ROOT/build/module-cache" \
  "$ROOT/SourcesGUI/Models.swift" "$ROOT/SourcesGUI/LiveCapacity.swift" "$ROOT/SourcesGUI/DiagnosticAnalysis.swift" "$ROOT/SourcesGUI/EventPanelText.swift" "$ROOT"/SourcesShared/*.swift \
  "$ROOT/tests/ExternalLiveTests.swift" -o "$BUILD/ExternalLiveTests"
"$BUILD/ExternalLiveTests"
