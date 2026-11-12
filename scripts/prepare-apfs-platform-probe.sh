#!/bin/sh
# Prepare, do not elevate: direct native probe restricted at compile time to a new disposable image.
# Leave the image mounted for a separately approved administrator run of the SAME binary.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
SDK_PATH=${STORAGE_MONITOR_SDK_PATH:-$(/usr/bin/xcrun --show-sdk-path)}
BASE=$(mktemp -d /private/tmp/storage-apfs-direct-probe.XXXXXXXX)
mkdir "$BASE/mount"
/usr/bin/hdiutil create -size 256m -fs APFS -volname StorageMonitorDirectProbe -type SPARSE -quiet "$BASE/disposable.sparseimage"
/usr/bin/hdiutil attach -nobrowse -owners on -mountpoint "$BASE/mount" -plist "$BASE/disposable.sparseimage" > "$BASE/attachment.plist"
/usr/sbin/diskutil info -plist "$BASE/mount" > "$BASE/volume.plist"
VOLUME_UUID=$(/usr/libexec/PlistBuddy -c 'Print :VolumeUUID' "$BASE/volume.plist")
VOLUME_DEVICE=$(/usr/libexec/PlistBuddy -c 'Print :DeviceIdentifier' "$BASE/volume.plist")
SNAPSHOT_NAME="local.storage-monitor.platform-probe.$(/usr/bin/uuidgen)"
cat > "$BASE/ProbeTarget.h" <<TARGET
#define PROBE_MOUNT "$BASE/mount"
#define PROBE_UUID "$VOLUME_UUID"
#define PROBE_DEVICE "$VOLUME_DEVICE"
#define PROBE_NAME "$SNAPSHOT_NAME"
TARGET
xcrun clang -isysroot "$SDK_PATH" -mmacosx-version-min=14.0 -Wall -Wextra -Werror -I "$ROOT/SourcesSnapshotService" -I "$BASE" "$ROOT/SourcesSnapshotService/SnapshotNative.c" "$ROOT/tests/APFSSnapshotPlatformProbe.c" -framework Security -framework CoreFoundation -o "$BASE/snapshot-api-probe"
# Ad-hoc signing supplies no entitlement or developer certificate; no entitlement is fabricated.
/usr/bin/codesign --force --sign - "$BASE/snapshot-api-probe"
/usr/bin/printf '%s\n' "$BASE"
