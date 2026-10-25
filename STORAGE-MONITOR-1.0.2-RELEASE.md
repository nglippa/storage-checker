# Storage Monitor 1.0.2 (build 3): release report

2026-10-24. Built on the Mac mini (M4 Pro, 24 GB). **It has not been installed or validated on the MacBook Air**, and it is not notarized (ad-hoc signature). Nothing was installed, committed or pushed.

| | |
|---|---|
| DMG | `build/dist/Storage-Monitor-1.0.2.dmg` (10,287,860 bytes, `hdiutil verify` VALID) |
| SHA-256 | `4923c4e1b42887624bb127762993170bfcdcd8ee282ff33c7d22c861f47665ac` |
| Evidence | `build/release-1.0.2/` |

## 1. Root cause of D1 (readable directories silently not listed)

The Air's findings document was not available on this Mac. Each cause below was confirmed against the release source and reproduced on real directories.

1. **One unreadable entry hid a whole readable folder.**
   - `readInventoryBatch` returned `.unavailable("metadata:" + …)` for the entire directory as soon as one entry's `fstatat` failed with EPERM or EACCES.
   - The folder was then finished as an inaccessible `unknown` node with no children.
   - Reproduced with the 1.0.1 code on `/private/var/db`, where only `DifferentialPrivacy` refuses `lstat` (EPERM). The catalog held 1 node (`unknown`, `metadata:privacy`, 0 children), and 6,420 readable entries were missing. The same mechanism applies to any folder holding one protected entry.
2. **Activity relabelled never-measured folders as stale.** `applyInventoryInvalidations` set every invalidated node to `status='stale', reason='Filesystem activity'` and re-queued its job. That includes folders recorded as unreadable or consent-protected (`~/Library/Application Support`, `Metadata`, `Photos` and `Preferences` are not opened without Full Disk Access). The result is the Air's observed state: pending, "Filesystem activity", `attempts=0`, `completed_sequence=0`. Those folders had never been listed, yet the UI showed them as previously measured.
3. **Why the first pass still reported completion.** The milestone checks for first-listing jobs that are still pending. These folders' jobs had been *completed as unavailable* before the milestone was recorded, and were only re-queued by later activity. So `initialCompletion` was `complete` while the folders were in fact never listed.
4. **Unbounded postponement in the queue.** Each re-queue moved a still-pending job's `updated_at` to "now", sending it to the back of the FIFO. A folder that changes before every slice could wait while the queue held more than one slice of work.
5. **A folder that changed while being opened was recorded as unreadable.** `InventoryOpenDirectory` failed when the folder changed between `lstat` and `opendir`. The caller then reported a first listing as `.unavailable(accessReason(errno))` using a stale `errno`, so a busy, readable folder was finished as `unknown`, for example `error:2`, and was never listed. This was found by a regression test during this pass.
6. **A changing folder could escape deferral.** A buffered listing found changed at commit time was restarted without counting toward the 3-attempt deferral limit, so it could be relisted for the rest of the budget. This was found during this pass when the larger commit groups made it more frequent.

## 2. Root cause of D2 (about 38 relaunches per hour)

`inventory-work` computed its exit code from the **final** pass, not the main run:

1. after a complete main run, the closing event replay queues anything that changed during the run;
2. a zero-budget pass (`maxDuration: 0`) then reports `interrupted` with work pending;
3. that result replaced the main result, so any filesystem activity during a run produced exit 75;
4. `KeepAlive {SuccessfulExit=false}` with `ThrottleInterval 60` then relaunches about 95 s later, repeating indefinitely on an active Mac.

Folders re-queued by cause 2 above made this certain. The test `D2: work queued by the closing replay…` reproduces it exactly: the final pass is `interrupted` while the main run is `complete`.

## 3. Fixes

| Area | Change |
|---|---|
| D1 — unreadable entries | An entry whose metadata is refused is recorded on its own, as `unknown` with reason `metadata:privacy` or `metadata:permissions` and no size, taking its name, inode and type from `readdir`. The rest of the folder is listed, and the folder is a lower bound (`partial`). An existing node keeps its object, so earlier identity is not replaced. The viewer shows these entries as "Access restricted". |
| D1 — honest status under activity | Invalidation no longer turns `unknown`, `excluded` or never-listed (`pending`) nodes into "previously measured". It keeps their status and reason and re-runs the job. A folder that becomes readable is re-measured from its next listing. |
| D1 — bounded postponement | Re-queuing never moves an already queued folder back in the queue (`MIN(updated_at)`). A folder re-queued before every slice reaches its first listing while other work remains (tested). The deferral marker is kept until the folder's next listing. |
| D1 — open race | A folder that changes while being opened is reported as changed (retried, and counted toward deferral). Only a real `lstat`, `opendir` or `fstat` error is reported as unreadable, with its own errno. |
| D1 — deferral | Restarts caught at commit-time revalidation count toward the 3-attempt limit too. Deferred folders stay explicitly pending and stale, are counted in the status, and are retried on every update. |
| D2 — exit policy | `InventoryRunResult.runnableWorkRemains` is true only when the main run stopped at its time or entry limit with runnable work. The exit code uses the main run, so 75 is returned only for a first pass or reconciliation that exceeds its 1,200 s slice. Drained, deferred, paused, busy and low-space runs exit 0. A failing worker logs and exits 0 instead of relaunching every minute. Queued event work waits for the next :00/:30 check or a viewer request. |
| Low-space safety | Checked every 5 s against important-usage free space. The threshold is 1% of the volume, between 2 GB and 5 GB (2.56 GB on a 256 GB Air). Indexing pauses with an explicit reason, exits 0 and resumes on a later wake. The viewer shows "Indexing paused: disk space is low". |
| Progress and ETA | See §6. |
| D4 | Before consent, with no database, the inventory view shows "not installed or started" instead of a database-open error. |
| D5 | Removed "see PACKAGING.md → Gatekeeper" and "bin/storage-monitor authorize" from the helper output shown in Settings, and replaced them with user-facing steps. |
| D6 | The Overview no longer says history "is still loading" when there is no history, or when history is loaded but holds no readings; each case has its own wording. The clipped header labels were **not verified**, because no GUI could be shown (AGENTS.md). |
| D7 | The consent text now states that the free-space check only records history, and that low-space notifications stay off until "Allow Low-Space Notifications…" shows the macOS prompt. That matches `authorize`, which is the only path that requests notification permission. |
| D8 | PACKAGING.md → Updating describes upgrades from 1.0.0 (Repair) and 1.0.1 (Update). |

## 4. Initial scan performance

Workload: `/Applications` on the Mac mini (283,524 entries, 31,835 folders, warm cache), run through the real worker path (`runInventory`) on isolated state. The profiler is the existing opt-in `InventoryProfile`.

| | 1.0.1 | 1.0.2 | Change |
|---|---|---|---|
| Default priority, wall time | 113.5 s (2,498 nodes/s) | 25.0–33.1 s (8,566–11,332 nodes/s) | **3.4–4.5×** |
| Background policy (`taskpolicy -b`, the agent's launchd class), wall time | 358.4 s (791 nodes/s) | 103.9 s (2,728 nodes/s) | **3.4×** |
| Transactions committed | 46,531 | 2,148 | −95% |
| SQL statements | 4.26 M | 1.76 M | −59% |
| CPU, default priority | 57.2 s | 21.5–27.9 s | |
| Peak RSS | 22.6 MB | 24.9–26.6 MB | |
| Catalog | — | **identical**: all 283,524 nodes, totals, statuses and ownership; `integrity_check` ok | |

The default-priority range comes from repeated runs on a busy machine (load average about 4.2): the same binary varied by ±25%.

**Top three measured bottlenecks in 1.0.1, at default priority:**

1. **Durable commits: 61.9 s of 113.5 s.** The database uses a rollback journal by design (the viewer's no-journal reads and APFS snapshot soundness depend on it), so each commit costs two fsyncs. There was one commit per listing start, plus about one per parent folder.
2. **SQL statements: 37.5 s.** About 15 per entry.
3. **Ancestor aggregates: 15.5 s.** Every completed listing recomputed every ancestor up to the root.

**Changes, each verified by the identical-catalog comparison and the regression suites:**

- **Sequence blocks.** One commit reserves 64 unique listing sequences, used only while no other writer advances the counter. Every listing still gets a sequence above everything issued before it starts, and a request captured after a reservation is never satisfied early.
- **Wider commit groups.** Completed listings of unrelated folders share a commit (up to 32 listings or 2,048 entries, or 0.1 s). A folder that is an ancestor or descendant of a buffered listing forces a flush first.
- **One aggregate pass per commit.** Each affected ancestor is recomputed once, deepest first, instead of once per listing.
- **A new-entry fast path.** A single insert for new objects, no existence lookup when a folder is listed for the first time, no tombstone delete for brand-new nodes (tombstones cascade), and the owner's values written directly.
- **Less frequent writer yields.** The fairness yield runs once per second instead of every 200 ms. Under background timer coalescing, each 2 ms sleep had become about 50–90 ms, 19% of background wall time.

Durability is unchanged: synchronous FULL, rollback journal, and every transaction still atomic. No index was removed and no concurrency was added.

**Remaining limits at background priority:**

- SQL statement time is 63 s of 104 s, dominated by per-entry inserts into ten `inventory_nodes` indexes on efficiency cores.
- Aggregates take 13 s.
- Enumeration and metadata together take about 11 s.

**Air projection, not a measurement:** if the Air speeds up by the same 3.4× as the background benchmark, its 1 h 58 min first pass would take roughly 35 minutes. That has not been measured on the Air. Reaching minutes rather than tens of minutes would need fewer indexes on hot insert paths (below) or WAL, which is an architecture change and was out of scope.

## 5. SQLite size

- **Per node:** 478 B, unchanged (1.0.1: 477 B/node; the Air's 967 MB for 2.02 M nodes fits the same ratio). Indexes are 87.7 MB and tables 41.5 MB on the benchmark catalog.
- **Overlap:** `inventory_nodes_parent (generation_id, parent_id, name NOCASE)` (7% of the database) overlaps `inventory_nodes_children (parent_id, name NOCASE, id)`.
- **Why it stays:** dropping it makes the viewer's by-name folder page plan `SEARCH n USING INDEX inventory_nodes_name (generation_id=?)`, which reads the whole generation. Removing it safely first requires steering that query onto `inventory_nodes_children`, which is left as follow-up work.
- **What 1.0.2 adds:** one small table (`inventory_progress`, at most 720 rows per generation, older rows deleted) and two cursor columns.
- **Visibility:** the database size (main file plus journal) is shown in Disk Inventory's footer note.

## 6. Progress and time remaining

- **Persistence:** the worker writes a progress sample at most every 10 s of work (completed and queued listings, nodes, bytes) to `inventory_progress`, kept for 2 hours, so the display survives worker slices and viewer restarts.
- **Display during the first pass:**
  - items indexed · bytes examined · folders completed · folders queued (deferred folders excluded);
  - items per second over the last ~2 minutes, including any gaps between slices;
  - "Elapsed …" since the first pass started;
  - an estimate when defensible.
- **The estimate:**
  - it is the remaining queued listings divided by the queue's shrink rate, from a least-squares fit over the last 10 minutes of samples;
  - it is shown only with at least 6 samples spanning at least 2 minutes, the newest under 2 minutes old, a queue that is shrinking with R² ≥ 0.7, and a result under 48 hours;
  - otherwise it reads "Estimating time remaining…", and paused or low-space states say "No estimate while paused";
  - the wording is coarse ("about 5 / 10 / 15 minutes", "about 2 hours");
  - there is never a percentage, and no total is derived from the growing catalog.
- **Limitations:**
  - It extrapolates the current queue-drain rate. Early in a pass, while discovery adds folders faster than they are listed, it stays "Estimating…", possibly for a long time on large disks.
  - It usually errs long, because discovery slows near the end.
  - It has not been observed on a real full-volume first pass; tested on synthetic sample series only.

## 7. Test results

| Suite | Result |
|---|---|
| `scripts/test-inventory.sh` | **255 / 255 passed (3 consecutive clean runs after the final changes)** |
| `StorageMonitor self-test` | **231 / 231 passed (also from the mounted DMG)** |
| `scripts/test-gui.sh` | **344 / 344 passed** |
| `build-gui.sh` (26.5 SDK) | OK, no warnings |

New targeted tests:

- **D1:**
  - a readable folder with refused entry metadata is listed as `partial`, and those entries are `unknown` with `metadata:permissions`;
  - bounded postponement under re-queues before every slice: the queue position never increases, and the folder is listed while 332 jobs remain;
  - a consent-protected folder stays "protected" under activity;
  - a first pass with a continuously changing folder records completion as C, never A;
  - deferral, a later-run retry, and C → B.
- **D2:**
  - budget-limited slices exit 75 and continue to completion (4 slices, 601 entries, final exit 0);
  - the exact Air sequence exits 0;
  - four launchd invocations under continuous activity cause 0 relaunches, and the catalog matches disk;
  - a busy second worker exits 0.
- **Low space:**
  - the threshold values;
  - pause before writing, exit 0 and the status shown;
  - resume and completion once space returns;
  - progress samples persist across runs.
- **ETA:**
  - withheld with too few samples, a growing queue, or a stopped worker;
  - within 25% of the truth on a steady drain (583 s against 600 s);
  - at most a 6.8% change between 10 s refreshes, with the wording changing 5 times in 15 minutes;
  - it survives a 60 s slice gap;
  - low-space pause wording.
- **Migration, on copies:**
  - a clone of the 2.9 M-node QA catalog (from 1.0.1-era code): every row and the root total preserved, progress table and cursor columns added, `quick_check` ok, 3 ms;
  - a read-only `.backup` of this Mac's production history (1.0.0-era, no inventory): 124 readings, 29 alerts, 7 diagnostics and 10 state rows preserved, inventory tables added, `quick_check` ok.

**Real-volume omission audit** (isolated state, release CLI `inventory-work --root …`):

| Root | Entries (catalog vs `os.scandir` walk) | Unfinished jobs | Unknown dirs | Unknown but actually listable | Exit |
|---|---|---|---|---|---|
| `/private/var/db` | 6,421 = 6,421 | 0 | 58 (privacy 14, permissions 40, metadata:privacy 4) | **0** | 0 |
| `/Library` (Data volume) | 116,813 = 116,813 | 0 | 8 (permissions 4, metadata 4) | **0** | 0 |

## 8. Remaining risks

1. **No Air validation.** The Air speed-up, the honest completion state on its real tree, idle behavior between wakes, and the upgrade from 1.0.1 are all unverified there.
2. **Consent-gated folders without Full Disk Access** are still never opened. They are now consistently reported as protected and are not re-labelled as stale. Their data (the Air's ~20.5 GB) is visible only after Full Disk Access is granted. That is a product decision, not a scan defect.
3. **Queued event work after a run** now waits up to 30 minutes for the next check instead of being relisted after 60 s. Totals for recently changed folders can lag by up to one check interval.
4. **The ETA model** is new and has only been validated on synthetic series.
5. **Native viewer appearance** is not verified: new progress lines, low-space state, footer database size, D6 wording and clipped labels (no GUI automation is allowed on this Mac).
6. **Index overlap** remains (about 7%), along with the commit cost of the rollback journal; see §4 and §5.
7. **Notarization and source state.** The build is ad-hoc signed, not notarized, and built from an uncommitted working tree (fingerprint in §9).

## 9. Build provenance

| | |
|---|---|
| Source | `46cd268` plus uncommitted working tree; fingerprint `a8f36600eb45aafa5883f62069ad7e28070669947d9df185fd68b60e60c1352e` (`build/release-1.0.2/source-fingerprint.txt`) |
| Compiler | Apple Swift 6.4 (swiftlang-6.4.0.34.1), `-O`, Swift 5 mode, macOS 14.0 target, universal arm64 + x86_64 |
| App / helper versions | 1.0.2 (3) / 1.0.2 (3) |
| Executables in image | helper `0c991273876e6a6eb639ca026658bd89b3a40feb232ddf114af15d73c1eec67d`, viewer `c2cf078ccd12add3aef0ab89056fe3ed6d3554ee398e925f5738098038aee60e` |
| Signing | ad-hoc; `codesign --verify --deep --strict` ok; Gatekeeper `rejected` (expected) |

## 10. MacBook Air upgrade test (requires explicit authorization)

The Air has 1.0.1 (build 2) installed. Keep the 1.0.1 catalog: the upgrade path is what is under test.

1. **Before:**
   - `cp -c` the database to `/tmp/pre.sqlite3`, then record `SELECT COUNT(*)` for `readings`, `inventory_nodes` and `inventory_jobs WHERE state IN ('pending','enumerating')`;
   - record `launchctl print gui/$(id -u)/local.macbook.storage-monitor.inventory | grep -E "runs|last exit"` and `tail -20 monitor.log`.
2. **Transfer** `Storage-Monitor-1.0.2.dmg` by USB or `scp`. The SHA-256 must equal the value above, and there must be no quarantine attribute.
3. **Install:**
   - Quit Storage Monitor, then replace /Applications/Storage Monitor.app with the one from the DMG.
   - Open the app. Settings must show "differs from this app (1.0.2)". Choose **Update Background Monitor…**.
   - The inventory agent's arguments must include `--budget 1200`.
4. **Data preserved:**
   - after the update, `readings` and `inventory_nodes` counts are equal or higher on a clone;
   - one `history.pre-update-*.sqlite3` exists;
   - `install-transaction/` is absent.
5. **D1 on the real tree:**
   - On the next runs, `/private/var/db` must have `status` other than `unknown` with children present.
   - For each of the five folders the Air reported, the catalog must show completed, deferred, or protected/unreadable with a reason. None may be pending "Filesystem activity" with `attempts=0` across more than one check.
   - Audit query on a clone: `SELECT COUNT(*) FROM inventory_jobs j JOIN inventory_nodes n ON n.id=j.node_id WHERE j.state='pending' AND j.completed_token=0 AND COALESCE(j.reason,'') NOT LIKE 'deferred%'` must reach 0 after a quiet check.
6. **D2:**
   - For 2 hours after the update, `launchctl print … | grep runs` should grow by about 4 per hour (the :00/:30 checks plus requests), not about 38.
   - `last exit code` should be 0.
   - `pgrep -f inventory-work` should print nothing between checks.
   - `monitor.log` `inventory {…}` lines carry `"continues":false`.
7. **Status and ETA:**
   - With Chrome open, the status may read "Up to date except 1 folder that keeps changing".
   - Otherwise it should read "Inventory is up to date" or "Showing available measurements" without Full Disk Access.
   - There must be no first-pass panel unless a first pass is genuinely running.
8. **Optional fresh first pass, to measure speed:**
   - This requires a separate authorization, a separate test account, and a fresh install of 1.0.2.
   - Record elapsed time, the `inventory {…}` throughput, peak RSS and the database size.
   - Check that the first-pass panel shows items, bytes, items/sec, elapsed time, and eventually an estimate.
9. **Low-space behavior:** do **not** fill the Air's disk. Low-space pausing is covered by automated tests only.
10. **Stop conditions:**
    - any decrease in history rows;
    - the run count growing faster than about 6 per hour without a first pass;
    - a readable folder left `unknown` with no reason;
    - worker RSS over 200 MB;
    - memory pressure reaching critical.
