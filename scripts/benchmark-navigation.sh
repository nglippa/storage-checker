#!/bin/sh
# Structured Explorer end-to-end navigation benchmark (scripts/benchmark-navigation.swift): navigation request to
# interaction readiness, with the clone's pending reconciliation kept and a 2 s inventory refresh, from one APFS clone of
# an existing catalog. The source catalog is only read (cp -c); the clone and the binary live under /private/tmp and are
# removed on exit. Nothing is shown on screen and no preference is written.
# Usage: scripts/benchmark-navigation.sh /path/to/catalog.sqlite3 output.json [label]
# LIVING_TREE_VIEW=/path/to/LivingTreeView.swift compiles that controller instead (before/after comparisons).
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
SOURCE=${1:?usage: scripts/benchmark-navigation.sh /path/to/catalog.sqlite3 output.json [label]}
OUTPUT=${2:?usage: scripts/benchmark-navigation.sh /path/to/catalog.sqlite3 output.json [label]}
LABEL=${3:-current}
SDK_PATH=${STORAGE_MONITOR_SDK_PATH:-$(/usr/bin/xcrun --show-sdk-path)}
case "$SOURCE" in "$HOME/Library/Application Support/"*) echo "Refusing a production catalog; pass a preserved or copied catalog." >&2; exit 2 ;; esac
[ ! -e "$SOURCE-journal" ] && [ ! -e "$SOURCE-wal" ] || { echo "Source has an open journal; copy a quiescent catalog." >&2; exit 2; }
WORK=$(/usr/bin/mktemp -d /private/tmp/storage-monitor-navigation.XXXXXX)
trap '/bin/rm -rf "$WORK"' EXIT INT TERM
/bin/chmod 700 "$WORK"
/bin/cp -c "$SOURCE" "$WORK/catalog.sqlite3"
/bin/cat "$WORK/catalog.sqlite3" > /dev/null
/bin/mkdir -p "$ROOT/build/module-cache"
/usr/bin/sed 's/^@main struct StorageMonitorViewerApp/struct StorageMonitorViewerApp/' "$ROOT/SourcesGUI/StorageMonitorApp.swift" > "$WORK/StorageMonitorApp.swift"
GUI=$(/bin/ls "$ROOT"/SourcesGUI/*.swift | /usr/bin/grep -v '/StorageMonitorApp\.swift$')
if [ -n "${LIVING_TREE_VIEW:-}" ]; then
  /bin/cp "$LIVING_TREE_VIEW" "$WORK/LivingTreeView.swift"
  GUI=$(/usr/bin/printf '%s\n' "$GUI" | /usr/bin/grep -v '/LivingTreeView\.swift$'; /usr/bin/printf '%s\n' "$WORK/LivingTreeView.swift")
fi
# shellcheck disable=SC2086
/usr/bin/xcrun swiftc -sdk "$SDK_PATH" -target arm64-apple-macos14.0 -swift-version 5 -O -parse-as-library -module-cache-path "$ROOT/build/module-cache" \
  -framework SwiftUI -framework Charts -framework AppKit $GUI "$WORK/StorageMonitorApp.swift" "$ROOT"/SourcesShared/*.swift "$ROOT/scripts/benchmark-navigation.swift" -o "$WORK/benchmark"
"$WORK/benchmark" "$WORK/catalog.sqlite3" "$OUTPUT" "$LABEL"
