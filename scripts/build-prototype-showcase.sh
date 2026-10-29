#!/bin/sh
# Builds the Living Tree prototype showcase (QA only): build/prototypes/Living Tree Prototypes.app, its own bundle
# identifier, ad-hoc signed. It is never installed or launched by this script. Run it on a copied catalog:
#   cp -c /path/to/preserved/catalog.sqlite3 /private/tmp/tree-showcase.sqlite3
#   open -n "build/prototypes/Living Tree Prototypes.app" --args /private/tmp/tree-showcase.sqlite3
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
SDK_PATH=${STORAGE_MONITOR_SDK_PATH:-$(/usr/bin/xcrun --show-sdk-path)}
APP="$ROOT/build/prototypes/Living Tree Prototypes.app"
WORK="$ROOT/build/prototypes/work"
BUNDLE_ID=local.macbook.storage-monitor.prototype-showcase
/bin/mkdir -p "$APP/Contents/MacOS" "$WORK" "$ROOT/build/module-cache"
/usr/bin/sed 's/^@main struct StorageMonitorViewerApp/struct StorageMonitorViewerApp/' "$ROOT/SourcesGUI/StorageMonitorApp.swift" > "$WORK/StorageMonitorApp.swift"
GUI=$(/bin/ls "$ROOT"/SourcesGUI/*.swift | /usr/bin/grep -v '/StorageMonitorApp\.swift$')
PROTO=$(/bin/ls "$ROOT"/Prototypes/LivingTree/*.swift | /usr/bin/grep -v '/PrototypeHarness\.swift$')
# shellcheck disable=SC2086
/usr/bin/xcrun swiftc -sdk "$SDK_PATH" -target arm64-apple-macos14.0 -swift-version 5 -O -parse-as-library -module-cache-path "$ROOT/build/module-cache" \
  -framework SwiftUI -framework Charts -framework AppKit $GUI "$WORK/StorageMonitorApp.swift" "$ROOT"/SourcesShared/*.swift $PROTO "$ROOT/Prototypes/Showcase/ShowcaseApp.swift" -o "$APP/Contents/MacOS/LivingTreePrototypes"
/bin/cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
<key>CFBundleName</key><string>Living Tree Prototypes</string>
<key>CFBundleExecutable</key><string>LivingTreePrototypes</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSPrincipalClass</key><string>NSApplication</string>
</dict></plist>
PLIST
/usr/bin/codesign --force --sign - --identifier "$BUNDLE_ID" "$APP"
/usr/bin/printf '%s\n' "Built $APP (not launched)"
