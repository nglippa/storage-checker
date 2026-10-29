#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
/bin/mkdir -p "$ROOT/build/module-cache"
/usr/bin/xcrun swiftc -swift-version 5 -O -parse-as-library -module-cache-path "$ROOT/build/module-cache" "$ROOT/SourcesGUI/Models.swift" "$ROOT/SourcesGUI/HistoryReader.swift" "$ROOT/SourcesGUI/DiagnosticAnalysis.swift" "$ROOT/SourcesGUI/EventPanelText.swift" "$ROOT/SourcesGUI/LiveCapacity.swift" "$ROOT/SourcesGUI/MonitoringSetup.swift" "$ROOT/SourcesGUI/ViewerIdentity.swift" "$ROOT"/SourcesShared/*.swift "$ROOT/tests/GUIModelTests.swift" "$ROOT/tests/LivingTreeTests.swift" "$ROOT/tests/CleanupInspectorTests.swift" "$ROOT/tests/CleanupTrashSafetyTests.swift" "$ROOT/tests/CleanupReviewQueueTests.swift" "$ROOT/tests/ViewerIdentityTests.swift" -o "$ROOT/build/GUIModelTests"
# Fixtures default to a fresh folder under /private/tmp: the /tmp ↔ /private/tmp alias tests run only there.
"$ROOT/build/GUIModelTests" "${1:-$(/usr/bin/mktemp -d /private/tmp/storage-monitor-viewer-fixtures.XXXXXX)}" "$ROOT/tests/fixtures"
VIEWER="$ROOT/build/Storage Monitor.app/Contents/MacOS/StorageMonitorViewer"
if [ -x "$VIEWER" ]; then
  if /usr/bin/otool -L "$VIEWER" | /usr/bin/grep -q UserNotifications; then echo "FAIL viewer links UserNotifications"; exit 1; fi
  echo "PASS viewer binary does not link UserNotifications (cannot send notifications)"
  if /usr/bin/grep -nE 'Process\(|NSTask|INSERT|UPDATE |DELETE ' "$ROOT/SourcesGUI/LiveCapacity.swift"; then echo "FAIL live capacity code launches processes or writes SQL"; exit 1; fi
  echo "PASS live capacity code launches no process and writes no SQL"
fi
