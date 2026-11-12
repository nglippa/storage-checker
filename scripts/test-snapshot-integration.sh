#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
WORK=$(mktemp -d /private/tmp/storage-monitor-snapshot-integration.XXXXXX)
trap '/bin/rm -rf "$WORK"' EXIT HUP INT TERM
/usr/bin/xcrun swiftc -D INVENTORY_TESTS -parse-as-library -swift-version 5 -Onone \
  -module-cache-path "$ROOT/build/module-cache" -framework AppKit -framework UserNotifications \
  "$ROOT"/Sources/*.swift "$ROOT"/SourcesShared/*.swift "$ROOT/tests/InventoryTests.swift" \
  "$ROOT/SourcesGUI/Models.swift" "$ROOT/SourcesGUI/HistoryReader.swift" "$ROOT/SourcesGUI/DiagnosticAnalysis.swift" \
  "$ROOT/SourcesGUI/EventPanelText.swift" "$ROOT/SourcesGUI/LiveCapacity.swift" \
  "$ROOT/SourcesGUI/MonitoringSetup.swift" "$ROOT/SourcesGUI/ViewerIdentity.swift" \
  "$ROOT/tests/APFSSnapshotIntegrationTests.swift" -o "$WORK/APFSSnapshotIntegrationTests"
"$WORK/APFSSnapshotIntegrationTests" "$@"
