#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
SDK_PATH=${STORAGE_MONITOR_SDK_PATH:-$(/usr/bin/xcrun --show-sdk-path)}
MONITOR="$ROOT/build/MacBook Storage Monitor.app/Contents/MacOS/StorageMonitor"
if [ ! -x "$MONITOR" ]; then /usr/bin/printf '%s\n' 'Build the monitor first with scripts/build.sh.' >&2; exit 1; fi
/bin/mkdir -p "$ROOT/build/module-cache"
WORK=$(/usr/bin/mktemp -d /private/tmp/storage-monitor-inventory-model-tests.XXXXXX)
# The viewer's @main entry point is removed from a scratch copy; the test supplies its own entry point.
/usr/bin/sed 's/^@main struct StorageMonitorViewerApp/struct StorageMonitorViewerApp/' "$ROOT/SourcesGUI/StorageMonitorApp.swift" > "$WORK/StorageMonitorApp.swift"
set --
for source in "$ROOT"/SourcesGUI/*.swift; do
  case "$source" in */StorageMonitorApp.swift) ;; *) set -- "$@" "$source" ;; esac
done
/usr/bin/xcrun swiftc -sdk "$SDK_PATH" -target arm64-apple-macos14.0 -swift-version 5 -O -parse-as-library -module-cache-path "$ROOT/build/module-cache" -framework SwiftUI -framework Charts -framework AppKit \
  "$@" "$WORK/StorageMonitorApp.swift" "$ROOT"/SourcesShared/*.swift "$ROOT/tests/InventoryModelTests.swift" "$ROOT/tests/SparseStorageTests.swift" -o "$ROOT/build/InventoryModelTests"
"$ROOT/build/InventoryModelTests" "$MONITOR" "$WORK/scratch"
