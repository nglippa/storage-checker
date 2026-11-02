#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
SDK_PATH=${STORAGE_MONITOR_SDK_PATH:-/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk}
WORK=$(/usr/bin/mktemp -d /private/tmp/storage-monitor-cleanup-scroll.XXXXXX)
LOG="$WORK/test.log"

if [ ! -d "$SDK_PATH" ]; then
  /usr/bin/printf '%s\n' "Required SDK not found: $SDK_PATH" | /usr/bin/tee "$LOG"
  exit 1
fi

# Scratch-only defaults expose the real disclosures without desktop input.
/usr/bin/sed \
  -e 's/@ViewState private var showingAccounting = false/@ViewState private var showingAccounting = true/' \
  -e 's/@ViewState private var showingCleanup = false/@ViewState private var showingCleanup = true/' \
  "$ROOT/SourcesGUI/InventoryNavigatorView.swift" > "$WORK/InventoryNavigatorView.swift"
/usr/bin/sed 's/^@main struct StorageMonitorViewerApp/struct StorageMonitorViewerApp/' \
  "$ROOT/SourcesGUI/StorageMonitorApp.swift" > "$WORK/StorageMonitorApp.swift"

set --
for source in "$ROOT"/SourcesGUI/*.swift; do
  case "$source" in
    */InventoryNavigatorView.swift|*/StorageMonitorApp.swift) ;;
    *) set -- "$@" "$source" ;;
  esac
done

/bin/mkdir -p "$ROOT/build/module-cache"
/usr/bin/printf '%s\n' "work: $WORK" > "$LOG"
set +e
/usr/bin/xcrun swiftc \
  -sdk "$SDK_PATH" \
  -target arm64-apple-macos14.0 \
  -swift-version 5 \
  -Onone \
  -parse-as-library \
  -module-cache-path "$ROOT/build/module-cache" \
  -framework SwiftUI \
  -framework Charts \
  -framework AppKit \
  "$@" \
  "$WORK/InventoryNavigatorView.swift" \
  "$WORK/StorageMonitorApp.swift" \
  "$ROOT"/SourcesShared/*.swift \
  "$ROOT/scripts/cleanup-inspector-scroll-tests.swift" \
  -o "$WORK/cleanup-inspector-scroll-tests" >> "$LOG" 2>&1
COMPILE_STATUS=$?
set -e
if [ "$COMPILE_STATUS" -ne 0 ]; then
  /usr/bin/printf 'compile exit: %s\nlog: %s\n' "$COMPILE_STATUS" "$LOG" >> "$LOG"
  /bin/cat "$LOG"
  exit "$COMPILE_STATUS"
fi

set +e
"$WORK/cleanup-inspector-scroll-tests" "$WORK/fixture" >> "$LOG" 2>&1
STATUS=$?
set -e
/usr/bin/printf 'exit: %s\nlog: %s\n' "$STATUS" "$LOG" >> "$LOG"
/bin/cat "$LOG"
exit "$STATUS"
