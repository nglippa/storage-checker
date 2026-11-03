#!/bin/sh
# Offscreen Migration Readiness renders from a disposable sparse-file fixture under /private/tmp. Never launches or
# focuses an app; windows are never ordered in. Needs scripts/build.sh first (the worker indexes the fixture).
# Usage: scripts/render-migration-readiness.sh <output folder>
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
OUT=${1:?usage: render-migration-readiness.sh <output folder>}
SDK_PATH=${STORAGE_MONITOR_SDK_PATH:-/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk}
MONITOR="$ROOT/build/MacBook Storage Monitor.app/Contents/MacOS/StorageMonitor"
[ -x "$MONITOR" ] || { echo 'Build the monitor first with scripts/build.sh.' >&2; exit 1; }
WORK=$(/usr/bin/mktemp -d /private/tmp/storage-monitor-migration-render.XXXXXX)
trap '/bin/rm -rf "$WORK"' EXIT INT TERM
/bin/chmod 700 "$WORK"
T="$WORK/Example Mac"
/bin/mkdir -p "$T/Library/Containers/com.docker.docker/Data/vms/0/data" "$T/.orbstack/data" "$T/Parallels/Windows 11.pvm/harddisk.hdd" \
  "$T/Backups/Archive.sparsebundle/bands" "$T/Projects/site/assets" "$T/Media" "$OUT"
# Sparse files: large logical sizes, little allocated (ftruncate). Real metadata; about 200 MB is written in total.
/usr/bin/python3 - "$T" <<'PY'
import os, plistlib, sys
root = sys.argv[1]
def sparse(rel, gib, written=4096):
    fd = os.open(os.path.join(root, rel), os.O_CREAT | os.O_WRONLY | os.O_TRUNC, 0o644)
    os.write(fd, b'R' * written); os.ftruncate(fd, int(gib * (1 << 30))); os.fsync(fd); os.close(fd)
sparse('Library/Containers/com.docker.docker/Data/vms/0/data/Docker.raw', 460, 96 << 20)
sparse('.orbstack/data/data.img', 64, 24 << 20)
sparse('Parallels/Windows 11.pvm/harddisk.hdd/harddisk.hdd.0.{5fbaabe3}.hds', 128, 48 << 20)
sparse('Media/scratch.img', 3, 1 << 20)
with open(os.path.join(root, 'Backups/Archive.sparsebundle/Info.plist'), 'wb') as f: plistlib.dump({'size': 1 << 40, 'band-size': 8 << 20}, f)
for b in range(4): sparse(f'Backups/Archive.sparsebundle/bands/{b}', 0.0625)
for i in range(40):
    with open(os.path.join(root, f'Projects/site/assets/a{i}.bin'), 'wb') as f: f.write(os.urandom(256 << 10))
PY
"$MONITOR" inventory-work --root "$T" --data-dir "$WORK/state" --budget 60 >/dev/null
/usr/bin/sed 's/^@main struct StorageMonitorViewerApp/struct StorageMonitorViewerApp/' "$ROOT/SourcesGUI/StorageMonitorApp.swift" > "$WORK/StorageMonitorApp.swift"
GUI=$(/bin/ls "$ROOT"/SourcesGUI/*.swift | /usr/bin/grep -v '/StorageMonitorApp\.swift$')
IFS='
'
/usr/bin/xcrun swiftc -sdk "$SDK_PATH" -target arm64-apple-macos14.0 -swift-version 5 -O -parse-as-library -module-cache-path "$WORK/module-cache" \
  -framework SwiftUI -framework Charts -framework AppKit $GUI "$WORK/StorageMonitorApp.swift" "$ROOT"/SourcesShared/*.swift "$ROOT/scripts/render-migration-readiness.swift" -o "$WORK/render"
"$WORK/render" "$WORK/state/history.sqlite3" "$OUT"
