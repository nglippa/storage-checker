#!/bin/sh
# Builds a self-contained, universal Storage Monitor.app (with its background monitor bundled
# as a helper) and packages it in a drag-to-Applications disk image. See PACKAGING.md.
#
# Environment (all optional):
#   STORAGE_MONITOR_VERSION        marketing version            (default: scripts/version.env)
#   STORAGE_MONITOR_BUILD          build number                 (default: scripts/version.env)
#   STORAGE_MONITOR_APP_ONLY=1     stop after building and verifying build/dist/work/Storage Monitor.app (no image)
#   STORAGE_MONITOR_SIGN_IDENTITY  codesign identity; "-" = ad-hoc (default). A Developer ID
#                                  identity adds the hardened runtime and a secure timestamp.
#   STORAGE_MONITOR_SDK_PATH       macOS SDK for the SwiftUI app (default: 26.5 Command Line
#                                  Tools SDK when present, else xcrun's default)
#   STORAGE_MONITOR_ARCHS          architectures                (default "arm64 x86_64")
#   SOURCE_DATE_EPOCH              file timestamps inside the image (default: last commit time)
#   STORAGE_MONITOR_SKIP_VERIFY=1  skip scripts/verify-dmg.sh
#   STORAGE_MONITOR_DMG_NAME       image file name              (default Storage-Monitor-<version>.dmg)
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
. "$ROOT/scripts/version.env"
VERSION=${STORAGE_MONITOR_VERSION:-$STORAGE_MONITOR_RELEASE_VERSION}
BUILD=${STORAGE_MONITOR_BUILD:-$STORAGE_MONITOR_RELEASE_BUILD}
IDENTITY=${STORAGE_MONITOR_SIGN_IDENTITY:--}
ARCHS=${STORAGE_MONITOR_ARCHS:-arm64 x86_64}
MIN_MACOS=14.0
if [ -n "${STORAGE_MONITOR_SDK_PATH:-}" ]; then SDK=$STORAGE_MONITOR_SDK_PATH
elif [ -d /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk ]; then SDK=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk
else SDK=$(/usr/bin/xcrun --show-sdk-path); fi
EPOCH=${SOURCE_DATE_EPOCH:-$(/usr/bin/git -C "$ROOT" log -1 --format=%ct 2>/dev/null || echo 1700000000)}
case "$VERSION$BUILD" in *[!0-9.]*) echo "Version and build must be numeric (for example 1.2.0 and 7)." >&2; exit 1;; esac
[ -f "$ROOT/Assets/AppIcon.png" ] || { echo "Missing approved artwork: Assets/AppIcon.png" >&2; exit 1; }

DIST="$ROOT/build/dist"
WORK="$DIST/work"
APP="$WORK/Storage Monitor.app"
HELPER="$APP/Contents/Helpers/MacBook Storage Monitor.app"
DMG="$DIST/${STORAGE_MONITOR_DMG_NAME:-Storage-Monitor-$VERSION.dmg}"
case "$DMG" in *.dmg) ;; *) echo "STORAGE_MONITOR_DMG_NAME must end in .dmg" >&2; exit 1;; esac
/bin/rm -rf "$WORK"
/bin/mkdir -p "$WORK/bin" "$WORK/iconset.iconset" "$APP/Contents/MacOS" "$APP/Contents/Resources" "$HELPER/Contents/MacOS" "$HELPER/Contents/Resources" "$ROOT/build/module-cache"

echo "==> Icon (Assets/AppIcon.png)"
/usr/bin/xcrun swift -module-cache-path "$ROOT/build/module-cache" "$ROOT/scripts/prepare-icon.swift" "$ROOT/Assets/AppIcon.png" "$WORK/AppIcon-RGBA.png"
while read -r pixels name; do
  /usr/bin/sips -z "$pixels" "$pixels" "$WORK/AppIcon-RGBA.png" --out "$WORK/iconset.iconset/$name.png" >/dev/null
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
if ! /usr/bin/iconutil -c icns "$WORK/iconset.iconset" -o "$WORK/AppIcon.icns" 2>"$WORK/iconutil.log"; then
  /usr/bin/xcrun swift -module-cache-path "$ROOT/build/module-cache" "$ROOT/scripts/pack-icon.swift" "$WORK/iconset.iconset" "$WORK/AppIcon.icns"
fi

monitors=""; viewers=""
for arch in $ARCHS; do
  echo "==> Compile background monitor ($arch, macOS $MIN_MACOS+)"
  /usr/bin/xcrun swiftc -D STORAGE_MONITOR_DISTRIBUTION -target "$arch-apple-macos$MIN_MACOS" -swift-version 5 -O -module-cache-path "$ROOT/build/module-cache" \
    -framework AppKit -framework UserNotifications -parse-as-library \
    "$ROOT"/Sources/*.swift "$ROOT"/SourcesShared/*.swift "$ROOT/tests/InventoryTests.swift" -o "$WORK/bin/StorageMonitor-$arch"
  echo "==> Compile desktop app ($arch, macOS $MIN_MACOS+)"
  /usr/bin/xcrun swiftc -D STORAGE_MONITOR_DISTRIBUTION -sdk "$SDK" -target "$arch-apple-macos$MIN_MACOS" -swift-version 5 -O -parse-as-library -module-cache-path "$ROOT/build/module-cache" \
    -framework SwiftUI -framework Charts -framework AppKit \
    "$ROOT"/SourcesGUI/*.swift "$ROOT"/SourcesShared/*.swift -o "$WORK/bin/StorageMonitorViewer-$arch"
  monitors="$monitors $WORK/bin/StorageMonitor-$arch"; viewers="$viewers $WORK/bin/StorageMonitorViewer-$arch"
done
# shellcheck disable=SC2086
/usr/bin/lipo -create $monitors -output "$HELPER/Contents/MacOS/StorageMonitor"
# shellcheck disable=SC2086
/usr/bin/lipo -create $viewers -output "$APP/Contents/MacOS/StorageMonitorViewer"
/bin/cp "$WORK/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
/bin/cp "$WORK/AppIcon.icns" "$HELPER/Contents/Resources/AppIcon.icns"
/bin/cp "$ROOT/THIRD-PARTY-NOTICES.md" "$APP/Contents/Resources/THIRD-PARTY-NOTICES.md"
/bin/cp "$ROOT/THIRD-PARTY-NOTICES.md" "$HELPER/Contents/Resources/THIRD-PARTY-NOTICES.md"

info() { # identifier name executable extra-keys
  /bin/cat <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>$1</string>
<key>CFBundleName</key><string>$2</string>
<key>CFBundleDisplayName</key><string>$2</string>
<key>CFBundleExecutable</key><string>$3</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
<key>CFBundleShortVersionString</key><string>$VERSION</string>
<key>CFBundleVersion</key><string>$BUILD</string>
<key>LSMinimumSystemVersion</key><string>$MIN_MACOS</string>
<key>NSHighResolutionCapable</key><true/>
$4
</dict></plist>
PLIST
}
info local.macbook.storage-monitor.viewer "Storage Monitor" StorageMonitorViewer \
  '<key>NSPrincipalClass</key><string>NSApplication</string>
<key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>' > "$APP/Contents/Info.plist"
info local.macbook.storage-monitor "MacBook Storage Monitor" StorageMonitor '<key>LSUIElement</key><true/><key>StorageMonitorExternalVolumeSupport</key><integer>1</integer>' > "$HELPER/Contents/Info.plist"
/usr/bin/plutil -lint "$APP/Contents/Info.plist" "$HELPER/Contents/Info.plist" >/dev/null

echo "==> Normalize permissions, attributes and timestamps"
/bin/chmod -R u+rwX,go+rX,go-w "$APP"
/bin/chmod 755 "$APP/Contents/MacOS/StorageMonitorViewer" "$HELPER/Contents/MacOS/StorageMonitor"
/usr/bin/xattr -cr "$APP"
STAMP=$(/bin/date -r "$EPOCH" +%Y%m%d%H%M.%S)
/usr/bin/find "$APP" -exec /usr/bin/touch -h -t "$STAMP" {} +

echo "==> Sign (identity: $IDENTITY)"
sign() { # path identifier
  if [ "$IDENTITY" = - ]; then /usr/bin/codesign --force --sign - --identifier "$2" "$1"
  else /usr/bin/codesign --force --sign "$IDENTITY" --identifier "$2" --options runtime --timestamp "$1"; fi
}
sign "$HELPER" local.macbook.storage-monitor          # nested code first
sign "$APP" local.macbook.storage-monitor.viewer
/usr/bin/codesign --verify --deep --strict "$APP"
if [ "${STORAGE_MONITOR_APP_ONLY:-0}" = 1 ]; then echo "Built $APP (no disk image)"; exit 0; fi

echo "==> Disk image"
STAGE="$WORK/dmg-root"
/bin/mkdir -p "$STAGE"
/usr/bin/ditto "$APP" "$STAGE/Storage Monitor.app"
/bin/ln -s /Applications "$STAGE/Applications"
/usr/bin/touch -h -t "$STAMP" "$STAGE" "$STAGE/Applications"
/bin/rm -f "$DMG" "$DMG.sha256"
/usr/bin/hdiutil create -quiet -volname "Storage Monitor" -srcfolder "$STAGE" -fs HFS+ -format UDZO -imagekey zlib-level=9 -ov "$DMG"
if [ "$IDENTITY" != - ]; then /usr/bin/codesign --force --sign "$IDENTITY" --timestamp "$DMG"; fi
(cd "$DIST" && /usr/bin/shasum -a 256 "$(basename "$DMG")" > "$(basename "$DMG").sha256")
echo "Built $DMG ($(/usr/bin/du -h "$DMG" | /usr/bin/cut -f1))"

if [ "${STORAGE_MONITOR_SKIP_VERIFY:-0}" != 1 ]; then
  /bin/sh "$ROOT/scripts/verify-dmg.sh" "$DMG" "$VERSION" "$BUILD"
fi
