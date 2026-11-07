#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
mkdir -p "$ROOT/build/module-cache"
set --
for source in "$ROOT/SourcesShared/ExternalVolumeModels.swift" "$ROOT/SourcesShared/ExternalVolumeRegistry.swift" "$ROOT/SourcesShared/ExternalVolumeMount.swift" "$ROOT/SourcesShared/ExternalVolumeObservations.swift"; do
  [ ! -f "$source" ] || set -- "$@" "$source"
done
/usr/bin/xcrun swiftc -swift-version 5 -Onone -parse-as-library -module-cache-path "$ROOT/build/module-cache" "$@" "$ROOT/tests/ExternalVolumeTests.swift" -o "$ROOT/build/ExternalVolumeTests"
"$ROOT/build/ExternalVolumeTests"
