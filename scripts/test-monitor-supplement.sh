#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
/bin/mkdir -p "$ROOT/build/module-cache"
/usr/bin/xcrun swiftc -D INVENTORY_TESTS -parse-as-library -swift-version 5 -O \
  -module-cache-path "$ROOT/build/module-cache" -framework AppKit -framework UserNotifications \
  "$ROOT"/Sources/*.swift "$ROOT"/SourcesShared/*.swift \
  "$ROOT/tests/InventoryTests.swift" "$ROOT/tests/MonitorSupplement.swift" \
  -o "$ROOT/build/MonitorSupplement"
"$ROOT/build/MonitorSupplement" "$@"
