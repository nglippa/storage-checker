#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
SDK_PATH=${STORAGE_MONITOR_SDK_PATH:-$(/usr/bin/xcrun --show-sdk-path)}
. "$ROOT/scripts/version.env"
VERSION=${STORAGE_MONITOR_VERSION:-$STORAGE_MONITOR_RELEASE_VERSION}
BUILD=${STORAGE_MONITOR_BUILD:-$STORAGE_MONITOR_RELEASE_BUILD}
# A development build, never the installed app: its own identifier keeps its preferences, saved window state and
# caches apart from the production app (local.macbook.storage-monitor.viewer, built only by scripts/build-dmg.sh).
APP="$ROOT/build/Storage Monitor.app"
BUNDLE_ID=local.macbook.storage-monitor.viewer.dev
NAME="Storage Monitor Dev"
QA=false
if [ "${1:-}" = "--qa-runtime" ] && [ "$#" -eq 1 ]; then
  QA=true
  APP="$ROOT/build/native-acceptance/runtime/Storage Monitor QA.app"
  BUNDLE_ID=local.macbook.storage-monitor.viewer.native-qa
elif [ "$#" -ne 0 ]; then
  /usr/bin/printf '%s\n' 'Usage: scripts/build-gui.sh [--qa-runtime]' >&2; exit 1
fi
ICON="$ROOT/build/MacBook Storage Monitor.app/Contents/Resources/AppIcon.icns"
if [ ! -f "$ICON" ]; then ICON="$HOME/Applications/MacBook Storage Monitor.app/Contents/Resources/AppIcon.icns"; fi
if [ ! -f "$ICON" ]; then /usr/bin/printf '%s\n' 'Build the background monitor icon resource first with scripts/build.sh.' >&2; exit 1; fi
/bin/mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$ROOT/build/module-cache"
/bin/cp "$ICON" "$APP/Contents/Resources/AppIcon.icns"
/bin/cp "$ROOT/THIRD-PARTY-NOTICES.md" "$APP/Contents/Resources/THIRD-PARTY-NOTICES.md"
/usr/bin/xcrun swiftc -sdk "$SDK_PATH" -target arm64-apple-macos14.0 -swift-version 5 -O -parse-as-library -module-cache-path "$ROOT/build/module-cache" -framework SwiftUI -framework Charts -framework AppKit "$ROOT"/SourcesGUI/*.swift "$ROOT"/SourcesShared/*.swift -o "$APP/Contents/MacOS/StorageMonitorViewer"
/bin/cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
<key>CFBundleName</key><string>$NAME</string>
<key>CFBundleDisplayName</key><string>$NAME</string>
<key>CFBundleExecutable</key><string>StorageMonitorViewer</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>$VERSION</string>
<key>CFBundleVersion</key><string>$BUILD</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSPrincipalClass</key><string>NSApplication</string>
</dict></plist>
PLIST
if [ "$QA" = true ]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleName Storage Monitor QA" "$APP/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName Storage Monitor QA" "$APP/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c 'Add :StorageMonitorQAInventory bool true' "$APP/Contents/Info.plist"
fi
if [ "${STORAGE_MONITOR_BUNDLE_HELPER:-1}" = 1 ]; then
  HELPER="$ROOT/build/MacBook Storage Monitor.app"
  if [ ! -x "$HELPER/Contents/MacOS/StorageMonitor" ]; then /usr/bin/printf '%s\n' 'Build the matching monitor first with scripts/build.sh.' >&2; exit 1; fi
  /bin/mkdir -p "$APP/Contents/Helpers"
  /usr/bin/ditto "$HELPER" "$APP/Contents/Helpers/MacBook Storage Monitor.app"
  /usr/bin/codesign --verify --deep --strict "$APP/Contents/Helpers/MacBook Storage Monitor.app"
fi
STORAGE_MONITOR_SDK_PATH="$SDK_PATH" "$ROOT/scripts/build-snapshot-service.sh" "$ROOT/build/snapshot-service"
/bin/mkdir -p "$APP/Contents/Library/HelperTools" "$APP/Contents/Library/LaunchDaemons"
/usr/bin/ditto "$ROOT/build/snapshot-service/Storage Monitor Snapshot Service.app" "$APP/Contents/Library/HelperTools/Storage Monitor Snapshot Service.app"
/bin/cat > "$APP/Contents/Library/LaunchDaemons/local.macbook.storage-monitor.snapshots.plist" <<'SNAPSHOT_PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>local.macbook.storage-monitor.snapshots</string>
<key>BundleProgram</key><string>Contents/Library/HelperTools/Storage Monitor Snapshot Service.app/Contents/MacOS/StorageMonitorSnapshotService</string>
<key>MachServices</key><dict><key>local.macbook.storage-monitor.snapshots</key><true/></dict>
<key>RunAtLoad</key><true/><key>KeepAlive</key><dict><key>Crashed</key><true/></dict>
<key>ThrottleInterval</key><integer>60</integer>
<key>ProcessType</key><string>Background</string>
</dict></plist>
SNAPSHOT_PLIST
/usr/bin/codesign --force --sign - --identifier "$BUNDLE_ID" "$APP"
/usr/bin/codesign --verify --deep --strict "$APP"
/usr/bin/printf '%s\n' "Built $APP"
