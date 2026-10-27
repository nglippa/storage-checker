#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
ARTIFACTS=${STORAGE_MONITOR_QUEUE_BENCHMARK_DIR:-/private/tmp/storage-monitor-queue-benchmark-build}
/bin/mkdir -p "$ARTIFACTS/module-cache"
/usr/bin/xcrun swiftc -swift-version 5 -O -parse-as-library -module-cache-path "$ARTIFACTS/module-cache" \
 "$ROOT/SourcesShared/InventoryModels.swift" "$ROOT/SourcesShared/InventoryPresentation.swift" "$ROOT/SourcesShared/InventoryChanges.swift" \
 "$ROOT/SourcesShared/InventoryExplorer.swift" "$ROOT/SourcesShared/InventoryMap.swift" "$ROOT/SourcesShared/StorageAtlas.swift" \
 "$ROOT/SourcesShared/LivingTree.swift" "$ROOT/SourcesShared/LivingTreeCamera.swift" "$ROOT/SourcesShared/LivingTree3D.swift" "$ROOT/SourcesShared/LivingTreeColor.swift" \
 "$ROOT/SourcesShared/CleanupModel.swift" "$ROOT/SourcesShared/CleanupEvidence.swift" "$ROOT/SourcesShared/CleanupDetectors.swift" \
 "$ROOT/SourcesShared/CleanupAssessment.swift" "$ROOT/SourcesShared/CleanupPresentation.swift" "$ROOT/SourcesShared/CleanupReviewQueue.swift" \
 "$ROOT/scripts/cleanup-review-queue-benchmark.swift" -o "$ARTIFACTS/benchmark"
"$ARTIFACTS/benchmark"
