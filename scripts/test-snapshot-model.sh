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

/usr/bin/xcrun swiftc \
  -swift-version 5 \
  -parse-as-library \
  -module-cache-path "$BUILD_DIR/module-cache" \
  -framework SwiftUI \
  -framework AppKit \
  "$REPO_DIR/SourcesGUI/Models.swift" \
  "$REPO_DIR/SourcesGUI/HistoryReader.swift" \
  "$REPO_DIR/SourcesGUI/DiagnosticAnalysis.swift" \
  "$REPO_DIR/SourcesGUI/EventPanelText.swift" \
  "$REPO_DIR/SourcesGUI/LiveCapacity.swift" \
  "$REPO_DIR/SourcesGUI/MonitoringSetup.swift" \
  "$REPO_DIR/SourcesGUI/ViewerIdentity.swift" \
  "$REPO_DIR/SourcesGUI/SnapshotManagementModel.swift" \
  "$REPO_DIR"/SourcesShared/*.swift \
  "$REPO_DIR/tests/TimeMachineSnapshotModelTests.swift" \
  -o "$BUILD_DIR/TimeMachineSnapshotModelTests"

"$BUILD_DIR/TimeMachineSnapshotModelTests"
