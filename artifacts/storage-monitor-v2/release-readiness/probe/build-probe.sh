#!/bin/sh
# Builds the preference-isolation probe from the current viewer sources into <work>/<identifier>.app bundles.
set -eu
ROOT=/Users/nicholaslippa/storage-checker; P=$ROOT/artifacts/storage-monitor-v2/release-readiness/probe; W=$1; FLAGS=${2:-}
sed 's/@main struct StorageMonitorViewerApp/struct StorageMonitorViewerApp/' "$ROOT/SourcesGUI/StorageMonitorApp.swift" > "$W/StorageMonitorApp.swift"
set --
for f in "$ROOT"/SourcesGUI/*.swift; do [ "$(basename "$f")" = StorageMonitorApp.swift ] || set -- "$@" "$f"; done
/usr/bin/xcrun swiftc $FLAGS -sdk /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk -target arm64-apple-macos14.0 -swift-version 5 -O -parse-as-library \
  -module-cache-path "$ROOT/build/module-cache" -framework SwiftUI -framework Charts -framework AppKit \
  "$@" "$ROOT"/SourcesShared/*.swift "$W/StorageMonitorApp.swift" "$P/PreferenceProbe.swift" -o "$W/probe" 2>&1 | grep -E "error" || true
for id in local.macbook.storage-monitor.viewer.dev local.macbook.storage-monitor.viewer.isolation-probe; do
  A="$W/$id.app"; mkdir -p "$A/Contents/MacOS"; cp "$W/probe" "$A/Contents/MacOS/probe"
  cat > "$A/Contents/Info.plist" <<PL
<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>$id</string><key>CFBundleExecutable</key><string>probe</string><key>CFBundlePackageType</key><string>APPL</string><key>LSUIElement</key><true/></dict></plist>
PL
  /usr/bin/codesign --force --sign - --identifier "$id" "$A"
done
