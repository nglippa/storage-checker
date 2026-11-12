#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
TMP=$(mktemp -d /private/tmp/storage-swap-counter-tests.XXXXXXXX)
trap 'rm -rf "$TMP"' EXIT HUP INT TERM
swiftc -swift-version 5 -parse-as-library "$ROOT/SourcesGUI/Models.swift" "$ROOT/SourcesGUI/HistoryReader.swift" "$ROOT/SourcesGUI/DiagnosticAnalysis.swift" "$ROOT/SourcesGUI/EventPanelText.swift" "$ROOT/SourcesGUI/LiveCapacity.swift" "$ROOT/SourcesGUI/MonitoringSetup.swift" "$ROOT/SourcesGUI/ViewerIdentity.swift" "$ROOT"/SourcesShared/*.swift "$ROOT/tests/SwapCounterPresentationTests.swift" -o "$TMP/tests"
"$TMP/tests"
