#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
SOURCE="$ROOT/build/Storage Monitor.app"
if [ ! -x "$SOURCE/Contents/MacOS/StorageMonitorViewer" ]; then /usr/bin/printf '%s\n' 'Run scripts/build-gui.sh first.' >&2; exit 1; fi
if [ "${1:-}" = --destination ]; then
  DESTINATION=${2:?Supply an absolute .app destination}
else
  if [ -w /Applications ]; then DESTINATION='/Applications/Storage Monitor.app'; else DESTINATION="$HOME/Applications/Storage Monitor.app"; fi
fi
case "$DESTINATION" in /*/Storage\ Monitor.app) ;; *) /usr/bin/printf '%s\n' 'Destination must be an absolute path ending in /Storage Monitor.app.' >&2; exit 1;; esac
if /usr/bin/pgrep -f "$DESTINATION/Contents/MacOS/StorageMonitorViewer" >/dev/null; then /usr/bin/printf '%s\n' 'Quit Storage Monitor before updating its app bundle.' >&2; exit 1; fi
/bin/mkdir -p "$(dirname -- "$DESTINATION")"
/usr/bin/ditto "$SOURCE" "$DESTINATION"
/usr/bin/codesign --verify --strict "$DESTINATION"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$DESTINATION"
/usr/bin/printf '%s\n' "Installed GUI: $DESTINATION" 'Background monitor app and LaunchAgent were not changed.'
