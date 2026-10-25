# Inventory steady-state verification (QA, real volume)

**Current verdict (candidate 3, 2026-10-23 19:57 UTC): PASS.** See [§8](#8-candidate-3-upgrade-and-verification).
- **Remaining maintenance:** finished in one 637 s run.
- **Chrome cache retries:** capped at 3 per run.
- **Cleanup backlog:** 405 tombstone claims drained within that run.
- **Background idle:** genuine, at 0 CPU between runs.
- **Run cost:** each triggered run takes 31–40 CPU-seconds and finishes well inside its budget.
- **Deferred work:** the Chrome cache stays durably pending and is retried on every later run.

§1–7 below are the original candidate 2 investigation and are kept as the "before" record.

**Candidate 2 verdict: FAIL.** Correctness held, but two reproducible defects keep the corrected worker permanently busy, so it never settles:
- **No correctness damage:** no false gaps, no resets, no lost progress, the cursor advanced, and `quick_check` passed on every clone.
- **Busy without stopping:** about 0.7–0.8 CPU-seconds per second (70–85 % of one core) through every 1,200 s slice, and that does not change as the backlog drains.
- **Two causes, both fixed in source and tested:** a continuously written Chrome cache directory relisted until each budget expires, and a cleanup query that scans every job for each tombstone claim.
- **QA still runs the unfixed binary:** deploying the fix needs a new QA binary and your explicit authorization.

Observed 2026-10-23, 17:49–18:40 UTC, read-only: QA was never stopped, signalled or written to. Database measurements come from APFS clones. One 10 s `sample` stack capture was taken, which does not stop the process.

## 1. Current QA state (18:40 UTC)

| Item | Value |
|---|---|
| Supervisor / worker | pid 69553 / 69554 (corrected candidate 2, executable SHA `0c24644f…`); slice started 18:29:29; 542 CPU-s in its first 643 s |
| Inherited reconciliation | **Complete.** The `inventory_reconcile` row (created 11:43:03Z, `request_sequence` 1,127,814) was deleted between 16:48:46 and 16:58:59. The only code that deletes it (`expandInventoryReconcile`) runs only once no candidates remain at or below `end_node_id` 2,980,782. |
| New full reconciliations | **None:** no reconcile row in any of 6 clone snapshots since 16:58 |
| FSEvents | 9 replays since the upgrade, all `applied`, 0 gaps; cursor 186,910,231 (17:51) → 190,560,498 (18:29) |
| Pending jobs / invalidations | 0–1 pending (the Chrome cache directory); invalidations 0 at every snapshot |
| Cleanup backlog (18:30 clone) | 91 prune jobs (78 fully scanned, `last_node_id = -1`), 200 tombstones with 200 claims, 214 stale nodes |
| Database | 1,486,643,200 bytes, unchanged since 17:08 because freed pages are reused; `quick_check` ok |
| Errors | `worker.stderr.log` empty; every slice exited 75 (budget expired) |
| Production | all four recorded hashes unchanged |

## 2. Per-cycle measurements

CPU-seconds are the worker's cumulative `ps` time at its last 5 s sample before exit. That is a measured total, distinct from the 15 s instantaneous `cpu_percent` samples.

| | Cycle A (pid 75282) | Cycle B (pid 29020) | Earlier (pids 99655, 39586) |
|---|---|---|---|
| Start → end | 17:48:58 → 18:09:15 (1,217 s) | 18:09:15 → 18:29:29 (1,213 s) | 17:08:46 → 17:48:58 |
| Exit / why | 75: **budget expired** | 75: **budget expired** | 75 / 75: budget |
| Replay at start | `applied` 3,310 events, 510 paths, 0.17 s | `applied` 15,032 events, 1,575 paths, 7.24 s | `applied` 2,992/311 and 3,310/510 |
| Listings completed / entries read | 188 / 43,500 | 1,486 / 2,024,616 | 315 / 1,441,053 and 306 / 1,460,320 |
| Pending at end | 0 | 1 | 1, 1 |
| Reconcile rows before → after | 0 → 0 | 0 → 0 | 0 |
| **CPU time** | **1,000 s** (82 % of wall time) | **881 s** (73 %) | — |
| Instantaneous CPU, average | 84 % | 72 % | — |
| Peak RSS (`peak_memory_bytes`) | 27.6 MB | 42.2 MB | 92.4 / 89.4 MB |
| Database growth | 0 bytes | 0 bytes | 0 bytes |
| Chrome cache relists (`attempts` Δ) | **0** | **+226** | — |

The test suites also ran during cycles A and B. That competes for wall-clock throughput, but per-process CPU time is unaffected.

## 3. What the worker is doing

### Defect 1: a continuously changing directory is relisted until the budget expires (category E, driven by C)

- **Directory:** node 197550 = `~/Library/Caches/Google/Chrome/Default/Cache/Cache_Data`, with 29,672 files.
- **Evidence:** in the job record, `attempts` went 1,418 (pre-upgrade backup, 16:06) → 1,752 (17:50) → 1,978 (18:29), and `listing_token` 2,862 → 3,536 → 3,989. Each restart re-queues the parent too: `Cache`'s `listing_token` 1,426 → 1,986.
- **Rate:** 226 restarts in cycle B alone, about one every 5 s. That cycle read about 2 million entries to deliver around 1,500 real listings.
- **Mechanism:**
  - `readInventoryBatch` returns `.changed` when the directory's mtime or ctime moves between batches, and Chrome writes faster than a 29,673-entry listing finishes.
  - `restartInventoryJob` puts the job straight back to `pending`.
  - `nextInventoryJob` picks it again whenever nothing else is queued.
  - There is no attempt limit and no deferral, so the loop ends only at the deadline.
- **Not new:** the old code had already restarted this directory 1,418 times.

### Defect 2: tombstone cleanup scans the whole job table per claim (category F: query plan)

- **Cycle A:** the Chrome cache was quiet (Δ attempts 0, `listing_token` unchanged), and only 188 directories were listed, yet the worker burned 1,000 CPU-s with 0 pending jobs.
- **Stack sample:** a 10 s `sample` of the live worker at 18:31 put **859 of 859** main-thread samples in `processInventoryTombstones` → `inventoryClaimIsAuthoritative` → one `sqlite3_step`, spending its time in B-tree page walks and `pread`.
- **Query plan:** `EXPLAIN QUERY PLAN` on a clone shows the "newer descendant observation" query plans `SCAN j`, a full scan of 480,000 `inventory_jobs` rows. The short recursive ancestor chain is only used as a Bloom-filtered probe.
- **Cost:** measured on the clone, 0.34 s per call; the same query with `CROSS JOIN` runs in 0.0001 s and returns the same result. The leaf step checks up to 256 claims per call, so one call can cost about 87 s.
- **Attribution:** the stack sample comes from the 18:31 slice. Attributing cycle A's 1,000 CPU-s to this same path is an inference from it listing almost nothing with tombstones outstanding.
- **Amplification:** each Chrome-cache relisting that completes finds deleted cache files, which feed this cleanup with new prune jobs and claims.

### Not found
- **No unnecessary full reconciliation (A):** none since the inherited pass completed.
- **Targeted FSEvents maintenance (B):** working as designed, and cheap: 0.17–7.24 s per replay for 311–1,575 changed folders.
- **No stalled jobs (E):** nothing beyond the Chrome directory.

## 4. Steady-state test

| Criterion | Result |
|---|---|
| No unnecessary full-volume reconciliation | **PASS** |
| No persistent unbounded job backlog | **PASS** for listings (0–1 pending). Cleanup backlog not shown to drain: 91 prune jobs / 200 claims at 18:30. |
| No repeated listing of unchanged directories without cause | **FAIL**: the Chrome cache is relisted about 226 times per slice; it does change, but no listing can ever complete |
| Cursor advances safely | **PASS** |
| Ordinary changes trigger targeted maintenance | **PASS** |
| Little CPU when there is no meaningful work | **FAIL**: 881–1,000 CPU-s per 1,200 s slice; never exits idle (exit 0) |
| Memory bounded | **PASS**: 27–92 MB peak |
| Database growth explainable | **PASS**: 0 bytes over the last 4 slices (page reuse) |

The worker never reached idle, so a post-idle cycle could not be observed.

## 5. Corrections in source (not deployed)

1. **Changed-directory deferral** (`Sources/Inventory.swift`, `runInventory`):
   - After `inventoryChangedRetryLimit` (3) changed-restarts in one run, the directory is excluded for the rest of that run, from both normal selection and focus selection.
   - It stays durably `pending`/`stale`, so nothing is falsely reported complete.
   - If only deferred work remains, the run reports `inventoryDeferredReason`, and `inventory-work` exits 0, just as it does for a cancel (`Sources/InventoryCommands.swift`). launchd then lets it idle, and the next run or event retries the directory.
2. **Cleanup query plan** (`inventoryNewerObservationSQL`): the same SQL with `CROSS JOIN`, which in SQLite keeps the ancestor chain as the outer loop. It has identical inner-join semantics.

### Regression tests (`tests/InventoryReconciliationTests.swift`)

- **Continuously changing directory:** a real 4,000-file directory is churned every 0.5 ms during listing.
  - With the fix: exactly 3 retries, then deferred, durably pending and stale. Once quiet, the next run is `complete` and the catalog matches disk.
  - With deferral disabled (temporary environment switch, since removed): **FAIL**, 105 retries and no deferral.
  - In the fixture, the unfixed loop got one clean listing after 0.4 s. On the real volume a 29,673-entry listing never does, so the test asserts that retries are bounded, not that the run times out.
- **Cleanup-authority plan:** asserts `SEARCH j USING INTEGER PRIMARY KEY` and no `SCAN j`. At fixture scale the old SQL plans `SCAN j` (checked on a scratch database with the same schema), so the test detects the regression.

### Suites

| Suite | Result |
|---|---|
| `scripts/test-inventory.sh` | **225 passed**: the previous 221, plus 3 deferral checks and 1 plan check |
| `scripts/build.sh` + self-test | **227 passed** |
| `scripts/test-gui.sh` | not run: no viewer sources changed (`SourcesGUI` does not compile `Inventory.swift`) |

**A new QA binary is required** to verify either fix on the real volume. Nothing was deployed. The dev build at `build/MacBook Storage Monitor.app` contains both fixes; it is unsigned for QA and was not installed.

## 6. Remaining operational risks

- **Cleanup at scale is otherwise unmeasured:** the plan fix removes the per-claim scan, but tombstone volume driven by browser caches still needs one real-volume observation.
- **Deferral semantics:**
  - A permanently churning directory stays `stale`, and the generation stays `building`, while that browser is running. That is truthful, but the viewer should explain it.
  - The QA plist has no periodic trigger. After an exit 0, maintenance resumes only on a request or a reload, and long idle gaps can outlive FSEvents history, which would force a genuine gap reconciliation.
- **Full Disk Access:** 46,749 directories are `unknown` in QA (FDA not granted), so the terminal outcome there would be `partial`, not `complete`.
- **Memory:** 92 MB peak RSS earlier in the day, versus the supervisor's 512 MiB guard.

## 7. Recommendation for the next milestone

1. With your authorization, deploy the fixed build to QA only, using the same pause → bootout → backup → swap → re-sign → resume sequence (`QA-EXECUTION-AUTHORIZATION.md` §7). Then observe until the worker exits 0, and for several cycles after that, with Chrome running.
2. Exit criteria for steady state:
   - an exit-0 run;
   - Chrome cache relists ≤ 3 per run;
   - cleanup tables draining;
   - CPU time per run proportional to replayed changes.
3. Then decide production scheduling, a periodic trigger with idle-safe FSEvents retention, and the viewer's wording for "deferred: changing continuously".

Do not claim beta readiness until a real-volume run has reached idle and stayed low-resource.

## 8. Candidate 3 upgrade and verification

### Review and build

Both fixes were reviewed against the requested properties:
- **Retry limit:** at most 3 unstable attempts per directory per run, held in run-local state only.
- **Deferred work is durable:** the directory stays `pending`/`stale` and is never marked complete.
- **No starvation:** only the deferred node is excluded, from both normal and focus selection.
- **Exit 0 only when drained:** the deferred reason is set only once invalidations, reconcile and tombstones are all empty.
- **Events are not lost:** a deferred run skips the final replay, so its events are replayed by the next run.
- **SQL:** `CROSS JOIN` only fixes the join order and keeps inner-join semantics.

Tests were strengthened:
- the plan assertion accepts both SQLite wordings, `SCAN j` and `SCAN TABLE j`;
- the old and new SQL are compared directly: 180 comparisons, 60 non-zero, 0 mismatches;
- a stable directory changed in the same interval is shown to be listed while the unstable one is deferred.

| Item | Value |
|---|---|
| Source | HEAD `46cd268` plus working tree; fingerprint `24a37c86f09392a584b9daf05d6dd1483622fabfaccc1c53b8276f121aca7e0a` (`U/source-fingerprint-candidate3.txt`); only `Inventory.swift` and `InventoryCommands.swift` differ from candidate 2 |
| Build | `scripts/build.sh`: `swiftc -O -target arm64-apple-macos14.0`, Swift 6.4 |
| Tests | inventory **227/227**; monitor self-test **227/227** |
| Candidate 3 executable | `15feba0a0cd3b1d8a9f06f79db2f54f8f84cd6623c91d85dc6ed83557c964115`, byte-identical to the tested build |
| After QA re-sign (`local.macbook.storage-monitor.inventory-fresh-qa`) | `e8e5600811da1293ac9bb9a394c8523d1527492129baad9a1288e4879d27b67f`; rehearsed twice, `codesign -v --strict` valid |
| Previous QA executable | `0c24644f…90007e` (candidate 2), preserved in `U/qa-pre-upgrade-candidate3/` |

### Upgrade (user-authorized, QA only; nothing was denied)

| Time (UTC) | Step | Result |
|---|---|---|
| 18:59:54 | Pause file written | Worker exited at 18:59:58: exit 0, `reason cancelled`, no relaunch |
| 19:00 | `bootout` of the QA label; `.backup` to `U/qa-pre-upgrade-candidate3/` | `integrity_check` ok and equal to live; SHA-256 `63f6955e…`. Old app, plist, supervisor, run metadata, samples and logs preserved (`SHA256SUMS`). |
| 19:00:5x | Swap and re-sign | Hash `15feba0a…` before signing and `e8e56008…` after; signature valid |
| 19:01:06 | `inventory-resume`, then `bootstrap` of the original plist | Pause file removed; one supervisor and one worker |

State at the upgrade, from the backup:
- no reconcile row; cursor 194520025;
- 3,006,175 nodes; all jobs complete;
- 405 tombstones, 405 claims, 90 prune jobs, 205 stale nodes;
- Chrome cache `attempts` 1,985.

### Measured cycles

CPU time is the worker's cumulative `ps` time at its last 5 s sample before exit.

| Run (pid) | Trigger | Wall time | CPU time | Exit | Replay | Listings / entries | Chrome retries (`attempts`) | Pending at end | Peak RSS |
|---|---|---|---|---|---|---|---|---|---|
| 1 (45223) | bootstrap | **637 s** | **452 s** | 75 | `applied` 3,945 ev / 559 paths, 0.38 s; the final replay found 526 more | 277 / 74,038 | 1 | 139 (from the final replay) | 74.6 MB |
| 2 (71960) | launchd, 10 s after exit 75 | **23 s** | not sampled | **0** | `applied` 20 ev / 12 paths | 278 / 37,398 | 3 → deferred | 1 (Chrome cache) | 26.4 MB |
| idle | — | 21.7 min | **0** | — | — | — | — | 1 | — |
| 3 (32557) | manual `inventory-resume` | **76 s** | **39.8 s** | **0** | `applied` 6,781 ev / 1,196 paths, 0.39 s | 1,955 / 59,800 | 3 (1,990 → 1,993) → deferred | 1 | 29.6 MB |
| idle | — | 20.4 min | **0** | — | — | — | — | 1 | — |
| 4 (20138) | manual `inventory-resume` | **57 s** | **31.5 s** | **0** | `applied` 5,185 ev / 1,883 paths, 0.75 s | 801 / 58,810 | 3 (1,993 → 1,996) → deferred | 1 | 28.3 MB |

Notes on run 1:
- Its main loop drained all work, returning complete or partial. That triggers the designed final replay, which queued 526 changed folders and ended the run with exit 75.
- Run 2 processed those folders and exited 0.
- Run 1's 452 CPU-s was mostly cleanup: by the 19:12 snapshot, tombstones were 405 → **0**, claims 405 → **0**, prune jobs 90 → **0**, and stale nodes 205 → 10.

Correctness checks:
- **Deletions confirmed on disk:** all 405 claim roots no longer exist on disk (read-only `lstat`). Most were test fixtures under `/private/tmp` from this session's suites, plus scratch folders and a few `~/.codex*`/`~/.agents` entries. The catalog went 3,006,175 → 2,893,881 nodes because those subtrees were really deleted, not because inventory was lost.
- **Replays:** all 14 since the first upgrade were `applied`.
- **Reconciliation:** no reconcile row in any snapshot, so no full reconciliation.
- **Database:** `quick_check` ok on every clone, `worker.stderr.log` empty, file size unchanged (page reuse).

### Before and after

| Measure | Candidate 2 (before) | Candidate 3 (after) |
|---|---|---|
| CPU per run | 881–1,000 s per 1,200 s slice, every slice | 452 s (one-off backlog drain), then **31.5–39.8 s** |
| Run length | always the full 1,200 s budget | 637 s, 23 s, 76 s, 57 s |
| Exit | always 75; never idle | **0** after maintenance; launchd does not relaunch |
| CPU between runs | none (it never stopped) | **0**, over 21.7 and 20.4 min idle windows |
| Chrome cache relists | up to 226 per slice | **≤ 3 per run** |
| Cleanup backlog | 91 prune jobs and 200 claims, not draining | **0 / 0** within the first run |
| Replays | applied | applied (1,196–1,883 paths in 0.39–0.75 s) |

### Specific checks

| Check | Result |
|---|---|
| A. Chrome `Cache_Data` cannot monopolize a slice | **PASS**: exactly 3 retries per run, then deferred; runs end in 23–76 s |
| B. Tombstone query avoids the full job scan | **PASS**. Evidence: plan test (`SEARCH j … PRIMARY KEY`, no `SCAN j`), result equivalence, and 405 claims drained in one run where candidate 2 made no measurable progress. The live stack sample was not repeated, because runs are now too short to catch cleanup in progress. |
| C. Deferred directories stay pending and are retried | **PASS**: `pending`/`stale` after every run; retried in runs 3 and 4 (`attempts` +3 each) |
| D. A quiet cycle finishes before the 1,200 s budget | **PASS**: 23 s, 76 s, 57 s |
| E. A completed cycle does not trigger an immediate restart | **PASS**: no process, launchd `runs` unchanged and no log lines for 21.7 and 20.4 minutes after exit 0 |

### Caveats (not blockers for this verdict)

- **No schedule in QA:** the QA plist starts a run only on `RunAtLoad` or `WatchPaths`. Runs 3 and 4 were started by hand with the authorized `inventory-resume`. A production scheduling policy, with a periodic trigger that respects FSEvents history retention, is still undecided.
- **Chrome cache stays stale:** while Chrome is writing, `Cache_Data` remains `stale` and the generation remains `building`, with reason `deferred: a directory kept changing during listing`. This is truthful, but the viewer should present it clearly.
- **Partial coverage without Full Disk Access:** QA has no FDA, so 434 directories are unknown and the terminal outcome would be `partial`.
- **Short sample:** one afternoon on one Mac. This is not a beta-readiness claim.

Production was unchanged throughout (all four hashes verified at 19:57 UTC). Nothing was installed, rebuilt as a DMG, committed or pushed.
