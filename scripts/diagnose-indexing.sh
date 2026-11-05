#!/bin/sh
# Read-only startup diagnostics. Never launches the helper, scans files or changes services.
# Review the output before sharing: existing logs may contain folder names.
set -u
case "$#" in
  0) diagnostic_home=$HOME ;;
  2) [ "$1" = --home ] && [ "${2#/}" != "$2" ] || { echo 'Usage: diagnose-indexing.sh [--home /absolute/home]'; exit 2; }; diagnostic_home=$2 ;;
  *) echo 'Usage: diagnose-indexing.sh [--home /absolute/home]'; exit 2 ;;
esac
diagnostic_data="$diagnostic_home/Library/Application Support/MacBook Storage Monitor"
diagnostic_helper="$diagnostic_home/Applications/MacBook Storage Monitor.app"
diagnostic_domain="gui/$(/usr/bin/id -u)"
/bin/date -u
/usr/bin/sw_vers
/usr/bin/uname -m

for diagnostic_app in '/Applications/Storage Monitor.app' "$diagnostic_helper"; do
  /usr/bin/printf '\nApp: %s\n' "$diagnostic_app"
  if [ -f "$diagnostic_app/Contents/Info.plist" ]; then
    if [ "$diagnostic_app" = "$diagnostic_helper" ]; then diagnostic_executable=StorageMonitor; else diagnostic_executable=StorageMonitorViewer; fi
    /usr/bin/plutil -extract CFBundleShortVersionString raw -o - "$diagnostic_app/Contents/Info.plist"
    /usr/bin/plutil -extract CFBundleVersion raw -o - "$diagnostic_app/Contents/Info.plist"
    /usr/bin/codesign --verify --deep --strict "$diagnostic_app" 2>&1
    /usr/bin/xattr -p com.apple.quarantine "$diagnostic_app" 2>&1
    /usr/bin/xattr -p com.apple.quarantine "$diagnostic_app/Contents/MacOS/$diagnostic_executable" 2>&1
  else
    echo 'App metadata is missing.'
  fi
done

for diagnostic_label in local.macbook.storage-monitor local.macbook.storage-monitor.baseline local.macbook.storage-monitor.inventory; do
  /usr/bin/printf '\nService: %s\n' "$diagnostic_label"
  diagnostic_plist="$diagnostic_home/Library/LaunchAgents/$diagnostic_label.plist"
  if [ -f "$diagnostic_plist" ]; then
    /usr/bin/plutil -extract ProgramArguments json -o - "$diagnostic_plist"
  else
    echo 'LaunchAgent file is missing.'
  fi
  # Full launchctl output can include inherited environment values; report only execution fields.
  /bin/launchctl print "$diagnostic_domain/$diagnostic_label" 2>&1 |
    /usr/bin/awk '/^[[:space:]]*(state|program|runs|pid|last exit code|last terminating signal) =/ || /Could not find service|Bad request|Could not find domain|Operation not permitted/'
done
/usr/bin/printf '\nDisabled overrides for Storage Monitor:\n'
/bin/launchctl print-disabled "$diagnostic_domain" 2>&1 | /usr/bin/awk '/local[.]macbook[.]storage-monitor/'

/usr/bin/printf '\nInventory pause marker: '
if [ -e "$diagnostic_data/inventory.cancel" ]; then echo present; else echo absent; fi
/usr/bin/printf '\nCatalog file metadata (database is not opened):\n'
if [ -f "$diagnostic_data/history.sqlite3" ]; then
  /usr/bin/stat -f 'bytes=%z modified=%Sm' "$diagnostic_data/history.sqlite3"
else
  echo 'No catalog file.'
fi
for diagnostic_log in "$diagnostic_data/monitor.log.1" "$diagnostic_data/monitor.log"; do
  /usr/bin/printf '\nRecent worker records: %s\n' "$diagnostic_log"
  if [ -f "$diagnostic_log" ]; then
    /usr/bin/tail -n 120 "$diagnostic_log" | /usr/bin/grep -E ' inventory |ERROR inventory-work'
  else
    echo 'No log file.'
  fi
done
exit 0
