#!/bin/sh
# Structured Explorer: headless renders of the explorer page (new and classic Living Tree) and measurements of both,
# from one APFS clone of an existing catalog. The source catalog is only read (cp -c); the clone and the binary live
# under /private/tmp and are removed on exit. Nothing is shown on screen.
# Usage: scripts/benchmark-structured-explorer.sh /path/to/catalog.sqlite3 [output folder]
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
SOURCE=${1:?usage: scripts/benchmark-structured-explorer.sh /path/to/catalog.sqlite3 [output folder]}
OUT=${2:-$ROOT/build/structured-explorer}
SDK_PATH=${STORAGE_MONITOR_SDK_PATH:-$(/usr/bin/xcrun --show-sdk-path)}
case "$SOURCE" in "$HOME/Library/Application Support/"*) echo "Refusing a production catalog; pass a preserved or copied catalog." >&2; exit 2 ;; esac
[ ! -e "$SOURCE-journal" ] && [ ! -e "$SOURCE-wal" ] || { echo "Source has an open journal; copy a quiescent catalog." >&2; exit 2; }
WORK=$(/usr/bin/mktemp -d /private/tmp/storage-monitor-structured-explorer.XXXXXX)
trap '/bin/rm -rf "$WORK"' EXIT INT TERM
/bin/chmod 700 "$WORK"
/bin/cp -c "$SOURCE" "$WORK/catalog.sqlite3"
/bin/cat "$WORK/catalog.sqlite3" > /dev/null
/bin/mkdir -p "$ROOT/build/module-cache" "$OUT"
/usr/bin/sed 's/^@main struct StorageMonitorViewerApp/struct StorageMonitorViewerApp/' "$ROOT/SourcesGUI/StorageMonitorApp.swift" > "$WORK/StorageMonitorApp.swift"
GUI=$(/bin/ls "$ROOT"/SourcesGUI/*.swift | /usr/bin/grep -v '/StorageMonitorApp\.swift$')
# shellcheck disable=SC2086
/usr/bin/xcrun swiftc -sdk "$SDK_PATH" -target arm64-apple-macos14.0 -swift-version 5 -O -parse-as-library -module-cache-path "$ROOT/build/module-cache" \
  -framework SwiftUI -framework Charts -framework AppKit $GUI "$WORK/StorageMonitorApp.swift" "$ROOT"/SourcesShared/*.swift "$ROOT/scripts/benchmark-structured-explorer.swift" -o "$WORK/benchmark"
"$WORK/benchmark" "$WORK/catalog.sqlite3" "$OUT"
