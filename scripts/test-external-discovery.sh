#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
BUILD=$(mktemp -d /private/tmp/storage-monitor-external-discovery.XXXXXX)
trap '/bin/rm -rf "$BUILD"' EXIT HUP INT TERM
/usr/bin/xcrun swiftc -D INVENTORY_TESTS -parse-as-library -swift-version 5 -Onone \
  -module-cache-path "$ROOT/build/module-cache" \
  -framework AppKit -framework UserNotifications \
  "$ROOT"/Sources/*.swift "$ROOT"/SourcesShared/*.swift \
  "$ROOT/tests/InventoryTests.swift" "$ROOT/tests/ExternalDiscoveryTests.swift" \
  -o "$BUILD/ExternalDiscoveryTests"
"$BUILD/ExternalDiscoveryTests"
