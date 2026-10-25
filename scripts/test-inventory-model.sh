#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
SDK_PATH=${STORAGE_MONITOR_SDK_PATH:-$(/usr/bin/xcrun --show-sdk-path)}
MONITOR="$ROOT/build/MacBook Storage Monitor.app/Contents/MacOS/StorageMonitor"
if [ ! -x "$MONITOR" ]; then /usr/bin/printf '%s\n' 'Build the monitor first with scripts/build.sh.' >&2; exit 1; fi
WORK="$ROOT/build/inventory-model-tests"
/bin/rm -rf "$WORK"; /bin/mkdir -p "$WORK" "$ROOT/build/module-cache"
# The viewer's @main entry point is removed from a scratch copy; the test supplies its own entry point.
/usr/bin/sed 's/^@main struct StorageMonitorViewerApp/struct StorageMonitorViewerApp/' "$ROOT/SourcesGUI/StorageMonitorApp.swift" > "$WORK/StorageMonitorApp.swift"
GUI=$(/bin/ls "$ROOT"/SourcesGUI/*.swift | /usr/bin/grep -v '/StorageMonitorApp\.swift$')
/usr/bin/xcrun swiftc -sdk "$SDK_PATH" -target arm64-apple-macos14.0 -swift-version 5 -O -parse-as-library -module-cache-path "$ROOT/build/module-cache" -framework SwiftUI -framework Charts -framework AppKit \
  $GUI "$WORK/StorageMonitorApp.swift" "$ROOT"/SourcesShared/*.swift "$ROOT/tests/InventoryModelTests.swift" -o "$ROOT/build/InventoryModelTests"
"$ROOT/build/InventoryModelTests" "$MONITOR" "$WORK/scratch"
