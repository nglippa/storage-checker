#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
/bin/mkdir -p "$ROOT/build/module-cache"
/usr/bin/xcrun swiftc -D INVENTORY_TESTS -parse-as-library -swift-version 5 -O \
  -module-cache-path "$ROOT/build/module-cache" \
  -framework AppKit -framework UserNotifications \
  "$ROOT"/Sources/*.swift "$ROOT"/SourcesShared/*.swift \
  "$ROOT/tests/InventoryTests.swift" "$ROOT/tests/InventoryExplorerTests.swift" "$ROOT/tests/InventoryIntegrationTests.swift" "$ROOT/tests/InventoryLifecycleTests.swift" "$ROOT/tests/InventoryBoundaryTests.swift" "$ROOT/tests/InventoryProgressiveTests.swift" "$ROOT/tests/InventoryCompletionTests.swift" "$ROOT/tests/InventoryReconciliationScenarios.swift" "$ROOT/tests/InventoryReconciliationTests.swift" "$ROOT/tests/InventoryChangeJournalTests.swift" "$ROOT/tests/LivingTreeCatalogTests.swift" \
  -o "$ROOT/build/InventoryIntegrationTests"
"$ROOT/build/InventoryIntegrationTests"
