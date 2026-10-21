#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
/bin/mkdir -p "$ROOT/build/module-cache"
/usr/bin/xcrun swiftc -swift-version 5 -O -parse-as-library -module-cache-path "$ROOT/build/module-cache" "$ROOT/SourcesGUI/Models.swift" "$ROOT/SourcesGUI/HistoryReader.swift" "$ROOT/SourcesGUI/DiagnosticAnalysis.swift" "$ROOT/SourcesGUI/EventPanelText.swift" "$ROOT/SourcesGUI/LiveCapacity.swift" "$ROOT/tests/GUIModelTests.swift" -o "$ROOT/build/GUIModelTests"
"$ROOT/build/GUIModelTests" "${1:-$ROOT/build/qa-fixtures}" "$ROOT/tests/fixtures"
VIEWER="$ROOT/build/Storage Monitor.app/Contents/MacOS/StorageMonitorViewer"
if [ -x "$VIEWER" ]; then
  if /usr/bin/otool -L "$VIEWER" | /usr/bin/grep -q UserNotifications; then echo "FAIL viewer links UserNotifications"; exit 1; fi
  echo "PASS viewer binary does not link UserNotifications (cannot send notifications)"
  if /usr/bin/grep -nE 'Process\(|NSTask|INSERT|UPDATE |DELETE ' "$ROOT/SourcesGUI/LiveCapacity.swift"; then echo "FAIL live capacity code launches processes or writes SQL"; exit 1; fi
  echo "PASS live capacity code launches no process and writes no SQL"
fi
