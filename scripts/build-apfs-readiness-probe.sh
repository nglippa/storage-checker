#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
OUT=${1:?Provide an absolute executable path under /private/tmp/storage-apfs-acceptance-*}
case "$OUT" in /private/tmp/storage-apfs-acceptance-*/*) ;; *) exit 64 ;; esac
/usr/bin/xcrun swiftc -D INVENTORY_TESTS -parse-as-library -swift-version 5 -Onone \
  -module-cache-path "$ROOT/build/module-cache" -framework AppKit -framework UserNotifications \
  "$ROOT"/Sources/*.swift "$ROOT"/SourcesShared/*.swift "$ROOT/tests/InventoryTests.swift" \
  "$ROOT/SourcesGUI/Models.swift" "$ROOT/SourcesGUI/HistoryReader.swift" "$ROOT/SourcesGUI/DiagnosticAnalysis.swift" \
  "$ROOT/SourcesGUI/EventPanelText.swift" "$ROOT/SourcesGUI/LiveCapacity.swift" \
  "$ROOT/SourcesGUI/MonitoringSetup.swift" "$ROOT/SourcesGUI/ViewerIdentity.swift" \
  "$ROOT/artifacts/apfs-snapshot-acceptance/ReadinessProbe.swift" -o "$OUT"
