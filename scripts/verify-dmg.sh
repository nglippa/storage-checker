#!/bin/sh
# Non-interactive structural verification of a Storage Monitor disk image.
# Mounts read-only with -nobrowse (no Finder window, no app launch), inspects, always detaches.
# Usage: scripts/verify-dmg.sh path/to/Storage-Monitor-X.dmg [version] [build]
set -u
DMG=${1:?Usage: verify-dmg.sh image.dmg [version] [build]}
VERSION=${2:-}
BUILD=${3:-}
MOUNT=$(/usr/bin/mktemp -d /private/tmp/storage-monitor-dmg-verify.XXXXXX)
failures=0
result() { if [ "$1" -eq 0 ]; then echo "PASS $2"; else echo "FAIL $2"; failures=$((failures + 1)); fi; }
cleanup() {
  /usr/bin/hdiutil detach -quiet "$MOUNT" 2>/dev/null || /usr/bin/hdiutil detach -quiet -force "$MOUNT" 2>/dev/null
  /bin/rmdir "$MOUNT" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

/usr/bin/hdiutil verify -quiet "$DMG"; result $? "image checksum verifies"
if ! /usr/bin/hdiutil attach -quiet -readonly -nobrowse -noautoopen -mountpoint "$MOUNT" "$DMG"; then echo "FAIL image mounts read-only without Finder"; exit 1; fi
result 0 "image mounts read-only without Finder (-nobrowse, -noautoopen)"

APP="$MOUNT/Storage Monitor.app"
HELPER="$APP/Contents/Helpers/MacBook Storage Monitor.app"
VIEWER="$APP/Contents/MacOS/StorageMonitorViewer"
MONITOR="$HELPER/Contents/MacOS/StorageMonitor"
value() { /usr/bin/plutil -extract "$2" raw -o - "$1/Contents/Info.plist" 2>/dev/null; }
same() { [ "$1" = "$2" ]; }

entries=$(/bin/ls "$MOUNT" | /usr/bin/grep -v '^\.' | /usr/bin/tr '\n' '|')
same "$entries" "Applications|Storage Monitor.app|"; result $? "volume contains exactly Storage Monitor.app and Applications ($entries)"
[ -L "$MOUNT/Applications" ] && same "$(/usr/bin/readlink "$MOUNT/Applications")" /Applications; result $? "Applications shortcut is a symlink to /Applications"
same "$(value "$APP" CFBundleIdentifier)" local.macbook.storage-monitor.viewer; result $? "app bundle identifier is local.macbook.storage-monitor.viewer"
same "$(value "$APP" CFBundleDisplayName)" "Storage Monitor" && same "$(value "$APP" CFBundleName)" "Storage Monitor"; result $? "app display name is Storage Monitor"
same "$(value "$HELPER" CFBundleIdentifier)" local.macbook.storage-monitor && same "$(value "$HELPER" LSUIElement)" true; result $? "bundled helper is local.macbook.storage-monitor and background-only"
if [ -n "$VERSION" ]; then
  same "$(value "$APP" CFBundleShortVersionString)" "$VERSION" && same "$(value "$HELPER" CFBundleShortVersionString)" "$VERSION" \
    && same "$(value "$APP" CFBundleVersion)" "$BUILD" && same "$(value "$HELPER" CFBundleVersion)" "$BUILD"
  result $? "app and helper version $VERSION ($BUILD)"
fi
same "$(value "$APP" LSMinimumSystemVersion)" 14.0 && same "$(value "$HELPER" LSMinimumSystemVersion)" 14.0; result $? "both bundles declare minimum macOS 14.0"
for binary in "$VIEWER" "$MONITOR"; do
  name=$(/usr/bin/basename "$binary")
  [ -x "$binary" ]; result $? "$name is executable"
  archs=$(/usr/bin/lipo -archs "$binary" | /usr/bin/tr ' ' '\n' | /usr/bin/sort | /usr/bin/tr '\n' ' ')
  same "$archs" "arm64 x86_64 "; result $? "$name is universal ($archs)"
  same "$(/usr/bin/vtool -show-build "$binary" | /usr/bin/awk '/minos/{print $2}' | /usr/bin/sort -u)" 14.0; result $? "$name deployment target is macOS 14.0 for every architecture"
  external=$(/usr/bin/otool -L "$binary" | /usr/bin/grep -E '^[[:space:]]' | /usr/bin/awk '{print $1}' | /usr/bin/sort -u | /usr/bin/grep -vE '^(/usr/lib/|/System/Library/)')
  [ -z "$external" ]; result $? "$name links only system libraries${external:+ ($external)}"
  rpaths=$(/usr/bin/otool -l "$binary" | /usr/bin/awk '/cmd LC_RPATH/{getline; getline; print $2}' | /usr/bin/sort -u | /usr/bin/tr '\n' ' ')
  ! /usr/bin/otool -l "$binary" | /usr/bin/grep -qE 'Xcode.app|CommandLineTools|Toolchains' && [ -z "$(echo "$rpaths" | /usr/bin/tr ' ' '\n' | /usr/bin/grep -v '^$' | /usr/bin/grep -v '^/usr/lib/')" ]
  result $? "$name searches only system runtime paths (rpaths: ${rpaths:-none}) and no developer toolchain"
  ! /usr/bin/strings -a "$binary" | /usr/bin/grep -qF "$HOME/"; result $? "$name embeds no build-machine home or repository path"
done
[ -s "$APP/Contents/Resources/AppIcon.icns" ] && [ -s "$HELPER/Contents/Resources/AppIcon.icns" ] && same "$(value "$APP" CFBundleIconFile)" AppIcon; result $? "both bundles carry the approved icon"
/usr/bin/plutil -lint "$APP/Contents/Info.plist" "$HELPER/Contents/Info.plist" >/dev/null; result $? "Info.plists are valid"
/usr/bin/codesign --verify --deep --strict "$APP"; result $? "code signature verifies (deep, strict)"
echo "INFO app signature: $(/usr/bin/codesign -dv "$APP" 2>&1 | /usr/bin/grep -E '^(Signature|Authority)=' | /usr/bin/head -1)"
echo "INFO helper signature: $(/usr/bin/codesign -dv "$HELPER" 2>&1 | /usr/bin/grep -E '^(Signature|Authority)=' | /usr/bin/head -1)"
echo "INFO Gatekeeper assessment (informational): $(/usr/sbin/spctl --assess --type execute "$APP" 2>&1 | /usr/bin/head -1)"
# The background monitor runs from the read-only image without the repository. Its self-test
# uses only temporary files, a recording fake for launchd and simulated notification delivery.
selftest=$("$MONITOR" self-test 2>&1 | /usr/bin/tail -1)
case "$selftest" in *"tests passed") result 0 "bundled background monitor runs from the image ($selftest)";; *) result 1 "bundled background monitor self-test from the image: $selftest";; esac

if [ "$failures" -eq 0 ]; then echo "DMG verification passed: $DMG"; else echo "DMG verification FAILED ($failures)"; exit 1; fi
