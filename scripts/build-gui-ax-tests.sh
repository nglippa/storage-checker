#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
/usr/bin/xcrun swiftc -swift-version 5 -O -parse-as-library -module-cache-path "$ROOT/build/module-cache" -framework AppKit -framework ApplicationServices "$ROOT/SourcesGUI/Models.swift" "$ROOT/SourcesGUI/HistoryReader.swift" "$ROOT/SourcesGUI/DiagnosticAnalysis.swift" "$ROOT/SourcesGUI/LiveCapacity.swift" "$ROOT/tests/GUIAXTests.swift" -o "$ROOT/build/GUIAXTests"
/usr/bin/printf '%s\n' "Built $ROOT/build/GUIAXTests. Run only against an already open QA window: GUIAXTests PID /absolute/populated.sqlite3"
