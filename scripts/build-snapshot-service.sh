#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
SDK_PATH=${STORAGE_MONITOR_SDK_PATH:-$(/usr/bin/xcrun --show-sdk-path)}
OUT=${1:-"$ROOT/build/snapshot-service"}
ARCH=${STORAGE_MONITOR_SNAPSHOT_ARCH:-arm64}
. "$ROOT/scripts/version.env"
VERSION=${STORAGE_MONITOR_VERSION:-$STORAGE_MONITOR_RELEASE_VERSION}
BUILD=${STORAGE_MONITOR_BUILD:-$STORAGE_MONITOR_RELEASE_BUILD}
case "$VERSION$BUILD" in *[!0-9.]*) echo "Version/build must be numeric." >&2; exit 1;; esac
mkdir -p "$OUT"
xcrun clang -target "$ARCH-apple-macos14.0" -isysroot "$SDK_PATH" -mmacosx-version-min=14.0 -Wall -Wextra -Werror -c "$ROOT/SourcesSnapshotService/SnapshotNative.c" -o "$OUT/SnapshotNative.o"
xcrun swiftc -sdk "$SDK_PATH" -target "$ARCH-apple-macos14.0" -swift-version 5 -O -parse-as-library -import-objc-header "$ROOT/SourcesSnapshotService/SnapshotNative.h" -framework Security "$ROOT"/SourcesShared/SnapshotLifecycle*.swift "$ROOT"/SourcesSnapshotService/*.swift "$OUT/SnapshotNative.o" -o "$OUT/StorageMonitorSnapshotService"
APP="$OUT/Storage Monitor Snapshot Service.app"
mkdir -p "$APP/Contents/MacOS"
cp "$OUT/StorageMonitorSnapshotService" "$APP/Contents/MacOS/StorageMonitorSnapshotService"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>CFBundleIdentifier</key><string>local.macbook.storage-monitor.snapshot-service</string><key>CFBundleExecutable</key><string>StorageMonitorSnapshotService</string><key>CFBundleName</key><string>Storage Monitor Snapshot Service</string><key>CFBundlePackageType</key><string>APPL</string><key>CFBundleShortVersionString</key><string>$VERSION</string><key>CFBundleVersion</key><string>$BUILD</string><key>LSMinimumSystemVersion</key><string>14.0</string><key>LSUIElement</key><true/></dict></plist>
PLIST
# Development builds deliberately have no capability entitlement/profile. Distribution packaging
# accepts only operator-supplied Apple-approved credentials; it never fabricates a provisioning grant.
codesign --force --sign - --identifier local.macbook.storage-monitor.snapshot-service "$APP"
printf '%s\n' "Built $OUT/StorageMonitorSnapshotService (ad-hoc, mutation capability disabled)"
