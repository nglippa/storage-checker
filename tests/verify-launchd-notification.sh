#!/bin/sh
# One-shot user-agent delivery probe. Uses only this monitor's own temporary files/job.
set -eu
APP="$HOME/Applications/MacBook Storage Monitor.app"
JOB=local.macbook.storage-monitor.notification-test
UID_NUMBER=$(/usr/bin/id -u)
TMP_DIR=$(/usr/bin/mktemp -d /private/tmp/storage-monitor-notification.XXXXXX)
trap '/bin/launchctl bootout "gui/$UID_NUMBER/$JOB" >/dev/null 2>&1 || true; /bin/rm -f "$TMP_DIR/job.plist" "$TMP_DIR/result.log"; /bin/rmdir "$TMP_DIR"' EXIT
/bin/cat > "$TMP_DIR/job.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>$JOB</string>
<key>ProgramArguments</key><array><string>$APP/Contents/MacOS/StorageMonitor</string><string>test-notification</string></array>
<key>RunAtLoad</key><true/>
<key>StandardOutPath</key><string>$TMP_DIR/result.log</string>
<key>StandardErrorPath</key><string>$TMP_DIR/result.log</string>
</dict></plist>
PLIST
/bin/launchctl bootstrap "gui/$UID_NUMBER" "$TMP_DIR/job.plist"
ATTEMPT=0
while [ "$ATTEMPT" -lt 30 ]; do
  if /bin/launchctl print "gui/$UID_NUMBER/$JOB" | /usr/bin/grep -Eq 'last exit code = [0-9]+'; then break; fi
  /bin/sleep 1
  ATTEMPT=$((ATTEMPT + 1))
done
/bin/cat "$TMP_DIR/result.log"
/bin/launchctl print "gui/$UID_NUMBER/$JOB" | /usr/bin/grep -E 'runs =|last exit code|state ='
if /usr/bin/grep -q '^delivered:' "$TMP_DIR/result.log"; then exit 0; fi
exit 1
