#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
TMP=$(mktemp -d /private/tmp/storage-time-machine-snapshot-tests.XXXXXX)
trap 'rm -rf "$TMP"' EXIT HUP INT TERM
swiftc -swift-version 5 -parse-as-library \
    "$ROOT/SourcesShared/TimeMachineSnapshots.swift" \
    "$ROOT/tests/TimeMachineSnapshotTests.swift" \
    -o "$TMP/tests"
"$TMP/tests"
