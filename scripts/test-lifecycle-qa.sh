#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
/bin/mkdir -p "$ROOT/build/module-cache"
/usr/bin/xcrun swiftc -D INVENTORY_TESTS -parse-as-library -swift-version 5 -O \
  -module-cache-path "$ROOT/build/module-cache" -framework AppKit -framework UserNotifications \
  "$ROOT"/Sources/*.swift "$ROOT"/SourcesShared/*.swift "$ROOT/tests/InventoryTests.swift" \
  "$ROOT/SourcesGUI/MonitoringSetup.swift" "$ROOT/tests/LifecycleQATests.swift" -o "$ROOT/build/LifecycleQATests"
"$ROOT/build/LifecycleQATests"
