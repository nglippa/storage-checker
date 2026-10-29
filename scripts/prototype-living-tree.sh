#!/bin/sh
# Living Tree prototypes (Prototypes/LivingTree): screenshots of the current tree and both prototypes, a comparison
# board and measurements, all from one APFS clone of an existing catalog. The source catalog is only read (cp -c); the
# clone and the binary live under /private/tmp and are removed on exit. Nothing is shown on screen.
# Usage: scripts/prototype-living-tree.sh /path/to/catalog.sqlite3 [output folder]
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
SOURCE=${1:?usage: scripts/prototype-living-tree.sh /path/to/catalog.sqlite3 [output folder]}
OUT=${2:-$ROOT/build/living-tree-prototypes}
SDK_PATH=${STORAGE_MONITOR_SDK_PATH:-$(/usr/bin/xcrun --show-sdk-path)}
case "$SOURCE" in "$HOME/Library/Application Support/"*) echo "Refusing a production catalog; pass a preserved or copied catalog." >&2; exit 2 ;; esac
[ ! -e "$SOURCE-journal" ] && [ ! -e "$SOURCE-wal" ] || { echo "Source has an open journal; copy a quiescent catalog." >&2; exit 2; }
WORK=$(/usr/bin/mktemp -d /private/tmp/storage-monitor-tree-prototypes.XXXXXX)
trap '/bin/rm -rf "$WORK"' EXIT INT TERM
/bin/chmod 700 "$WORK"
/bin/cp -c "$SOURCE" "$WORK/catalog.sqlite3"
/bin/cat "$WORK/catalog.sqlite3" > /dev/null
/bin/mkdir -p "$ROOT/build/module-cache" "$OUT"
# The viewer's @main entry point is removed from a scratch copy; the harness supplies its own entry point.
/usr/bin/sed 's/^@main struct StorageMonitorViewerApp/struct StorageMonitorViewerApp/' "$ROOT/SourcesGUI/StorageMonitorApp.swift" > "$WORK/StorageMonitorApp.swift"
GUI=$(/bin/ls "$ROOT"/SourcesGUI/*.swift | /usr/bin/grep -v '/StorageMonitorApp\.swift$')
# shellcheck disable=SC2086
/usr/bin/xcrun swiftc -sdk "$SDK_PATH" -target arm64-apple-macos14.0 -swift-version 5 -O -parse-as-library -module-cache-path "$ROOT/build/module-cache" \
  -framework SwiftUI -framework Charts -framework AppKit $GUI "$WORK/StorageMonitorApp.swift" "$ROOT"/SourcesShared/*.swift "$ROOT"/Prototypes/LivingTree/*.swift -o "$WORK/prototypes"
"$WORK/prototypes" "$WORK/catalog.sqlite3" "$OUT"
