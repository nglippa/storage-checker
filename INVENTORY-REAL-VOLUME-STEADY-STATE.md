# Inventory real-volume steady state (QA)

**Assessment: PASS for the three-slice upgrade verification. Steady state at rest (idle) has not yet been observed.**

The corrected worker (candidate 2) ran three complete 1,200 s slices on the existing QA catalog of about 3.0 million entries. There were:
- no false full-volume restarts;
- no replay timeouts or gaps;
- no errors.

The bounded reconciliation pass started by the old code at 11:43:03Z **completed** during slice 3. This is one real-volume result on one Mac and does not by itself establish beta readiness.

## Upgrade record (2026-10-23, UTC; authorized by the user for QA only)

| Time | Step | Result |
|---|---|---|
| 16:06:22 | Preflight; wrote `R/data/inventory.cancel` | Old executable `25c49e96…`, candidate `0525bdf6…`, `supervise.py` `7a25f8f9…`, plist `6caea476…` all verified |
| 16:06:26 | Old worker exited | `slice_end` exit 0 after 128 s; log `outcome interrupted, reason cancelled`; launchd `not running`, last exit 0, **no relaunch** |
| 16:06:37 | `launchctl bootout gui/501/local.macbook.storage-monitor.inventory-qa` | rc 0; no QA process; production labels untouched |
| 16:07:06–10 | `sqlite3 .backup` to `U/qa-pre-upgrade/history.sqlite3` (3.3 s) | `integrity_check` ok; row-for-row equal to live (frontier 2,265,190, `request_sequence` 1,127,814, 3,017,980 nodes); SHA-256 `cebf7444d4aaffb4550952c9eba5ac8e04c1e6769427e4a78dba7982df1a2b8b`. Old app bundle, plist, `supervise.py`, `run.json`, `started.json`, samples and logs preserved; hashes in `U/qa-pre-upgrade/SHA256SUMS` |
| 16:08 | Executable swap and ad-hoc re-sign with identifier `local.macbook.storage-monitor.inventory-fresh-qa` | Before signing `0525bdf6…` ✓; after signing `0c24644ffc01f006…` ✓ (matches rehearsal); `codesign -v --strict` valid |
| 16:08:23 | `inventory-resume`, then `launchctl bootstrap` of the original plist | Pause file removed; one supervisor and one worker; launchd `runs = 1` |

Pre-upgrade cursor: 184097686. Generation 1 was `paused`/`cancelled`, and the migration columns were absent.

## Observation: three complete corrected slices

| Slice (pid) | Ended | Exit | Replay at slice start | Entries / directories | CPU avg / max | RSS max | Database |
|---|---|---|---|---|---|---|---|
| 1 (79929) | 16:28:30 | 75 | `applied` 3,474 events, 461 paths, 0.14 s | 1,137,237 / 38,218 | 67 % / 85 % | 77 MiB | 1,468.9 → 1,472.3 MB |
| 2 (21115) | 16:48:37 | 75 | `applied` 6,729 events, 591 paths, 0.95 s | 265,311 / 82,832 | 60 % / 87 % | 49 MiB | 1,472.5 → 1,483.5 MB |
| 3 (61785) | 17:08:46 | 75 | `applied` 5,494 events, 818 paths, 1.76 s | 111,136 / 32,840 | 67 % / 95 % | 72 MiB | 1,483.7 → 1,486.6 MB |
| 4 (99655, running) | — | — | `applied` 3,322 events, 333 paths, 0.96 s | — | — | — | — |

CPU is the `ps` figure for one core, sampled every 15 s at nice 15 and low I/O priority. `worker.stderr.log` is empty. Free disk stayed at 24–26 GB.

### Reconciliation frontier and cursor (APFS clones; `quick_check` ok on every clone)

| Snapshot | Frontier (`last_node_id` of 2,980,782) | `created_at` / `request_sequence` | Cursor |
|---|---|---|---|
| Backup, pre-upgrade | 2,265,190 | 11:43:03Z / 1,127,814 | 184097686 |
| 16:09:37 | 2,265,469 | unchanged | 184153661 |
| 16:28:35, after slice 1 | 2,605,355 | unchanged | 184824351 |
| 16:48:46, after slice 2 | 2,902,283 | unchanged | 186043505 |
| 16:58:59, mid slice 3 | **row absent: pass complete** | — | 186043505 |
| 17:08:53, after slice 3 | absent | — | 186700256 |

- The reconcile row is deleted only by `expandInventoryReconcile` (`Sources/Inventory.swift:1372`), and only when no directory candidates remain at or below `end_node_id`.
- No new row was inserted, so no new gap occurred.
- **Migration:** additive, applied at startup. `initial_completion` = `complete`, recorded at 16:09:00Z.
- **Catalog:** nodes 3,018,605 → 3,027,925 → 3,023,590, reflecting real file changes and tombstone processing.
- **Invalidations queue:** 0 at every snapshot.
- **Generation 1:** stays `building`, as expected while jobs remain.

Three snapshots labelled 16:39:57–16:40:41 were retaken when the observer was restarted after its 30-minute monitor limit. They are not boundary snapshots; their values are consistent with the rows above.

## Success criteria

| Criterion | Status |
|---|---|
| No false-gap restarts | **PASS**: 4 replays, all `applied`, 0 gaps or timeouts; `created_at`/`request_sequence` unchanged until the pass completed |
| Existing progress survives the upgrade | **PASS**: frontier 2,265,190 preserved and advanced; catalog, cursor and generation not reset |
| Cursor advances safely | **PASS**: 184097686 → 186700256, monotonic, acknowledged at each slice boundary |
| Targeted invalidations processed | **PASS**: 333–818 changed paths per replay; invalidations queue drained (0) |
| Inventory consistent | **PASS**: `quick_check` ok on every clone; backup `integrity_check` ok |
| Bounded resources | **PASS**: RSS ≤ 77 MiB (guard 512 MiB); database grew 17.7 MB over 3 slices |
| Reconciliation pass completes | **PASS**: completed during slice 3; it had restarted five times under the old code |
| Reaches idle | **NOT VERIFIED**: slice 3 ended with 0 pending; event-driven jobs (139) were queued for slice 4 |
| Production unchanged | **PASS**: all four recorded hashes unchanged |

## Remaining

- Observe until the worker reaches idle (`complete` outcome, generation leaves `building`), and then a few event-driven slices at rest.
- Rollback is available from `U/qa-pre-upgrade/`, but restoring that database now would discard newer writes. It should be considered only after deciding it is safe.
- Nothing was installed, rebuilt, committed or pushed.
