#!/bin/sh
# Living Tree benchmark and offscreen renders against an APFS clone of an existing catalog. The source catalog is
# only read (cp -c); the clone and the binaries live under /private/tmp and are removed on exit. Renders are written
# to build/living-tree-1/evidence unless a second argument names another folder.
# Usage: scripts/benchmark-living-tree.sh /path/to/catalog.sqlite3 [evidence folder]
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
SOURCE=${1:?usage: scripts/benchmark-living-tree.sh /path/to/catalog.sqlite3 [evidence folder]}
EVIDENCE=${2:-$ROOT/build/living-tree-1/evidence}
SDK_PATH=${STORAGE_MONITOR_SDK_PATH:-$(/usr/bin/xcrun --show-sdk-path)}
case "$SOURCE" in "$HOME/Library/Application Support/"*) echo "Refusing a production catalog; pass a preserved or copied catalog." >&2; exit 2 ;; esac
[ ! -e "$SOURCE-journal" ] && [ ! -e "$SOURCE-wal" ] || { echo "Source has an open journal; copy a quiescent catalog." >&2; exit 2; }
WORK=$(/usr/bin/mktemp -d /private/tmp/storage-monitor-tree-bench.XXXXXX)
trap '/bin/rm -rf "$WORK"' EXIT INT TERM
/bin/chmod 700 "$WORK"
/bin/cp -c "$SOURCE" "$WORK/catalog.sqlite3"
/bin/mkdir -p "$ROOT/build/module-cache" "$EVIDENCE"
/usr/bin/xcrun swiftc -D INVENTORY_TESTS -parse-as-library -swift-version 5 -O -module-cache-path "$ROOT/build/module-cache" \
  -framework AppKit -framework UserNotifications "$ROOT"/Sources/*.swift "$ROOT"/SourcesShared/*.swift "$ROOT/tests/InventoryTests.swift" \
  "$ROOT/scripts/benchmark-living-tree.swift" -o "$WORK/benchmark"
"$WORK/benchmark" prepare "$WORK/catalog.sqlite3"
[ -n "${SKIP_MEASURE:-}" ] || "$WORK/benchmark" measure "$WORK/catalog.sqlite3"
if [ -z "${SKIP_RENDER:-}" ]; then
  # The viewer's @main entry point is removed from a scratch copy; the harness supplies its own entry point.
  /usr/bin/sed 's/^@main struct StorageMonitorViewerApp/struct StorageMonitorViewerApp/' "$ROOT/SourcesGUI/StorageMonitorApp.swift" > "$WORK/StorageMonitorApp.swift"
  GUI=$(/bin/ls "$ROOT"/SourcesGUI/*.swift | /usr/bin/grep -v '/StorageMonitorApp\.swift$')
  /usr/bin/xcrun swiftc -sdk "$SDK_PATH" -target arm64-apple-macos14.0 -swift-version 5 -O -parse-as-library -module-cache-path "$ROOT/build/module-cache" \
    -framework SwiftUI -framework Charts -framework AppKit $GUI "$WORK/StorageMonitorApp.swift" "$ROOT"/SourcesShared/*.swift "$ROOT/scripts/render-living-tree.swift" -o "$WORK/render"
  "$WORK/render" "$WORK/catalog.sqlite3" "$EVIDENCE"
fi
