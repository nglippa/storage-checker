#!/bin/sh
# Inspector scroll stability, offscreen, against an APFS clone of a catalog (the source is only read).
# Usage: scripts/probe-inspector-scroll.sh /path/to/catalog.sqlite3
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
SOURCE=${1:?usage: scripts/probe-inspector-scroll.sh /path/to/catalog.sqlite3}
SDK_PATH=${STORAGE_MONITOR_SDK_PATH:-$(/usr/bin/xcrun --show-sdk-path)}
case "$SOURCE" in "$HOME/Library/Application Support/"*) echo "Refusing a production catalog; pass a copied catalog." >&2; exit 2 ;; esac
WORK=$(/usr/bin/mktemp -d /private/tmp/storage-monitor-scroll-probe.XXXXXX)
trap '/bin/rm -rf "$WORK"' EXIT INT TERM
/bin/cp -c "$SOURCE" "$WORK/catalog.sqlite3"
/bin/mkdir -p "$ROOT/build/module-cache"
/usr/bin/sed 's/^@main struct StorageMonitorViewerApp/struct StorageMonitorViewerApp/' "$ROOT/SourcesGUI/StorageMonitorApp.swift" > "$WORK/StorageMonitorApp.swift"
GUI=$(/bin/ls "$ROOT"/SourcesGUI/*.swift | /usr/bin/grep -v '/StorageMonitorApp\.swift$')
/usr/bin/xcrun swiftc -sdk "$SDK_PATH" -target arm64-apple-macos14.0 -swift-version 5 -O -parse-as-library -module-cache-path "$ROOT/build/module-cache" \
  -framework SwiftUI -framework Charts -framework AppKit $GUI "$WORK/StorageMonitorApp.swift" "$ROOT"/SourcesShared/*.swift "$ROOT/scripts/inspector-scroll-probe.swift" -o "$WORK/probe"
"$WORK/probe" "$WORK/catalog.sqlite3"
