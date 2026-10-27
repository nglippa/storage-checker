#!/bin/sh
# Cleanup Inspector measurements against an APFS clone of an existing catalog. The source catalog is only read
# (cp -c); the clone and the binary live under /private/tmp and are removed on exit. Inspections read real filesystem
# metadata (read-only; Git status for linked worktrees with repository commands disabled). Nothing is shown on screen.
# Usage: scripts/benchmark-cleanup-inspector.sh /path/to/catalog.sqlite3 [evidence folder]
# Offscreen renders of the Inspector go to build/cleanup-inspector/evidence unless another folder is named.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
SOURCE=${1:?usage: scripts/benchmark-cleanup-inspector.sh /path/to/catalog.sqlite3}
SDK_PATH=${STORAGE_MONITOR_SDK_PATH:-$(/usr/bin/xcrun --show-sdk-path)}
case "$SOURCE" in "$HOME/Library/Application Support/"*) echo "Refusing a production catalog; pass a preserved or copied catalog." >&2; exit 2 ;; esac
[ ! -e "$SOURCE-journal" ] && [ ! -e "$SOURCE-wal" ] || { echo "Source has an open journal; copy a quiescent catalog." >&2; exit 2; }
WORK=$(/usr/bin/mktemp -d /private/tmp/storage-monitor-cleanup-bench.XXXXXX)
trap '/bin/rm -rf "$WORK"' EXIT INT TERM
/bin/chmod 700 "$WORK"
/bin/cp -c "$SOURCE" "$WORK/catalog.sqlite3"
/bin/cat "$WORK/catalog.sqlite3" > /dev/null
/bin/mkdir -p "$ROOT/build/module-cache"
/usr/bin/sed 's/^@main struct StorageMonitorViewerApp/struct StorageMonitorViewerApp/' "$ROOT/SourcesGUI/StorageMonitorApp.swift" > "$WORK/StorageMonitorApp.swift"
GUI=$(/bin/ls "$ROOT"/SourcesGUI/*.swift | /usr/bin/grep -v '/StorageMonitorApp\.swift$')
/usr/bin/xcrun swiftc -sdk "$SDK_PATH" -target arm64-apple-macos14.0 -swift-version 5 -O -parse-as-library -module-cache-path "$ROOT/build/module-cache" \
  -framework SwiftUI -framework Charts -framework AppKit $GUI "$WORK/StorageMonitorApp.swift" "$ROOT"/SourcesShared/*.swift "$ROOT/scripts/cleanup-inspector-benchmark.swift" -o "$WORK/benchmark"
EVIDENCE=${2:-$ROOT/build/cleanup-inspector/evidence}
"$WORK/benchmark" "$WORK/catalog.sqlite3" "$EVIDENCE"
