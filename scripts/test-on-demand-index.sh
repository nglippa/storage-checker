#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
OUTPUT=$(/usr/bin/mktemp /private/tmp/storage-monitor-on-demand-index-tests.XXXXXX)
trap '/bin/rm -f "$OUTPUT"' EXIT HUP INT TERM
/usr/bin/xcrun swiftc -swift-version 5 -O -parse-as-library \
  -framework AppKit -framework SwiftUI \
  "$ROOT/SourcesGUI/OnDemandIndex.swift" "$ROOT/tests/OnDemandIndexTests.swift" \
  -o "$OUTPUT"
"$OUTPUT"
