#!/bin/sh
set -eu
REPO=$(pwd)
WORK=/private/tmp/storage-marketing-230
SOURCE=$WORK/source
OUT=$REPO/artifacts/marketing-2.3.0
mkdir -p "$WORK/module-cache" "$OUT/originals"
if [ ! -f "$SOURCE/SourcesGUI/InventoryView.swift" ]; then
    mkdir -p "$SOURCE"
    git archive a98fa0f487df0bcbf4501ea4b9fbfc2e2069c479 | tar -x -C "$SOURCE"
fi
if [ ! -f "$WORK/demo.sqlite3" ]; then sqlite3 "$WORK/demo.sqlite3" < "$OUT/capture/demo-schema.sql"; fi
python3 "$OUT/capture/make-demo.py" "$WORK/demo.sqlite3" > "$OUT/capture/demo-inventory.json"
xcrun swiftc -sdk /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk -target arm64-apple-macos14.0 -module-cache-path "$WORK/module-cache" "$OUT/capture/set-demo-identities.swift" -o "$WORK/set-demo-identities"
"$WORK/set-demo-identities" "$WORK/demo.sqlite3"
python3 "$OUT/capture/prepare-source.py" "$SOURCE/SourcesGUI/StorageMonitorApp.swift" "$WORK/StorageMonitorApp.swift"
set --
for source in "$SOURCE"/SourcesGUI/*.swift; do
    case "$source" in */StorageMonitorApp.swift) ;; *) set -- "$@" "$source" ;; esac
done
xcrun swiftc -j 4 -sdk /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk -target arm64-apple-macos14.0 -swift-version 5 -Onone -parse-as-library -D STORAGE_MONITOR_DISTRIBUTION -module-cache-path "$WORK/module-cache" -framework SwiftUI -framework Charts -framework AppKit "$@" "$WORK/StorageMonitorApp.swift" "$SOURCE"/SourcesShared/*.swift "$OUT/capture/render.swift" -o "$WORK/render"
"$WORK/render" "$WORK/demo.sqlite3" "$OUT/originals"
