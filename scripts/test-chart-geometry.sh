#!/bin/sh
# Hosted-view regressions: the Monitoring chart hover geometry (tests/CapacityChartGeometryTests.swift) and Living Tree
# AppKit scroll routing (tests/LivingTreeScrollRoutingTests.swift). Hosts the real chart offscreen in a
# process that cannot activate, so it never takes focus. The app's @main entry is stripped from a build-local copy so the
# test can provide its own.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
SDK_PATH=${STORAGE_MONITOR_SDK_PATH:-$(/usr/bin/xcrun --show-sdk-path)}
WORK="$ROOT/build/chart-geometry"
/bin/mkdir -p "$WORK" "$ROOT/build/module-cache"
/usr/bin/sed 's/^@main struct StorageMonitorViewerApp/struct StorageMonitorViewerApp/' "$ROOT/SourcesGUI/StorageMonitorApp.swift" > "$WORK/StorageMonitorApp.swift"
SOURCES=$(/usr/bin/find "$ROOT/SourcesGUI" -name '*.swift' ! -name StorageMonitorApp.swift)
# shellcheck disable=SC2086
/usr/bin/xcrun swiftc -sdk "$SDK_PATH" -target arm64-apple-macos14.0 -swift-version 5 -O -parse-as-library -module-cache-path "$ROOT/build/module-cache" -framework SwiftUI -framework Charts -framework AppKit $SOURCES "$WORK/StorageMonitorApp.swift" "$ROOT"/SourcesShared/*.swift "$ROOT/tests/CapacityChartGeometryTests.swift" "$ROOT/tests/LivingTreeScrollRoutingTests.swift" -o "$WORK/CapacityChartGeometryTests"
"$WORK/CapacityChartGeometryTests"
