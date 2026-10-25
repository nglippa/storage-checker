#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
SDK_PATH=${STORAGE_MONITOR_SDK_PATH:-$(/usr/bin/xcrun --show-sdk-path)}
APP="$ROOT/build/Storage Monitor.app"
ICON="$ROOT/build/MacBook Storage Monitor.app/Contents/Resources/AppIcon.icns"
if [ ! -f "$ICON" ]; then ICON="$HOME/Applications/MacBook Storage Monitor.app/Contents/Resources/AppIcon.icns"; fi
if [ ! -f "$ICON" ]; then /usr/bin/printf '%s\n' 'Build the background monitor icon resource first with scripts/build.sh.' >&2; exit 1; fi
/bin/mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$ROOT/build/module-cache"
/bin/cp "$ICON" "$APP/Contents/Resources/AppIcon.icns"
/usr/bin/xcrun swiftc -sdk "$SDK_PATH" -target arm64-apple-macos14.0 -swift-version 5 -O -parse-as-library -module-cache-path "$ROOT/build/module-cache" -framework SwiftUI -framework Charts -framework AppKit "$ROOT"/SourcesGUI/*.swift "$ROOT"/SourcesShared/*.swift -o "$APP/Contents/MacOS/StorageMonitorViewer"
/bin/cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>local.macbook.storage-monitor.viewer</string>
<key>CFBundleName</key><string>Storage Monitor</string>
<key>CFBundleDisplayName</key><string>Storage Monitor</string>
<key>CFBundleExecutable</key><string>StorageMonitorViewer</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.0.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSPrincipalClass</key><string>NSApplication</string>
</dict></plist>
PLIST
/usr/bin/codesign --force --sign - --identifier local.macbook.storage-monitor.viewer "$APP"
/usr/bin/printf '%s\n' "Built $APP"
