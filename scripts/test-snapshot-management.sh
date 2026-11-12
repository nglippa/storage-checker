#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
TMP=$(mktemp -d /private/tmp/storage-snapshot-management-tests.XXXXXX)
trap 'rm -rf "$TMP"' EXIT HUP INT TERM
swiftc -swift-version 5 -parse-as-library "$ROOT"/SourcesShared/SnapshotLifecycle*.swift "$ROOT/tests/SnapshotManagementTests.swift" "$ROOT/tests/SnapshotLifecycleEngineTests.swift" -o "$TMP/tests"
"$TMP/tests"
