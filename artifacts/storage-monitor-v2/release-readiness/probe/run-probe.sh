#!/bin/sh
# Preference-isolation proof. Never runs as the production identifier; production preferences are only read.
set -u
W=$1; QADB=$2
PROD=local.macbook.storage-monitor.viewer; DEV=local.macbook.storage-monitor.viewer.dev
STANDIN=local.macbook.storage-monitor.viewer.isolation-probe; QA=local.macbook.storage-monitor.viewer.qa
KEYS="inventory.explorer.visualization inventory.explorer.treeNavigatorExpanded event.showEvidence inventory.livingTree.dimension"
prodfile="$HOME/Library/Preferences/$PROD.plist"
snap() { /usr/bin/defaults export "$1" - 2>/dev/null | /usr/bin/shasum -a 256 | cut -c1-16; }
keys() { for k in $KEYS; do printf '%s=%s ' "$k" "$(/usr/bin/defaults read "$1" "$k" 2>/dev/null || echo '<unset>')"; done; echo; }
run() { "$W/$1.app/Contents/MacOS/probe" "$@"; }
echo "production file sha256: $(/usr/bin/shasum -a 256 "$prodfile" | cut -c1-16)  semantic: $(snap $PROD)"
echo "production keys: $(keys $PROD)"
echo "QA suite before: $(keys $QA)"
echo "dev domain before: $(keys $DEV) semantic: $(snap $DEV)"
# Stand-in production domain with established preferences.
/usr/bin/defaults write $STANDIN inventory.explorer.visualization atlas; /usr/bin/defaults write $STANDIN inventory.explorer.treeNavigatorExpanded -bool false
/usr/bin/defaults write $STANDIN event.showEvidence -bool false; /usr/bin/defaults write $STANDIN inventory.livingTree.dimension flat
standin_before=$(snap $STANDIN); dev_before=$(snap $DEV)
echo "--- 1 stand-in production identity, QA database, changes settings"; run $STANDIN --database-path "$QADB" --probe-write
echo "    stand-in domain unchanged: $([ "$(snap $STANDIN)" = "$standin_before" ] && echo YES || echo NO)  QA suite: $(keys $QA)"
echo "--- 2 development identity, QA database, changes settings"; run $DEV --database-path "$QADB" --probe-write
echo "    dev domain unchanged: $([ "$(snap $DEV)" = "$dev_before" ] && echo YES || echo NO)"
echo "--- 3 development identity, QA database, relaunch reads"; run $DEV --database-path "$QADB"
echo "--- 4 stand-in production, normal launch, reads its own saved settings"; run $STANDIN
echo "--- 5 QA flags without a QA database (development identity)"; run $DEV --perf-log /private/tmp/storage-monitor-probe-perf.log --perf-script
echo "--- 6 control: stand-in production, normal launch, changes settings (lands in its own domain)"; run $STANDIN --probe-write
echo "    stand-in domain changed: $([ "$(snap $STANDIN)" != "$standin_before" ] && echo YES || echo NO)  $(keys $STANDIN)"
echo "production file sha256: $(/usr/bin/shasum -a 256 "$prodfile" | cut -c1-16)  semantic: $(snap $PROD)"
echo "production keys: $(keys $PROD)"
echo "perf log created by step 5: $([ -e /private/tmp/storage-monitor-probe-perf.log ] && echo YES || echo NO)"
