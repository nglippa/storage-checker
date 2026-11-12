#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
SDK_PATH=${STORAGE_MONITOR_SDK_PATH:-$(/usr/bin/xcrun --show-sdk-path)}
BASE=$(mktemp -d /private/tmp/storage-snapshot-native-XXXXXXXX)
DEVICE=
cleanup() {
  if [ -n "$DEVICE" ]; then /usr/bin/hdiutil detach "$DEVICE" >/dev/null || true; fi
  # Only our generated image, binary and fixtures. Preserve the directory if a mount is still busy.
  if ! /sbin/mount | /usr/bin/grep -Fq " on $BASE/mount "; then /bin/rm -rf "$BASE"; else /usr/bin/printf '%s\n' "Preserved mounted disposable fixture: $BASE" >&2; fi
}
trap cleanup EXIT HUP INT TERM
mkdir "$BASE/mount"
/usr/bin/hdiutil create -size 256m -fs APFS -volname StorageMonitorDisposable -type SPARSE -quiet "$BASE/test.sparseimage"
/usr/bin/hdiutil attach -nobrowse -owners on -mountpoint "$BASE/mount" -plist "$BASE/test.sparseimage" > "$BASE/attachment.plist"
DEVICE=$(/usr/libexec/PlistBuddy -c 'Print :system-entities:0:dev-entry' "$BASE/attachment.plist")
xcrun clang -isysroot "$SDK_PATH" -mmacosx-version-min=14.0 -Wall -Wextra -Werror -c "$ROOT/SourcesSnapshotService/SnapshotNative.c" -o "$BASE/native.o"
xcrun swiftc -sdk "$SDK_PATH" -target arm64-apple-macos14.0 -swift-version 5 -parse-as-library -import-objc-header "$ROOT/SourcesSnapshotService/SnapshotNative.h" -framework Security "$ROOT"/SourcesShared/SnapshotLifecycle*.swift "$ROOT/SourcesSnapshotService/SnapshotNativeBackend.swift" "$ROOT/tests/SnapshotNativeDisposableTests.swift" "$BASE/native.o" -o "$BASE/test"
"$BASE/test" "$BASE/mount"

/usr/bin/hdiutil detach "$DEVICE" >/dev/null
DEVICE=
"$BASE/test" --offline "$BASE/volume.json"
