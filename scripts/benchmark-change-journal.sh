#!/bin/sh
# Change-journal benchmark against APFS clones of an existing catalog. The source catalog is only read
# (cp -c); both clones, the synthetic tree and the binary live under /private/tmp and are removed on exit.
# Usage: scripts/benchmark-change-journal.sh /path/to/catalog.sqlite3
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
SOURCE=${1:?usage: scripts/benchmark-change-journal.sh /path/to/catalog.sqlite3}
case "$SOURCE" in "$HOME/Library/Application Support/"*) echo "Refusing a production catalog; pass a preserved or copied catalog." >&2; exit 2 ;; esac
[ ! -e "$SOURCE-journal" ] && [ ! -e "$SOURCE-wal" ] || { echo "Source has an open journal; copy a quiescent catalog." >&2; exit 2; }
WORK=$(/usr/bin/mktemp -d /private/tmp/storage-monitor-journal-bench.XXXXXX)
trap '/bin/rm -rf "$WORK"' EXIT INT TERM
/bin/chmod 700 "$WORK"
/bin/cp -c "$SOURCE" "$WORK/with-journal.sqlite3"
/bin/cp -c "$SOURCE" "$WORK/without-journal.sqlite3"
/bin/mkdir -p "$ROOT/build/module-cache" "$WORK/scratch"
/usr/bin/xcrun swiftc -D INVENTORY_TESTS -parse-as-library -swift-version 5 -O -module-cache-path "$ROOT/build/module-cache" \
  -framework AppKit -framework UserNotifications "$ROOT"/Sources/*.swift "$ROOT"/SourcesShared/*.swift "$ROOT/tests/InventoryTests.swift" \
  "$ROOT/scripts/benchmark-change-journal.swift" -o "$WORK/benchmark"
"$WORK/benchmark" "$WORK/scratch" "$WORK/with-journal.sqlite3" "$WORK/without-journal.sqlite3"
for name in with-journal without-journal; do
  /usr/bin/printf 'database %s bytes=%s\n' "$name" "$(/usr/bin/stat -f %z "$WORK/$name.sqlite3")"
done
/usr/bin/sqlite3 "$WORK/with-journal.sqlite3" "SELECT 'journal table '||name||' pages='||COUNT(*)||' bytes='||SUM(pgsize) FROM dbstat WHERE name IN ('inventory_change_clock','inventory_changed_directories','inventory_changed_directories_sequence','inventory_size_signals','inventory_size_signals_sequence') GROUP BY name;"
