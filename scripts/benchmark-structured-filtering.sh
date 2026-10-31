#!/bin/sh
# Headless only: clones a quiescent catalog; never launches an app, orders a window, or writes preferences.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
SOURCE=${1:?usage: benchmark-structured-filtering.sh catalog.sqlite3 output-folder}
OUT=${2:?usage: benchmark-structured-filtering.sh catalog.sqlite3 output-folder}
SDK_PATH=${STORAGE_MONITOR_SDK_PATH:-/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk}
case "$SOURCE" in "$HOME/Library/Application Support/"*) echo 'Pass a disposable or preserved catalog, never production.' >&2; exit 2 ;; esac
[ ! -e "$SOURCE-wal" ] && [ ! -e "$SOURCE-journal" ] || { echo 'Source catalog must be quiescent.' >&2; exit 2; }
WORK=$(/usr/bin/mktemp -d /private/tmp/storage-monitor-filter-bench.XXXXXX)
/bin/chmod 700 "$WORK"
/bin/cp -c "$SOURCE" "$WORK/catalog.sqlite3"
/bin/mkdir -p "$OUT" "$WORK/module-cache"
/usr/bin/sed 's/^@main struct StorageMonitorViewerApp/struct StorageMonitorViewerApp/' "$ROOT/SourcesGUI/StorageMonitorApp.swift" > "$WORK/StorageMonitorApp.swift"
set --
for source in "$ROOT"/SourcesGUI/*.swift; do
  case "$source" in */StorageMonitorApp.swift) ;; *) set -- "$@" "$source" ;; esac
done
/usr/bin/printf 'work: %s\n' "$WORK"
/usr/bin/xcrun swiftc -sdk "$SDK_PATH" -target arm64-apple-macos14.0 -swift-version 5 -O -parse-as-library \
  -module-cache-path "$WORK/module-cache" -framework SwiftUI -framework Charts -framework AppKit \
  "$@" "$WORK/StorageMonitorApp.swift" "$ROOT"/SourcesShared/*.swift "$ROOT/scripts/benchmark-structured-filtering.swift" -o "$WORK/benchmark"
"$WORK/benchmark" "$WORK/catalog.sqlite3" "$OUT"
