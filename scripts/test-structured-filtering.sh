#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
SDK_PATH=${STORAGE_MONITOR_SDK_PATH:-$(/usr/bin/xcrun --show-sdk-path)}
WORK=$(/usr/bin/mktemp -d /private/tmp/storage-monitor-structured-filtering.XXXXXX)
LOG="$WORK/test.log"
/usr/bin/printf 'work: %s\n' "$WORK" > "$LOG"
set +e
/usr/bin/xcrun swiftc -sdk "$SDK_PATH" -target arm64-apple-macos14.0 -swift-version 5 -O -parse-as-library \
  -D STRUCTURED_FILTER_TEST_MAIN -module-cache-path "$WORK/module-cache" \
  "$ROOT"/SourcesShared/*.swift "$ROOT/tests/StructuredExplorerFilteringTests.swift" -o "$WORK/structured-filtering-tests" >> "$LOG" 2>&1
COMPILE_STATUS=$?
set -e
if [ "$COMPILE_STATUS" -ne 0 ]; then /bin/cat "$LOG"; /usr/bin/printf 'compile exit: %s\nlog: %s\n' "$COMPILE_STATUS" "$LOG"; exit "$COMPILE_STATUS"; fi
set +e
"$WORK/structured-filtering-tests" >> "$LOG" 2>&1
STATUS=$?
set -e
/usr/bin/printf 'exit: %s\nlog: %s\n' "$STATUS" "$LOG" >> "$LOG"
/bin/cat "$LOG"
exit "$STATUS"
