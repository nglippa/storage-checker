#!/bin/sh
set -eu

REPO_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
BUILD_DIR=$(mktemp -d /private/tmp/storage-monitor-snapshot-model.XXXXXX)
trap 'rm -rf "$BUILD_DIR"' EXIT HUP INT TERM

swiftc \
  -swift-version 5 \
  "$REPO_DIR/SourcesShared/APFSSnapshotIntelligence.swift" \
  "$REPO_DIR/tests/APFSSnapshotModelTests.swift" \
  -o "$BUILD_DIR/APFSSnapshotModelTests"

"$BUILD_DIR/APFSSnapshotModelTests"
