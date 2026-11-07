# Cleanup review Inspector scroll stability — 2026-10-31

## Reproduced cause and fix

The queue's same-item revalidation called `beginQueueReview`, which removed the displayed evidence and open preview before collecting replacement evidence. The real SwiftUI Inspector's document contracted from 1,840 to 639 points, clamping a deep scroll offset from 1,320 to 119. The document expanded again without restoring that position. This explains a panel-wide jump while reading lower sections.

`beginQueueReview` now retains the current evidence and preview only when the catalog ID, filesystem identity and exact path still match. It marks the review pending, cancels any prepared confirmation, and binds subsequent preview refreshes to the latest row. A different object or path clears the old content even if its catalog ID is reused. A failed refresh discards retained evidence and preview. Pending revalidation continues to block advisory Trash availability; preparation and execution policy are unchanged.

## Offscreen regression — VERIFIED

Run `scripts/test-cleanup-inspector-scroll.sh`. It compiles the real viewer sources and hosts `InventoryInspectorView` with queue evidence in a never-shown window with prohibited activation. Only the initial disclosure defaults are expanded in scratch source copies, so no desktop input is required. The fixture is a small generated project under `/private/tmp`; no production catalog is opened. The runner preserves its compiler/test log and propagates the actual exit status. This is a layout regression, compiled without optimization, not a performance benchmark.

| Observation | Original code | Final fix |
|---|---:|---:|
| Deep offset before / minimum / after same-item revalidation | 1,320 / 119 / 119 | 1,320 / 1,320 / 1,320 |
| Document height before / minimum | 1,840 / 639 | 1,840 / 1,840 |
| Same-item preview retained | Failed | Passed |

The original failure was recorded with an optimized build. The initial fix also passed an optimized run. The final unoptimized regression passes nine checks: idle scroll stability, minimum scroll offset during revalidation, minimum document height, preview retention, authoritative returned-row measurement, replacement discovered during refresh, failed-refresh cleanup/refusal, same-ID object replacement and different-selection cleanup. Both pairs of replacement/failure and returned-row checks were first observed failing before their corresponding corrections.

Evidence retained under `/private/tmp`:

- Original failure: `storage-monitor-cleanup-scroll.eDwGi6/test.log`, exit 1 (three failures).
- Initial scroll fix: `storage-monitor-cleanup-scroll.BXha8j/test.log`, exit 0.
- Replacement/failure regression: `storage-monitor-cleanup-scroll.lfwaQ8/test.log`, exit 1 (two failures).
- Identity/failure correction: `storage-monitor-cleanup-scroll.4v9e2g/test.log`, exit 0 (seven checks).
- Returned-row regression: `storage-monitor-cleanup-scroll.26keoo/test.log`, exit 1 (two failures).
- Final regression: `storage-monitor-cleanup-scroll.C6fib4/test.log`, exit 0 (nine checks).

The compiler reports the existing unrelated weak/strong capture warning in the asynchronous Trash preparation progress callback. It was present before this fix and remains unchanged.

## Controller regression — VERIFIED

`STORAGE_MONITOR_SDK_PATH=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk scripts/test-inventory-model.sh` passed **69 tests, 0 failures** against the final source, including the new retained-evidence and pending-Trash checks, existing freshness/preview invalidation, and isolated-worker Queue/Inspector reconciliation. Log: `/private/tmp/cleanup-reviewer-check-20261031T103700Z/inventory-model-final.log`.

The first sandbox run aborted with an array-subscript trap after its fixture failed to index: its disposable catalog contained only the root, and the worker log reported `paused: low disk space`. The final unchanged command ran outside that sandbox restriction and passed; no capacity policy or assertion was weakened. Original failure log and fixture remain at `/private/tmp/cleanup-reviewer-check-20261031T103700Z/inventory-model.log` and `/private/tmp/storage-monitor-inventory-model-tests.Wt8R8X/`. The tests use the existing development monitor helper to index a bounded synthetic tree; it was not rebuilt or installed in this pass.

## Development viewer build — VERIFIED

`STORAGE_MONITOR_SDK_PATH=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk scripts/build-gui.sh` succeeded against the final source. Output: `build/Storage Monitor.app`, development identifier `local.macbook.storage-monitor.viewer.dev`. The local signature verifies with `codesign --verify --deep --strict`; its Info.plist passes `plutil -lint`. Build log: `/private/tmp/cleanup-reviewer-check-20261031T103700Z/viewer-build-final.log`. The existing capture warning above remains. The development app was neither launched nor installed.

## Scope and remaining native checks

**NOT VERIFIED:** scrolling with a physical wheel or trackpad in a visible window; toggling the affected disclosures in a visible window; live queue refresh while scrolling that window. The regression measures the real offscreen scroll document and clip offset, not desktop interaction. No application was activated, no desktop input was sent, and no installed app, production/QA worker or protected database was changed.
