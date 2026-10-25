# QA inventory worker upgrade — approval request

Prepared 2026-10-23, about 11:45 UTC. Nothing described under "Proposed upgrade sequence" has been done. Real-volume verification of the corrected worker is **not** complete: it has never run against the QA catalog.

## 1. Current QA status (read-only, 11:26–11:40 UTC)

| Item | Value |
|---|---|
| launchd job | `local.macbook.storage-monitor.inventory-qa`, loaded from `build/inventory-fresh-20261023T031313Z/inventory-worker.plist` (not `~/Library/LaunchAgents`) |
| Policy | `RunAtLoad`, `KeepAlive {SuccessfulExit=false}` (relaunch only after a non-zero exit), `ThrottleInterval` 10, `WatchPaths` = `data/inventory-requests` |
| Supervisor | `/usr/bin/python3 …/supervise.py`, pid 70185 at 11:26; launchd `runs = 29`, last exit 75 |
| Worker | pid 70188: `Storage Inventory Fresh QA Worker.app/Contents/MacOS/StorageMonitor inventory-work --data-dir …/data --budget 1200 --batch 256` |
| Slice cadence | 1,200 s of worker time; every slice exits 75 (`interrupted`) and is relaunched. Since 09:21 the Mac has slept between and during slices, so wall-clock slices run 20–30 min. |
| Database | `…/data/history.sqlite3`, 1,433,157,632 bytes, rollback-journal mode; `quick_check` ok (on a clone) |
| Generation | 1, `building`, active, event history available |
| Catalog | 2,973,086 nodes; jobs: 462,051 complete, 14 pending; 103 prune jobs; 0 queued invalidations |
| Reconciliation | One full-volume pass (old-code "File-event gap"), requested at 09:01:52Z. Frontier 631,335 at 11:26 → 1,109,351 at 11:39, of `end_node_id` 2,977,641. |
| Event cursor | 174520384, acknowledged 11:22:51Z (that slice's start) |
| Errors | `worker.stderr.log` empty; no error lines in `monitor.log` |
| Isolation | Own app copy, data directory, plist and logs under the run directory. Production agents `local.macbook.storage-monitor` and `.baseline` are loaded but idle, and production data is in `~/Library/Application Support/MacBook Storage Monitor/`. No production inventory agent exists. |

**Is the old worker still restarting reconciliation?**
- **Confirmed:** resets at 07:20, 07:40, 08:00 and 09:01 slice starts.
- **Not observed since 09:01:52Z:** no reset across the 09:21, 09:42, 10:12, 10:35, 11:00 and 11:22 slices. Activity was lower, with the Mac partly asleep, and each replay finished inside the old 5 s limit and below 4,096 changed folders.
- **Unknown:** the 08:20 and 08:40 slices. Only the latest request is retained in the row.
- The old code resets under ordinary load, not on every slice. At the 11:26–11:39 rate, the current pass could finish within roughly an hour if no further reset occurs. That is an estimate, not a measurement of completion.

## 2. Corrected binary identity

| Item | Value |
|---|---|
| Candidate | `build/inventory-qa-upgrade-20261023/candidate-2/MacBook Storage Monitor.app` (preserved copy, so later builds cannot overwrite it) |
| Executable SHA-256 | `0525bdf66353c2af6c6dcd516985bfdfdb9fd30938c9f8901298ef6d19b20307` |
| Built by | `scripts/build.sh` from the current working tree. HEAD `46cd268` does not describe it: the tree is uncommitted. |
| Source fingerprint | `ee19777d…` = SHA-256 of `source-fingerprint-candidate2.txt` (per-file SHA-256 of `Sources/*.swift`, `SourcesShared/*.swift`, `scripts/build.sh`) |
| Contains | Corrected FSEvents reconciliation (loss vs. volume, durable spilling, marker-only acknowledgement, quiet-interval acknowledgement, stall-bounded replay) and the transactional installer, including the two installer fixes in §8 |
| Self-test | 227 passed (`candidate-2/self-test.log`) |
| Superseded | Candidate 1 (`16ccdb17…`, 08:16 UTC) predates the installer work and is not proposed. Its replay code is identical: the only later change to `InventoryCommands.swift` is a test-only switch. |

Old QA executable: `25c49e962af3fa4900ce7f8a3e1c8288a3b9573f990e0bbbdd95a1f5cce4822e`, prepared 03:13 UTC. QA plist `6caea476…`, `supervise.py` `7a25f8f9…`. All three were re-verified unchanged at 11:39.

## 3. Database compatibility

This was a dry run on an APFS clone of the live QA database taken at 11:39:51Z, using a scratch harness compiled from the candidate's sources. Nothing was written to QA.

- **The upgrade does migrate.** The QA catalog predates the first-pass completion lifecycle. The candidate's migration is additive and took 0.89 s on the clone:
  - `inventory_generations` gains `initial_completion TEXT NOT NULL DEFAULT 'unknown'` and `initial_completed_at REAL`;
  - a partial index `inventory_jobs_first_listing` is added;
  - nothing is removed or rewritten. Generation 1, its nodes, jobs, frontier and cursor are preserved.
- **First replay from QA's cursor:** `applied` in 3.26 s. It processed 126,722 events in 1,545 changed folders, queuing 1,544 targeted invalidations and no gap. The event count includes test-fixture churn on this Mac during the window.
  - The reconcile row was unchanged: `last_node_id` 1,109,351, `request_sequence` 949,838, same `created_at`. So the existing pass **continues**; it is not restarted.
  - The cursor moved to the pre-stream marker; `quick_check` ok after both steps.
- **Initial completion** reads `unknown` after migration until the candidate worker confirms it from durable state. With a reconciliation pending it should stay unknown until that pass finishes. Not verified on the real catalog.
- **Not exercised in the dry run:**
  - directory listings (no filesystem walk was run, by design);
  - prune and cleanup authority;
  - focus and refresh requests;
  - completion confirmation.
  These are covered only by the 221 inventory fixture tests.

## 4. Proposed upgrade sequence (QA only)

`R` = `build/inventory-fresh-20261023T031313Z`, `U` = `build/inventory-qa-upgrade-20261023`, uid 501.

1. **Preflight (read-only).** Re-verify the old QA hashes and the candidate hash. Confirm exactly one supervisor and one worker from `R`, and record the reconcile row and cursor through an APFS clone.
2. **Pause at a batch boundary.** Write `R/data/inventory.cancel` (`cancel\n`, mode 0600). This is exactly what the project's `inventory-cancel` command writes; the worker checks it between committed batches.
   - Expect a `slice_end` with exit code 0. launchd then does not relaunch, because of `SuccessfulExit=false`.
   - Do **not** use `inventory-request pause`: it also writes a request file into the watched directory, which makes launchd start the supervisor.
3. **Unload the QA job:** `launchctl bootout gui/501/local.macbook.storage-monitor.inventory-qa`. This removes the `WatchPaths` trigger. Verify that no `supervise.py` or worker process remains for `R`.
4. **Recovery point.**
   - Run `sqlite3 R/data/history.sqlite3 ".backup 'U/qa-pre-upgrade/history.sqlite3'"`, which uses SQLite's backup API; nothing is writing at this point.
   - Run `PRAGMA integrity_check` on the backup (several minutes for about 1.4 GB) and record its SHA-256.
   - `ditto` the old QA app, plist, `supervise.py`, `run.json`, `samples.jsonl` and logs into `U/qa-pre-upgrade/`.
5. **Swap only the executable.**
   - `ditto` the candidate executable over `R/Storage Inventory Fresh QA Worker.app/Contents/MacOS/StorageMonitor`.
   - Verify the copied executable's hash is `0525bdf6…` **before** signing.
   - Run `codesign --force --sign - --identifier local.macbook.storage-monitor.inventory-fresh-qa` on that bundle, then `codesign -v --strict`. Re-signing rewrites the embedded signature, so the executable's hash becomes `0c24644ffc01f006d39a10f4ae3d437042ac06843d86c4807873de38ea90007e`. This was rehearsed on a scratch clone of the QA bundle and is deterministic. Without re-signing, `codesign -v` reports `invalid Info.plist`.
   - The bundle's `Info.plist`, the plist, `supervise.py` and `run.json` are unchanged.
6. **Clear the pause:** `R/…/StorageMonitor inventory-resume --data-dir R/data`. This removes `inventory.cancel` and drops a resume request, which the worker ignores.
7. **Reload:** `launchctl bootstrap gui/501 R/inventory-worker.plist`. `RunAtLoad` starts the supervisor, which starts one worker. Verify exactly one supervisor and one worker, and that the executable hash is `0c24644f…` (candidate 2 as re-signed in step 5).
8. **Observe at least three complete slices, read-only:**
   - one `inventory events {…}` line per replay in `R/data/monitor.log` (expected `applied` or `retry`);
   - the reconcile row via APFS clone: `created_at` and `request_sequence` must not change without a logged `gap` reason; `last_node_id` should rise;
   - the cursor;
   - CPU and RSS from `samples.jsonl`, and the database size.
   Results go in `INVENTORY-REAL-VOLUME-STEADY-STATE.md`.

No step creates a generation, clears jobs, resets the cursor, or starts a fresh crawl.

## 5. Required authorization

These steps change QA resources and need explicit permission. The execution guard denied step 2 on 2026-10-23 at about 08:17 UTC.

| Step | QA resource that changes |
|---|---|
| 2 | Creates `R/data/inventory.cancel`; ends the running slice early, at a batch boundary |
| 3 | Unloads launchd job `local.macbook.storage-monitor.inventory-qa` |
| 4 | Creates `U/qa-pre-upgrade/` (new files only); takes brief read locks on the QA database |
| 5 | Replaces one executable and re-signs `R/Storage Inventory Fresh QA Worker.app` |
| 6 | Removes `R/data/inventory.cancel`; adds one request file under `R/data/inventory-requests/` |
| 7 | Loads the same QA plist; starts the corrected worker |
| 7–8 | The corrected worker migrates the QA database (§3) and writes to it from then on |

No production file, production LaunchAgent, installed app or DMG is involved.

### Approval checklist

- [ ] Pause QA with `inventory.cancel` and unload its launchd job.
- [ ] Back up the QA database with the SQLite backup API into `U/qa-pre-upgrade/`.
- [ ] Replace and ad-hoc re-sign the QA bundle's executable with `0525bdf6…`.
- [ ] Accept the additive migration of the QA database.
- [ ] Reload the same QA plist, and observe for at least an hour (three slices).
- [ ] Add a permission rule so the guard allows these specific QA-only operations.

## 6. Rollback and recovery conditions

Stop the corrected worker with steps 2–3 and preserve the database and logs if, during observation:
- it crashes repeatedly;
- `quick_check` fails;
- the reconcile row is re-requested without a logged loss reason (a false gap);
- the cursor moves backwards or stops being acknowledged across several slices;
- the same folders are relisted slice after slice;
- RSS approaches the supervisor's 512 MiB guard.

Then:
- **Do not** automatically overwrite the database with the backup, and do not restore an older cursor silently.
- To run the old executable again, first verify it against a clone of the *migrated* database. Its schema initializer is additive and guarded, so the extra columns are expected to be ignored, but that is not yet tested.
- Restoring the step-4 backup discards all catalog work done since the upgrade. That is a separate decision.

## 7. Risks and unresolved questions

- **The old worker may finish its current pass before approval.** The observation would then show steady-state maintenance rather than continuation of an existing pass. Both are useful, but they are different evidence.
- **Pause race.** If a slice reaches its 1,200 s budget just before the worker sees `inventory.cancel`, it exits 75 and launchd relaunches the supervisor once. That old-code worker runs one event replay, which could request another false gap, before it sees the pause and exits 0. Writing the file early in a slice avoids this.
- **Sleep.** Slice wall times vary because the Mac sleeps. Three slices may take well over an hour.
- **No Full Disk Access.** QA runs without it, as before, so protected folders stay unknown.
- **Event volume.** The first slice's event count will include activity from this machine's development work (test fixtures under `/private/tmp`).
- **Unresolved:**
  - whether `initial_completion` is confirmed automatically once the pass finishes on the real catalog;
  - the old binary's behaviour on the migrated schema.

## 8. Installer review (separate from QA)

| Risk | Finding |
|---|---|
| SQLite snapshot consistency on APFS | **Sound for rollback-journal databases (the only mode the code uses).** The clone is taken inside a read transaction. The shared lock stops any writer from changing the database file, which requires an exclusive lock, and a hot journal is rolled back by the first read. **Defect fixed:** a WAL-mode database could not be snapshotted correctly by cloning the main file. Usually the schema check refused the snapshot and the install failed. Rows could be silently missing if the tables were already in the main file and only rows sat in the WAL. Such databases are now copied through the backup API into a self-contained file. Regression test added. |
| Indefinitely hanging install helpers | **No unbounded wait found.** Every subprocess goes through `run()`, which enforces a timeout and escalates to SIGKILL: `launchctl` 15 s, `lsregister` 10 s. SQLite busy timeouts are 10 s (snapshot), 3 s (history) and 100 ms (inventory). Copying the app bundle and the migration are bounded work. The viewer drains helper output, so a full pipe cannot stall it. **Residual:** if the helper itself wedged in uninterruptible I/O, Settings would show a spinner with no cancel; quitting the viewer leaves the transactional helper to finish or be recovered. Not release-blocking. |
| Recovery after new agents start writing | **Release-blocking defect, fixed.** The journal reached `registered` only after all three bootstraps. A failed second bootstrap, or a kill during registration, rolled back as if before registration. When the migration had changed the schema, that restored the snapshot over writes from the already-started first agent. After a kill those writes could cover hours. A new `registering` phase is recorded before the first bootstrap; from then on, rollback keeps the database and sets the snapshot aside as `history.pre-update-*.sqlite3`. Two regression tests cover the failure and the kill; the failure test fails with the guard disabled. |
| Other risk (not fixed) | The inventory migration uses a 100 ms busy timeout. A viewer query running at the moment of an update could make a migration statement fail, which rolls the update back cleanly. A spurious failed update is possible, but no data is lost. |

## Verification of this preparation

- **Monitor self-test:** 227 passed.
- **Inventory integration tests:** 221 passed, from the same source as candidate 2.
- **Viewer model tests:** 328 passed. No viewer source changed in this pass.
- **QA:** untouched. Its binary, plist and `supervise.py` hashes are unchanged, its slices kept running, and nothing was written under `R`.
- **Production:** hashes unchanged.
- **Not done:** no `launchctl` mutation, no install, no DMG rebuild, no window focus, no commit.
