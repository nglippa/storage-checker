# Handoff: event-gap reconciliation churn (in progress, 2026-10-23 ~07:40 UTC)

Read `AGENTS.md` first. Never focus or launch windows. Never touch the QA worker or its database, production, or LaunchAgents. No commits, pushes or installs.

## Confirmed root cause

The evidence comes from code and from read-only QA inspection.

- `reconcileInventoryEvents` (Sources/InventoryCommands.swift) runs at every worker slice start. The **old** code treated any of these as a full-volume "File-event gap":
  - more than 4,096 distinct changed paths (`overflow`);
  - a replay that didn't finish within 5 s (`!historyDone`);
  - "stream unavailable";
  - real loss: dropped or wrapped events, root change, root rescan;
  - identity changes, or a missing, regressed or expired (6 h) cursor.
- `applyInventoryInvalidations` resets an existing reconcile frontier to 0 when a newer gap's `request_sequence` arrives (`last_node_id=CASE WHEN excluded.request_sequence>… THEN 0`). The frontier is otherwise durable across slices and restarts (`inventory_reconcile.last_node_id`).
- QA read-only evidence:
  - The reconcile row was re-requested at 07:20:23Z, which was a slice start; the cursor was acknowledged at the same moment.
  - The frontier was 198,029 of 2,859,094 at 07:27, then unchanged at 07:34–07:39.
  - Each slice processes 0.8–1.2 M entries.
- Read-only FSEvents diagnostic from the QA cursor (event 155139381), using a scratch tool:
  - 9 min of history gave 3,889 distinct paths (heading past 4,096 within a 20-minute slice);
  - replay took 1.1 s;
  - no loss flags;
  - event IDs arrived **out of order** (56,844 inversions, backward jumps up to 48,547 IDs).
- **Conclusion:** the 4,096-path overflow (ordinary volume, not loss) is the probable trigger. The 5 s timeout is unlikely to be.
- **NOT yet confirmed:** that the 07:40:27Z slice reset the frontier again. At 07:39:02 it hadn't started. Re-check the `inventory_reconcile` row with read-only, indexed, sub-ms queries only (the worker's busy timeout is 100 ms).

## Implemented (uncommitted; builds; full suites NOT yet rerun after the last edits)

- `Sources/Coverage.swift`: `CoverageActivity` gains `lossDetected`, `timedOut`, `streamUnavailable` and `flushed` (set only after `FSEventStreamFlushSync` following HistoryDone). Coverage behavior is unchanged (`allGap` is still set).
- `Sources/InventoryCommands.swift`, `reconcileInventoryEvents` now returns an `InventoryEventReplay` and logs one `inventory events {...}` line per replay to `monitor.log`:
  - **Real loss** → full reconcile (unchanged).
  - **Many changed directories** → unlimited targeted invalidations. Memory is capped at `pathMemoryLimit` (262,144) by spilling durable chunks of 4,096. The cursor is acknowledged to the pre-stream marker only after every write succeeds; any write failure throws before acknowledgement.
  - **Replay not a completed boundary** (`inventoryReplayBoundaryComplete` = historyDone && flushed && !timedOut && !streamUnavailable) → apply what was seen, keep cursor and acknowledgement time, retry. The observed max ID is never used.
  - **Budget:** `inventoryReplayBudget(cursorAge:)` = clamp(age/60, 30…300 s). Retries leave the cursor age growing, so the budget grows before the 6 h expiry.
  - Test hooks: `simulateLoss`, `inventoryReplaySpillFault` (`INVENTORY_TESTS` only).
- No schema change, so existing catalogs need no migration.
- New tests:
  - `tests/InventoryReconciliationScenarios.swift` (shared harness);
  - `tests/InventoryReconciliationTests.swift` (loss classification, high volume, slow replay, retry keeps the acknowledgement time, boundary proof, budget, spill fault, overlapping gaps, completion marker preserved, no schema change, outside-root events, deletion/replacement/permission/mount, scenario assertions).
  - Both are registered in `scripts/test-inventory.sh` and `InventoryIntegrationTestMain`.
- `scripts/reconciliation-steady-state-verification.swift` prints the scenario JSON.

## In flight

A background run compiled both harness builds and runs them in sequence, writing to `build/inventory-reconciliation/`:
- the baseline (scratch copy with the original function, `…/scratchpad/baseline`) → `baseline.json`;
- the corrected build → `corrected.json`;
- completion is marked in `runs.done`.

`corrected.json` was compiled **before** the flush, budget and spill fixes, so rerun it.

## Next steps
1. Run `scripts/test-inventory.sh` (expect 189 + new checks) and fix any failures. The new tests use real FSEvents with 3 s settles and 12,000-directory fixtures, so expect a few minutes.
2. Rerun the corrected harness; compare against `baseline.json`. Compare listings, frontier resets, full reconciliations started, slices to idle, and catalog-matches-disk.
3. `scripts/build.sh`, then `self-test` (expect 209); `scripts/test-gui.sh` (expect 314); the GUI build with the 26.5 SDK; `scripts/build-dmg.sh` optionally.
4. Read-only check whether the 07:40/08:00 QA slices reset the frontier (`created_at` = slice start and a low `last_node_id`).
5. Write `INVENTORY-RECONCILIATION-STEADY-STATE.md` (root cause, evidence, invariant, changes, compatibility, results, limitations) and update `INVENTORY-VERIFICATION.md`.
6. Note for the docs: running workers (QA, production) keep the old code until restarted with a new build. QA needs explicit authorization to restart.

## Invariant to document
- The cursor advances only to a marker captured before the stream was created, and only after HistoryDone, a synchronous flush, and durable queuing of every changed directory.
- Otherwise the cursor and its acknowledgement time stay unchanged and history is replayed again.
- Only real loss signals schedule full reconciliation.
- A genuine overlapping loss still restarts the frontier (required for correctness). Directories listed after the new gap are skipped by `completed_sequence >= request_sequence`.
