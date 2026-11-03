#!/bin/sh
# Headless Migration Readiness benchmark. Never launches an app, focuses a window, or writes preferences.
#   scripts/benchmark-migration-readiness.sh synthetic            builds and indexes a sparse fixture under /private/tmp
#   scripts/benchmark-migration-readiness.sh catalog <clone>      times detection on a disposable clone of a catalog
# A catalog under ~/Library/Application Support is refused: clone it first (cp -c) while no journal is present.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
MODE=${1:?usage: benchmark-migration-readiness.sh synthetic | indexing [runs] | catalog <clone.sqlite3>}
WORK=$(/usr/bin/mktemp -d /private/tmp/storage-monitor-migration-bench.XXXXXX)
/bin/chmod 700 "$WORK"
/usr/bin/printf 'work: %s\n' "$WORK"
/usr/bin/xcrun swiftc -D INVENTORY_TESTS -parse-as-library -swift-version 5 -O -module-cache-path "$WORK/module-cache" \
  -framework AppKit -framework UserNotifications "$ROOT"/Sources/*.swift "$ROOT"/SourcesShared/*.swift \
  "$ROOT/tests/InventoryTests.swift" "$ROOT/tests/SparseStorageTests.swift" "$ROOT/scripts/benchmark-migration-readiness.swift" -o "$WORK/benchmark"
case "$MODE" in
  synthetic)
    MONITOR="$ROOT/build/MacBook Storage Monitor.app/Contents/MacOS/StorageMonitor"
    [ -x "$MONITOR" ] || { echo 'Build the monitor first with scripts/build.sh.' >&2; exit 1; }
    "$WORK/benchmark" synthetic "$WORK" "$MONITOR"; /bin/rm -rf "$WORK/fixture" ;;
  indexing)
    MONITOR="$ROOT/build/MacBook Storage Monitor.app/Contents/MacOS/StorageMonitor"
    [ -x "$MONITOR" ] || { echo 'Build the monitor first with scripts/build.sh.' >&2; exit 1; }
    "$WORK/benchmark" indexing "$WORK" "$MONITOR" "${2:-20}"; /bin/rm -rf "$WORK/fixture" ;;
  catalog)
    SOURCE=${2:?pass a catalog clone}
    case "$SOURCE" in "$HOME/Library/Application Support/"*) echo 'Pass a disposable clone, never a production catalog.' >&2; exit 2 ;; esac
    [ ! -e "$SOURCE-journal" ] && [ ! -e "$SOURCE-wal" ] || { echo 'Catalog must be quiescent (journal present).' >&2; exit 2; }
    /bin/cp -c "$SOURCE" "$WORK/catalog.sqlite3"
    "$WORK/benchmark" catalog "$WORK/catalog.sqlite3"; /bin/rm -f "$WORK/catalog.sqlite3" ;;
  *) echo 'usage: benchmark-migration-readiness.sh synthetic | catalog <clone.sqlite3>' >&2; exit 2 ;;
esac
