#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
SDK_PATH=${STORAGE_MONITOR_SDK_PATH:-/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk}
BUILD=$(mktemp -d /private/tmp/storage-monitor-external-store.XXXXXX)
trap '/bin/rm -rf "$BUILD"' EXIT HUP INT TERM
/usr/bin/sed 's/^@main struct StorageMonitorViewerApp/struct StorageMonitorViewerApp/' "$ROOT/SourcesGUI/StorageMonitorApp.swift" > "$BUILD/StorageMonitorApp.swift"
set --
for source in "$ROOT"/SourcesGUI/*.swift; do
  case "$source" in */StorageMonitorApp.swift) ;; *) set -- "$@" "$source" ;; esac
done
/usr/bin/xcrun swiftc -sdk "$SDK_PATH" -target arm64-apple-macos14.0 -swift-version 5 -Onone -parse-as-library \
  -module-cache-path "$ROOT/build/module-cache" -framework SwiftUI -framework Charts -framework AppKit \
  "$@" "$BUILD/StorageMonitorApp.swift" "$ROOT"/SourcesShared/*.swift "$ROOT/tests/ExternalStoreTests.swift" -o "$BUILD/ExternalStoreTests"
"$BUILD/ExternalStoreTests"
