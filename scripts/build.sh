#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
APP="$ROOT/build/MacBook Storage Monitor.app"
/bin/mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$ROOT/build/module-cache" "$ROOT/build/AppIcon.iconset"
# Keep the supplied artwork intact; macOS icon representations are proportional resizes.
/usr/bin/xcrun swift -module-cache-path "$ROOT/build/module-cache" "$ROOT/scripts/prepare-icon.swift" "$ROOT/Assets/AppIcon.png" "$ROOT/build/AppIcon-RGBA.png"
while read -r pixels name; do
  /usr/bin/sips -z "$pixels" "$pixels" "$ROOT/build/AppIcon-RGBA.png" --out "$ROOT/build/AppIcon.iconset/$name.png" >/dev/null
done <<'ICONS'
16 icon_16x16
32 icon_16x16@2x
32 icon_32x32
64 icon_32x32@2x
128 icon_128x128
256 icon_128x128@2x
256 icon_256x256
512 icon_256x256@2x
512 icon_512x512
1024 icon_512x512@2x
ICONS
if ! /usr/bin/iconutil -c icns "$ROOT/build/AppIcon.iconset" -o "$APP/Contents/Resources/AppIcon.icns" 2>"$ROOT/build/iconutil.log"; then
  /usr/bin/xcrun swift -module-cache-path "$ROOT/build/module-cache" "$ROOT/scripts/pack-icon.swift" "$ROOT/build/AppIcon.iconset" "$APP/Contents/Resources/AppIcon.icns"
fi
/usr/bin/xcrun swiftc -swift-version 5 -O -module-cache-path "$ROOT/build/module-cache" -framework AppKit -framework UserNotifications -parse-as-library "$ROOT/Sources/StorageMonitor.swift" "$ROOT/Sources/Diagnostics.swift" "$ROOT/Sources/Attribution.swift" "$ROOT/Sources/Coverage.swift" "$ROOT/Sources/CoverageSelfTest.swift" -o "$APP/Contents/MacOS/StorageMonitor"
/bin/cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>local.macbook.storage-monitor</string>
<key>CFBundleName</key><string>MacBook Storage Monitor</string>
<key>CFBundleDisplayName</key><string>MacBook Storage Monitor</string>
<key>CFBundleExecutable</key><string>StorageMonitor</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.0.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
/usr/bin/codesign --force --sign - --identifier local.macbook.storage-monitor "$APP"
/usr/bin/printf '%s\n' "Built $APP"
