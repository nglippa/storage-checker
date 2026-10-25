# Inventory reconciliation steady state

Recorded 2026-10-23, about 08:10 UTC. The correction is implemented and verified on fixtures and by tests. It is **not deployed**. The running QA worker and production still run the old code (see "Deployment status").

## Symptom

The fresh full-volume QA worker never finished its reconciliation. The `inventory_reconcile` frontier was reset at slice starts, so each 20-minute slice restarted most of the work instead of advancing.

## Root cause

`reconcileInventoryEvents` runs at every worker slice start. The old code scheduled a whole-volume "File-event gap" (`last_node_id` reset to 0 by a newer `request_sequence`) in any of these cases:

1. more than 4,096 distinct changed directories since the cursor (ordinary volume, not loss);
2. history replay not finished within a fixed 5 s;
3. stream unavailable;
4. genuine loss: dropped or wrapped events, root change, root rescan;
5. identity change, or a missing, regressed or expired (6 h) cursor.

Only case 4 (and case 5) means that file-event coverage was actually lost.

### QA evidence (read-only)

The catalog was inspected through APFS clones (`cp -c`) of the QA database, so the live worker saw no lock. FSEvents history was replayed read-only from the QA cursors by a scratch diagnostic that applies the inventory's own filtering and excludes the worker's own data directory. The diagnostic touches no database.

| Slice | Reconcile row re-requested | `request_sequence` | Window (event IDs) | Events | Distinct dirs | HistoryDone after | Out-of-order IDs |
|---|---|---|---|---|---|---|---|
| 07:40:27Z | 07:40:34Z, `last_node_id` 198,029 → 280 | 727,933 | 155139381 → 158363701 | 20,430 | 5,134 | 11.1–11.7 s | 64,056 inversions, jumps back up to 48,547 |
| 08:00:38Z | 08:00:45Z, `last_node_id` 280 | 731,569 | 158363701 → 162549024 | 19,931 | 2,697 | 7.0 s | 18,404 inversions, jumps back up to 41,299 |

Neither window carried any loss flag or MustScanSubDirs.

- **The 07:40 slice did restart reconciliation.** Both trigger 1 (more than 4,096 directories after about 1.1 s of replay) and trigger 2 applied.
- **The 08:00 slice restarted it again.** Only trigger 2 applied: there were too few directories for overflow, but HistoryDone came after 7 s, beyond the old 5 s limit.
- The old code logged nothing that distinguishes the triggers; they all share one reason string. The attribution above comes from replaying the same windows. The timings were measured after the fact on the loaded machine, so they are evidence, not a recording of the slices themselves.
- The earlier handoff concluded the timeout was "unlikely". That was wrong: its 1.1 s figure was the time to pass 4,096 paths, not the time to HistoryDone.

## Invariants (now implemented)

1. **Cursor boundary.**
   - The cursor advances only to a marker (`FSEventsGetCurrentEventId`) captured before the stream is created. It never advances to any observed ID.
   - A replay counts as a completed boundary only when HistoryDone arrives and a following `FSEventStreamFlushSync` returns (`inventoryReplayBoundaryComplete`).
   - Every event with an ID at or below the marker was generated before the stream existed, so HistoryDone plus the flush proves it was delivered, whatever order IDs arrived in.
   - Events are filtered per event (`cursor < id ≤ marker`), never by a running maximum.
   - An empty interval (marker == cursor) is trivially complete and is acknowledged.
2. **Memory limit without loss.**
   - Changed directories, and MustScanSubDirs subtrees, are collected without a count limit.
   - When `paths + subtrees` reaches `pathMemoryLimit` (262,144), they are written as durable invalidations in transactions of 4,096 and only then dropped from memory.
   - The cursor is acknowledged in a separate, final transaction after every write succeeded.
   - A write failure stops collection and throws before acknowledgement, so the same history is replayed next time.
   - A crash between the writes and the acknowledgement only duplicates invalidations. Duplicates are idempotent, and completed listings are skipped by `completed_sequence >= request_sequence`.
3. **No deferral into the six-hour expiry.**
   - An incomplete replay that is not loss (timed out or stream unavailable) applies what it saw and keeps both the cursor and its acknowledgement time.
   - The replay timeout now bounds a *stall*, not the replay. `replayCoverage(whileDelivering: true)` keeps waiting while events are delivered, and gives up only after `inventoryReplayBudget` (30 s, growing to 300 s with cursor age) with no delivery, or at the 30-minute guard ceiling (`inventoryReplayCeiling`).
   - A progressing replay is therefore never abandoned and redone. At the measured 7–12 s per 20 minutes of history, a full six-hour backlog needs a few minutes, an order of magnitude inside the ceiling.
   - A quiet volume is acknowledged on every slice, so its cursor never ages while the Mac is awake. (Correction, 2026-10-23: sleep longer than 6 h expired the wall-clock cursor. Cursor age now counts awake time within one boot session; see `STORAGE-MONITOR-INSTALL-READINESS.md` §1–2.)
   - Only persistent FSEvents failure — no delivery at all, a stream that cannot be created, or a replay longer than 30 minutes, on every slice for six hours — reaches the expiry. A full reconciliation is then the correct response.
4. **Only real loss schedules full reconciliation.** That means dropped or wrapped events, root change or root rescan, identity change, and an expired or regressed cursor. A genuine overlapping loss still restarts the frontier, which correctness requires.

Coverage (the monitor) keeps its wall-clock replay deadline and treats every incomplete replay as a gap, as before.

## Changes

- **`Sources/Coverage.swift`:**
  - `CoverageActivity` gains `lossDetected`, `timedOut`, `streamUnavailable`, `flushed` and `lastDelivery`.
  - `replayDeadline` is a new pure function.
  - `replayCoverage(…, whileDelivering:, ceiling:)` sets `flushed` only after `FSEventStreamFlushSync`, or for an empty interval, and marks a failed `FSEventStreamStart` as unavailable.
- **`Sources/InventoryCommands.swift`:**
  - `reconcileInventoryEvents` classifies each replay as `applied`, `retry`, `gap` or `identity`.
  - It spills to bounded durable invalidations, acknowledges last, and logs one `inventory events {…}` line per replay to `monitor.log`.
  - Test hooks under `INVENTORY_TESTS` only: `simulateLoss`, `inventoryReplaySpillFault`.
- **No schema change.** Existing catalogs need no migration; a test asserts this.

## Results

- **Inventory integration tests:** `scripts/test-inventory.sh` passes all **221** (`build/inventory-reconciliation/inventory-tests.log`). The run includes checks for:
  - loss classification;
  - 4,500 changes with forced spilling;
  - a slow replay keeping the cursor and its acknowledgement time;
  - a spill fault acknowledging nothing, then the replay being applied;
  - a boundary that is not proven by the largest observed ID;
  - the stall-bounded deadline;
  - a quiet interval being acknowledged;
  - overlapping genuine losses;
  - deletion, replacement, permission and mount changes;
  - no schema change.
- **Monitor build and self-test:** `scripts/build.sh` succeeds; `self-test` passes all **209**.
- **Viewer:** `scripts/test-gui.sh` passes all **314**, and the viewer builds with the 26.5 SDK.
- **DMG:** not rebuilt in this pass.

### Before/after fixture comparison (12,000-folder fixtures, `build/inventory-reconciliation/{baseline,corrected}.json`)

| Scenario | Full reconciliations (before → after) | Listings (before → after) | Slices to idle | Catalog matches disk |
|---|---|---|---|---|
| 4,500 changed folders | 1 → **0** | 12,025 → **4,500** | 5 → 2 | yes → yes |
| Slow replay, 50 changes | 1 (timeout) → **0** | 12,025 → **50** | 5 → 2 | yes → yes |
| Sustained 6 × 4,200 changes | 6 → **0** | 13,745 → 18,726 | 14 → 12 | yes → yes |
| Genuine loss + interruption + second loss | 1 → 1 (required) | 12,269 → 12,269 | 12 → 12 | yes → yes |
| Changes behind and ahead of frontier | 0 → 0 | 12,025 → 12,025 | 10 → 10 | yes → yes |

The sustained scenario changes about 35% of all fixture folders in every slice. There, relisting each changed folder costs more listings than the old single coalesced pass (+36%), although no full reconciliation starts and it reaches idle in fewer slices. On the QA volume (about 2.9 M directories, 3–5 k changed per 20 minutes) the targeted path is orders of magnitude cheaper than a full pass. The old pass in practice never finished, because it kept being reset. Wall-clock seconds differ between the two runs because the QA worker was loading the machine; they are not comparable.

## Deployment status and limitations

- The QA worker (`local.macbook.storage-monitor.inventory-qa`) and any production worker keep the old code until restarted with a new build. **Restarting QA requires explicit authorization; it was not done.** Until then QA will keep resetting its frontier at most slice starts.
- The correction has not been observed on the real full volume. After an authorized upgrade, verify it from the `inventory events` lines in `monitor.log` (expected: `applied` or `retry`, not `gap`) and a frontier that advances across slices.
- The boundary proof relies on documented FSEvents semantics: HistoryDone marks the end of historical events, and `FSEventStreamFlushSync` delivers pending ones. It is tested against real FSEvents on fixtures. No test can make macOS deliver events late on demand.
- The fixtures are synthetic and bounded. They do not establish customer-scale initial-index speed, which remains a release blocker per `INVENTORY-VERIFICATION.md`.
