# Disk Inventory implementation and verification

## Event-gap reconciliation churn — 2026-10-23, ~08:10 UTC

The details are in `INVENTORY-RECONCILIATION-STEADY-STATE.md`.

**Finding (read-only QA evidence):**
- The 07:40:27Z and 08:00:38Z QA slices both restarted reconciliation. The reconcile row was re-requested at 07:40:34Z and 08:00:45Z, and `last_node_id` went from 198,029 to 280 at 07:40.
- Replaying the same FSEvents windows read-only showed no loss. HistoryDone came after 7–12 s, beyond the old fixed 5 s timeout. The 07:20–07:40 window also exceeded the old 4,096-directory limit (5,134 directories).

**Correction:**
- Only genuine loss schedules full reconciliation.
- High volume becomes targeted relistings, spilled durably under `pathMemoryLimit` before the cursor is acknowledged.
- An incomplete replay retries from the unchanged cursor and acknowledgement time.
- The inventory replay is now bounded by a stall budget rather than wall time, with a 30-minute guard, and a quiet interval is acknowledged.
- The cursor moves only to a marker captured before the stream, after HistoryDone plus `FSEventStreamFlushSync`. It never moves to an observed ID, because IDs were seen arriving out of order.
- There is no schema change.

**Verification:**
- Inventory tests: 221 pass.
- Monitor self-test: 209 pass.
- Viewer model tests: 314 pass; the monitor and viewer (26.5 SDK) builds succeed.
- On 12,000-folder fixtures, 4,500 changes now cost 4,500 listings and no full pass (before: 12,025 listings and a full pass). A slow replay costs 50 listings (before: 12,025).
- Sustained 6 × 4,200 changes start no full pass (before: 6) but cost 18,726 listings versus 13,745.
- The DMG was not rebuilt.

**NOT VERIFIED:**
- behavior on the real full volume: QA still runs the old code, and restarting it requires authorization;
- native GUI checks: none were needed for this change, and none were run.

## Lifecycle audit, desktop safety and DMG packaging — 2026-10-23, ~07:10 UTC

**Desktop safety.** `AGENTS.md` (imported by `CLAUDE.md`) now prohibits:

- focusing, raising or launching windows;
- sending desktop input;
- `focus_window`;
- touching protected QA/production state without explicit authorization.

Skipped native checks must be reported as NOT VERIFIED. No window was focused, raised or launched during this pass.

**Lifecycle audit:** one defect fixed. A folder replaced at the same name by a new directory object kept the old object's first-listing token, so completion could be recorded before the replacement was listed. The reset now clears it. Regression test added; it fails without the fix. The "no unapplied change notices" clause is a precondition for the moment of recording only. Details: `INVENTORY-COMPLETION-LIFECYCLE.md` §9a.

**GUI-managed background monitoring.**

- `install`/`uninstall` take an injectable home and launchd control. They are verified against an isolated home with a recording fake (17 new monitor checks); real LaunchAgents are never touched.
- Settings → Background Monitoring offers Enable, Update, Repair, Disable and Allow Notifications. Each requires explicit confirmation and is disabled in QA builds.
- Status is read from the LaunchAgent files (off, on, needs update, partly set up).
- A Privacy section explains optional Full Disk Access.
- The background monitor's deployment target was 27.0 while its plist declared 14.0; it is now built for macOS 14.0.

**Packaging.**

- `scripts/build-dmg.sh` builds `build/dist/Storage-Monitor-1.0.0.dmg`: 9,211,261 bytes, sha256 `4f4c05cf…8ea4e87`.
- It is universal (arm64 + x86_64), macOS 14+, and ad-hoc signed.
- The app bundles the background monitor at `Contents/Helpers/MacBook Storage Monitor.app`.
- `scripts/verify-dmg.sh` passes every check: mounted read-only with `-nobrowse`; structure; Applications symlink; identifiers and version; architectures; deployment targets; system-only libraries and rpaths; no build-machine paths; icons; deep strict signature; the bundled monitor's 209-test self-test run from the image; clean detach.
- Gatekeeper assessment of the ad-hoc app: `rejected`, as expected for unnotarized code. See `PACKAGING.md`.

**Verified:**

- 189 inventory, 209 monitor and 314 viewer checks: **712 total, all pass**.
- CLI and viewer development builds pass; the progressive harness compiles.
- The milestone SIGKILL crash probe passes.
- Fresh APFS clones of three real legacy catalogs migrate with records preserved, `integrity_check` ok and 0 foreign-key violations: pre-inventory → `not_started`, backlog → `unknown`, previous catalog → `complete` in 0.45 s.
- Installed apps, the production LaunchAgent and the QA worker binary match their recorded hashes. The QA worker is running with empty stderr.

**NOT VERIFIED:**

- Any native GUI interaction: Settings controls, confirmation dialogs, panel states, drag-install from the DMG, first launch from /Applications.
- Real launchd registration and run-at-login.
- Gatekeeper behavior for a downloaded (quarantined) DMG and its background helper.
- Intel hardware execution.
- A full-volume first pass recording its milestone.

Nothing was installed, committed or pushed.

## Durable first-pass completion milestone — 2026-10-23, ~06:30 UTC

See [INVENTORY-COMPLETION-LIFECYCLE.md](INVENTORY-COMPLETION-LIFECYCLE.md) for the invariant, schema, migration, viewer mapping and evidence.

The engine now records `inventory_generations.initial_completion` (`pending` / `complete` / `unknown`) and `initial_completed_at`. It does so through an additive, atomic migration with a partial index. The marker is set transactionally once no directory awaits its first listing, no invalidation is unapplied, and every traversable directory has listing work. Later updates, new folders, cleanup, reconciliation and event gaps never reset it. Older generations become `unknown` and are confirmed from durable state without relisting when that state is conclusive. The viewer now reads this marker instead of the previous round's per-viewer record, which was removed. It shows legacy `unknown`/`unsupported` neutrally.

**Verified:**

- 185 inventory (145 + 40 new), 192 monitor and 305 viewer checks pass: **682 total**.
- CLI and viewer builds succeed; the progressive harness compiles.
- SIGKILL crash recovery for the milestone passes, and the earlier progressive crash probe still passes.
- Migration was checked on APFS clones of three real legacy formats:
  - pre-inventory → `not_started`;
  - backlog snapshot → `unknown`;
  - previous QA catalog → confirmed `complete` in 0.43 s with zero listings.
- All clones keep records identical, pass `integrity_check` and have no foreign-key violations.

**Not verified:**

- Native interaction for the new states. One fresh-installation screen was checked, then native work was stopped because focusing the dev window captured another application's keystrokes. The other states are covered by tests on real worker-produced catalogs only.
- A full-volume first pass recording its milestone.

The active QA worker (still running, empty stderr, binary hash unchanged), its database and supervisor, the preserved snapshots and production were not touched. Nothing was installed, committed or pushed.

## Initial-indexing progress panel — 2026-10-23, ~05:50 UTC

The Disk Inventory header now shows a first-index panel from the moment initialization is requested: an indeterminate native progress bar (a static track while paused), "Started N ago · Remaining time is not yet known" from the generation's persisted `created_at`, discovered-item/completed-folder/queued-listing counts, and guidance that a first index with millions of files can take hours, results can be browsed meanwhile, later checks normally update only changed folders, and event-history gaps can require a broader recheck. No percentage or ETA is derived from the growing queue. The empty "No disk inventory yet" state states the expected duration before Start is pressed.

*(Superseded: the viewer-side record described below was replaced by the durable engine milestone in the section above.)* **Correction to the handed-off draft.** `hasInitialDiscoveryWork` means "a never-completed folder listing is queued". A disposable CLI fixture confirmed that folders created *after* the first pass also produce such jobs, so the draft would have shown "Building your first inventory … can take hours" during an ordinary later update. The catalog has no durable "first pass finished" marker, and the root node's state cannot distinguish the cases (it becomes `stale` during an unfinished first pass when files change). Without a schema or worker change, the viewer now records — per database path, generation id and `created_at`, in its existing preferences domain — the first time it observes that generation with no first-time listings left. First-time listings drain exactly when first discovery ends, so this record is never written early. Known limit: if the viewer first opens a finished inventory while a large later update has first-time listings queued, it can show the first-index panel until those drain. A worker-written completion marker would remove this; it was out of scope here.

Other review fixes: duration guidance is not shown while the status query is still loading (no multi-hour claim before the database confirms a first index); the status line no longer says "Inventory has not started" under "Preparing initial inventory…" or "Discovering files and folders" while paused, and no longer duplicates the panel's counts; guidance and detail text use vertical fixed size so they wrap instead of truncating; the paused track and panel container expose accessibility elements/identifiers.

**Verified:** 299 viewer model checks pass (`build/inventory-initial-progress-tests-3.log`; previous 284 + 15 new initial-progress checks). The viewer builds with the existing 26.5 SDK (`build/inventory-initial-progress-build-3.log`); `git diff --check` passes. Native verification used a separately identified dev copy (`local.macbook.storage-monitor.viewer.initial-progress-dev`) at the 780×620 minimum window size against disposable scratch databases, driven by an isolated `--root`/`--data-dir` CLI run: before any generation; immediately after Start (no worker running → "Preparing initial inventory…" with bar and guidance); partial first discovery with overlapping filesystem changes; paused (static track, "Initial indexing paused", read correctly after relaunch); finished ("Inventory is up to date", panel gone); and a later update with 29 first-time listings queued (panel correctly absent). Accessibility exposes the bar as a busy indicator labelled with the panel title and the paused track with its label.

**Not verified:** the Pause/Resume menu items were not clicked natively (another application kept taking focus on that display); pause was driven through the same file-based request (`inventory-cancel`) the menu uses. VoiceOver speech, Dynamic Type and light appearance were not exercised. The active QA catalog was not opened by the new viewer; the QA worker, its supervisor, configuration and database were not touched and it remained running with an empty stderr log. Nothing was installed, committed or pushed.

## Authorized fresh full-volume QA start — 2026-10-23, 03:14 UTC

The user explicitly approved stopping the retained QA crawl and starting a fresh initialization with the latest development code. This authorization supersedes the earlier prohibition on restarting QA for this operation only. Production remains unchanged.

The prior worker exited cleanly after supported cancellation, then its QA service was unloaded. Its original database remains in place, paused. A consistent APFS copy containing **2,959,505 entries** passed `quick_check` and `foreign_key_check`; the old worker plist is retained alongside it. The immutable causation snapshot was not changed.

Fresh evidence and configuration: `build/inventory-fresh-20261023T031313Z/`. `build/inventory-fresh-current.json` points to this run. The new private `data/` directory initially contained no database or refresh requests. A separate signed development worker uses the current source build, default **256-entry batches**, **1,200-second checkpoint slices**, background process/I/O priority and nice 15. The distinct QA service label is reused; production service configuration is not touched. Launchd retries checkpointed slices with a 10-second throttle. Only one QA filesystem worker runs. No root refresh was queued.

The supervisor started at **2026-10-23T03:14:17.913476Z** (22:14 CDT, October 22). The catalog's root generation began at 03:14:23Z. At **03:14:39Z**, the fresh startup Data-volume catalog contained **12,241 entries**, with **zero refresh passes and zero pending invalidations**. These are early observations, not a completed-duration estimate. Final full-volume performance and steady-state correctness remain **NOT VERIFIED**.

The supervisor samples worker CPU/RSS, database bytes and free capacity every 15 seconds into `samples.jsonl`; each worker slice emits its outcome, elapsed time and peak RSS to `worker.stdout.log`. It requests a safe pause below 5 GiB free space or above 512 MiB worker RSS, with a termination fallback confined to its own child if cancellation does not finish. It performs no filesystem enumeration itself. Detailed internal `InventoryProfile` timers are not enabled by the normal CLI; external samples must not be presented as those internal timings. Full Disk Access coverage must be checked from the worker summary; it is not assumed.

The development backend rebuild and its 12 embedded inventory self-tests passed before launch. No source implementation was changed for this launch; the preceding 621-check verification remains recorded below. Post-launch hashes of both installed production binaries and the production LaunchAgent match the preservation baseline. The old QA executable is also unchanged; the fresh worker resides in a separate bundle. Nothing was installed, committed or pushed.

## Progressive experience pass — 2026-10-23

See [INVENTORY-PROGRESSIVE-EXPERIENCE.md](INVENTORY-PROGRESSIVE-EXPERIENCE.md) for the current startup audit, implementation, state semantics and measured evidence. This pass preserves the prior lifecycle corrections and leaves the active QA worker/database, production and immutable snapshot untouched.

Live capacity is visible without waiting for history or inventory. Navigation uses bounded priority in the existing job system, partial sizes publish during a listing, stale prior values have explicit separate fields, and progress uses discovery/activity counts rather than a growing-denominator percentage. A native folder picker can follow indexed ancestors toward a requested unindexed directory. Complete cached browsing does not wake a scanner. Busy pages refresh through the existing viewer loop; idle pages back off, and hidden/inactive windows do not poll. Cancelled navigation discards obsolete queued reads.

**621 checks pass:** 145 inventory, 192 monitor, 284 viewer. Both development builds pass (viewer uses the existing 26.5 SDK). Fresh disposable snapshot regression, legitimate cleanup, actual priority-aware SIGKILL recovery and SQLite checks pass. Original historical tables and production/snapshot hashes remain preserved.

On this Mac mini, native live capacity/history were exposed within **1.51 s** of launch with inventory uninitialized. A separate fresh, bounded native run exposed partial inventory after **1.81 s**; nonzero qualified-page data was ready after **0.71 s** from index process start. Its 13,163-node scope completed in **4.184 s** at default batches. Three independent 4,089-node runs took **0.95–1.13 s**, with zero repeated listings and 16.5–17.4 MB backend peak RSS. Focused partial query navigation measured **18.17 ms median**; nine real bounded FSEvents updates measured **0.670 s median**. These are bounded development results, not customer/full-volume estimates. The separate one-entry-batch stress run intentionally lasted 58 s and must not be confused with default performance.

**Production readiness remains NOT VERIFIED.** Full-volume completion, smaller-machine behavior and steady-state monitoring impact still require representative verification. No additional unrestricted scan was launched; this pass did not change or restart the active QA worker. The luminous visualization was not started.


## Authorized QA worker upgrade — 2026-10-23, 01:23 UTC

After the correction pass, the user explicitly requested the newer code on the existing QA worker. That later authorization supersedes the previous prohibition on changing that QA worker/database for this upgrade only. Production remains excluded.

The old worker exited through supported cancellation, then its QA service was unloaded. Its old app and unchanged LaunchAgent configuration were preserved. A consistent 1,401,688,064-byte pre-upgrade SQLite backup passed `quick_check` and foreign keys. Only the QA executable was replaced with the verified lifecycle correction build and the QA bundle was re-signed. Supported resume cleared the pause intent; the same LaunchAgent was loaded without a new refresh request or new full-volume crawl.

The new worker is running, the additive lifecycle migration is present, and generation 1 was retained. At 01:23 UTC the catalog held 2,912,497 nodes and 389,450 completed directories. New completed-sequence/token metadata confirms listings committed under the corrected code. All 20 root children remain present. The seven historical tables match the pre-upgrade backup row for row; installed production binaries, production LaunchAgent and the original evidence snapshot hashes remain unchanged. No production migration or installation occurred.

Evidence: `build/inventory-correction/qa-upgrade-20261023T012028Z/` contains the old app/configuration, verified pre-upgrade database, before/after-start records and `validation.json`. An optional online post-upgrade validation copy was cancelled because ongoing writes repeatedly restarted copying; that incomplete copy is explicitly not evidence. Final history comparison used a short read-only transaction instead.

Legacy refresh work was retained conservatively: missing historical listing order cannot justify discarding it. Resuming this old contaminated catalog is not a clean first-index benchmark. Multi-day customer initialization is unacceptable; initial-index performance remains a release blocker. The bounded fixture timings do not establish customer-scale speed. No production-readiness claim is made.


## Correction pass — 2026-10-22, 21:35 UTC

Current acceptance status is recorded in [INVENTORY-RECONCILIATION-FIX.md](INVENTORY-RECONCILIATION-FIX.md). This section supersedes the earlier test counts and “let QA finish” acceptance recommendation below; the rest of this document preserves historical development evidence.

Cleanup now validates listing authority inside each deletion transaction, retains provenance through recursive pruning, and rejects obsolete tokens. Refresh requests retain a monotonic ordering boundary and finite endpoint, skip newer successful listings, and preserve later events/gaps. Legacy state is migrated conservatively without invented completion ordering.

The immutable 20:33 UTC evidence copy reproduced the unsafe root cleanup selection. Corrected code retained all 20 root children, retired 256 other obsolete markers without current-record deletion, and pruned a genuinely absent seed under valid authority. All seven historical tables remained equal to the source; SQLite checks passed. The snapshot hash, installed binaries and production LaunchAgent remain unchanged; production still has zero inventory tables. The active QA worker/database were not modified or restarted in this pass.

Verification: **114 inventory, 192 monitor and 273 viewer checks pass**, both applications build, actual SIGKILL recovery passes, and the native browser supports navigation/search/pagination/largest files on a clearly labeled interrupted index. The installed macOS 27 SDK lacks its SwiftUI StateMacro plugin; the viewer build passed with the already installed macOS 26.5 SDK using `STORAGE_MONITOR_SDK_PATH`. The focused report records failed worker-context attempts and successful host reruns.

Three clean bounded initial runs each indexed 4,089 entries / 86 directories in **1.037–1.437 s**, with **zero repeated listings**, reported peak RSS **17.5 MB**, and 1.65 MB database growth. Nine real bounded FSEvents updates completed in **0.601–0.784 s**; 90/90 competing insert/rollback probes succeeded (maximum 219 ms). These are warm synthetic measurements while the old QA crawl was active, not full-volume estimates or a controlled production monitoring comparison.

**Production readiness is NOT VERIFIED.** The existing QA run includes redundant manual refresh work and old cleanup behavior, so its eventual finish cannot establish normal first-index duration or validate the corrected code. A bounded benchmark harness is ready; another unrestricted crawl was not launched. A clean full-volume scan requires an isolated database, no competing QA crawl, resource limits and separate explicit authorization. Full-volume steady state and M2/8 GiB performance remain unverified. No commits, pushes or installation occurred.

Latest evidence is under `build/inventory-correction/`: `verification.stdout.log`, `root-inventory-final.log`, `monitor-host.log`, `gui-host-tests.log`, `gui-sdk26-build.log`, `crash-recovery.json`, `final-background-benchmark.json`, `query-benchmark.json`, `native-partial-largest-files.png`, and `preservation-final.json`.

## Earlier foundation verification (historical)

Snapshot: 2026-10-22T19:46:06.100473+00:00. This is an implementation report, **not full phase acceptance**. The startup Data-volume QA inventory is still building/reconciling. Its initial completion duration and final counts/database footprint are not yet known. No commit, push, production installation, production inventory migration, or system-settings change was performed.

## Architecture and reuse

The comprehensive coverage catalog stores disjoint aggregate areas, not every directory entry. It cannot directly provide file search or immediate children. The pre-implementation reuse decision and full design are in [INVENTORY.md](INVENTORY.md).

Inventory enriches that infrastructure with persistent directory entries and object metadata. It reuses startup Data-volume boundaries, firmlink/path normalization, consent gates, allocation semantics, observational low-priority traversal policy and the existing FSEvents replay implementation/history. An independently acknowledged inventory consumer cursor prevents a monitoring check from acknowledging uncommitted inventory work; there is no new continuous event stream or polling loop. The attribution engine and notifications retain their responsibilities.

Persistent directory jobs/checkpoints, generation IDs, bounded batches, qualified ancestor aggregates, identity-preserving directory moves, hard-link ownership, deferred pruning and explicit stale data support interruption and incremental updates. Absolute paths derive from parent/name relationships and the generation root. The query actor is independent of SwiftUI and exposes the future visualization contract; historical growth is currently unavailable. No luminous tree was rendered.

The native browser adds a separate section with paginated contents, largest folders/files/items, name/path-prefix search, breadcrumbs, measurement details and background request controls. It does not start a crawl on launch.

## Files and database changes

New core: `Sources/Inventory.swift`, `Sources/InventoryCommands.swift` and three files under `SourcesShared/` (`InventoryMetadata.swift`, `InventoryModels.swift`, `InventoryRequests.swift`). New browser: `SourcesGUI/InventoryView.swift`. Integration changes: `Sources/Coverage.swift`, `Sources/StorageMonitor.swift`, `SourcesGUI/StorageMonitorApp.swift`, `scripts/build.sh`, `scripts/build-gui.sh`. Tests/tooling: `tests/InventoryTests.swift`, `tests/InventoryIntegrationTests.swift`, `scripts/test-inventory.sh`, `scripts/benchmark-inventory.py`. Documentation: `INVENTORY.md` and this report.

Migration adds ten prefixed inventory tables, navigation/size/job indexes and inventory-only count triggers. Setup is idempotent and additive, including introspected development-schema columns. Existing readings, alerts, diagnostic data, state, attribution evidence and comprehensive coverage tables are preserved. The production command path verifies a backup before the first inventory migration. Development migrated an isolated, verified SQLite backup copy.

All seven original tables in the QA database match the backup row for row. Backup and QA `quick_check` return `ok`; the QA foreign-key check has no violations. Both installed production binary SHA-256 values match their baseline. A final read-only production check found zero inventory tables; installed production binaries still match their original hashes. The latest row comparison is in `preservation-after-watchdog.json`; all seven original tables still match and production still has zero inventory tables.

## Measured behavior on the Mac mini

Hardware: Mac16,11 (Mac mini M4 Pro), 24 GiB RAM. The M2 Air/8 GiB machine was unavailable; its performance is unverified. The background QA worker reports Full Disk Access **not granted**. The explicitly invoked, scoped host verification reported granted; neither execution context was granted permissions by this task.

| Measurement | Observed result |
| --- | --- |
| Startup Data catalog at snapshot | 2,656,984 entries, incomplete |
| Indexed regular-file names | 2,208,290 |
| Indexed directories, including root | 391,064 |
| Indexed symbolic-link names | 57,592 |
| Other entries | 88 |
| Pending directories | 4,288; additional stale/reconciliation work exists |
| Full Data initial indexing duration | **Not available: not finished** |
| Reported peak resident memory across completed QA worker slices | 27,213,824 bytes (27.2 MB) |
| QA database size | 1,269,297,152 bytes |
| QA database increase over verified history copy | 1,266,102,272 bytes (1207.4 MiB); not a final footprint |
| Navigation median | 10.05 ms |
| Largest-directory median | 13.41 ms |
| Largest-file median | 17.05 ms |
| Indexed search median | 13.78 ms |
| Completed existing Homebrew configuration subtree | 69 entries: 11 directories, 22 regular files, 36 symlinks; 0 pending/gaps |
| That subtree's initial indexing | 0.569 s; peak RSS 11.9 MB |
| Host FSEvents fixture initial index | 0.719 s; four directory listings / 1,004 entry observations (root excluded) |
| Host FSEvents incremental pass | 1.295 s end to end, 3 directory listings / 1,002 entries; completed without rebuilding the fixture |
| Competing capacity insert/rollback probe | 30/30 post-watchdog probes succeeded; median 0.491 ms, maximum 22.567 ms; history rows retained |

Query figures are five-run medians for 100-item pages and include process startup/JSON transport. Counts from separate live queries can differ slightly while the worker commits new batches. The peak is the maximum reported by completed slices, not a claim that every future slice or dataset has this peak. A whole-volume duration cannot be inferred by multiplying the small-subtree benchmark.

A real initial contention probe failed the three-second lock timeout. After adding an unlocked yield between inventory transactions and coalescing ancestor updates per batch, the same probe passed. The capacity measurement itself took 264 ms. This probes capacity acquisition and competing database writes, **not a full new-monitor attribution check against the shared QA catalog**. Existing production monitoring continued: its 07:30 UTC attribution check completed in 13.003 s while QA indexing was active. A comparable quiet-machine four-second baseline was not controlled, so zero slowdown is not claimed. No recurring 90-second delay was observed in these checks.

The real FSEvents fixture verified file creation, deletion, modification and cross-parent directory movement, including preservation of the moved directory ID and a terminal complete state. A sandboxed attempt could not obtain event identity and exercised the stale/gap fallback; the successful ordinary-replay evidence comes from the host run. A final replay can leave newly queued work visible rather than label a changing volume complete.

## Viewer and test verification

The final native QA viewer was exercised against the completed real Homebrew subtree: actual logical/allocated values and complete coverage were rendered; opening a folder changed the path and child count; largest files displayed 22 entries; indexed search returned matching entries. The earlier full-volume QA browser displayed partial/stale progress, supported search and directory navigation, and retained committed results after interruption. Native screenshots and Accessibility values were inspected. Screenshot-by-title sometimes selected a desktop thumbnail; direct region capture verified the actual window. The standalone AX test executable could not run because that executable lacked Accessibility trust; no permissions were changed to enable it. UI refresh scheduling is implemented through the shared request-file API; exhaustive automated native interaction coverage has not been established.

| Check | Result |
| --- | --- |
| `scripts/test-inventory.sh` | **84 passed** |
| Explicit new monitor binary `self-test` | **192 passed** (includes the existing coverage suite and 12 inventory core checks) |
| `scripts/test-gui.sh` | **273 passed**, plus no-notification-link and read-only live-capacity checks |
| Monitor and viewer release builds | Passed |
| `git diff --check` | Passed |
| Benchmark Python compile check | Passed |
| QA/backup integrity and original-table comparison | Passed |

Inventory fixtures cover parent/child integrity, independent aggregate accounting, hard links and cross-parent owner updates, actual metadata versus counted allocation, sparse files/APFS clones, symlinks, canonical/firmlink paths, create/delete/modify, directory rename/move and destination-only refresh, replacement at the same path, empty/large/protected directories, denied metadata, interruption/resume/prefix replay, concurrent writers/readers, additive migrations, generation replacement, search/pagination, event gaps and event-identity loss/recovery. New gap tests verify committed invalidations are visible before application, a newer gap restarts an older frontier, and unrelated current branches survive a stale sibling aggregate.

Existing-suite failures seen under the sandbox reproduced on unchanged HEAD; the host suite results above are the acceptance evidence. An independent Opus design consultation identified the invalid durable-directory-cookie approach, which was removed and verified against directory API semantics. A later requested cross-model diff review could not finish because its provider session limit was reached; no successful final cross-model review is claimed. Focused read-only worker review and primary source/test verification were completed.

## Performance follow-up — 11:08 UTC

The unattended run exposed a catalog-size-dependent SQLite planning defect. Sampling the isolated worker found 1,903/1,918 worker samples in the moved-directory lookup. SQLite chose the generation/kind index, scanning directory rows for each new directory object. The primary verified the plan: 24.19 ms for an absent object versus 0.037 ms through the existing object index. The lookup now explicitly selects that index; no index-building migration was added.

Old invalidations were also waiting behind the initial job queue. The worker now applies a bounded 64-row page between directory jobs, with a synthetic interruption regression. On the retained real catalog, all 5,132 queued invalidations drained within 42.3 seconds. The post-fix write probe passed 20/20 inserts/rollbacks, median 0.516 ms, maximum 23.137 ms, with no history change. The full volume is still being indexed; these figures do not establish its final indexing duration. See `performance-fix-start.json`, `performance-fix-progress.json`, `capacity-concurrency-after-plan-fix.json` and `after-plan-fix-benchmark.json` under the QA evidence directory, plus `build/inventory-profile.txt`.

The follow-up profile then found 84.8% of worker wait in the intentional fairness delay. Completed small sibling listings now share bounded commits (at most four listings and 256 entries), with commit-time snapshot revalidation outside the write lock and a 100 ms flush target checked between reads. Large or unfinished listings retain their original commit behavior. The fairness delay remains after every outer commit. Injected third-listing failure verifies atomic rollback; entry-budget interruption and resume verify durable counts and aggregates. All 68 inventory checks pass. Safe container listings can share a commit too; directory identity preflight covers every status and non-traversable entry, and relocations commit immediately. New tests cover child-job discovery after interruption and old-path jobs for a stale moved directory. The rebuilt monitor suite passed 192 checks. The first grouped-commit write probe passed 30/30 transactions (median 0.338 ms, maximum 38.072 ms), preserving all history rows. The expanded safe-container build added 24,886 entries in 150.7 seconds (165 entries/second) with zero queued invalidations. This is a workload-specific observation, not a projected whole-volume duration. See `safe-container-start.json`, `safe-container-progress.json` and `capacity-concurrency-final.json`. Legacy CLI commands retain main-actor execution for AppKit/notification behavior; the new and installed binaries reported identical notification settings without requesting authorization. Changed/unavailable directory jobs now close their live directory handle immediately; the mutation/resume fixtures still pass.

The final host FSEvents fixture passed all checks again: create/delete/modify, sparse allocation, preserved cross-parent move identity, exact independent logical/allocation oracle totals, and terminal complete state. Its initial pass was 0.719 s and its incremental pass 1.295 s (3 directories / 1,002 entries), with peak RSS 12.7 MB. The safe-container build’s competing-write probe passed 30/30 transactions, median 0.384 ms and maximum 22.152 ms, with all inserts rolled back and history preserved. Selected-home-subtree largest-file/folder medians were 15.96/14.71 ms. Evidence: `events-final-results.json`, `capacity-concurrency-final.json` and `subtree-benchmark-final.json`.

## Convergence and write scheduling follow-up — 19:52 UTC

Two bounded workers investigated the live queue and reconciliation source. Normal locked read-only snapshots showed one old full-root manual refresh, no invalidation backlog and a current event cursor. Its frontier was advancing through a catalog that kept growing: reconciliation had no persistent endpoint and unnecessarily included newly discovered directories. `inventory_reconcile.end_node_id` now captures a finite global node high-water mark. New gaps restart the frontier and replace its endpoint; legacy passes conservatively adopt the current maximum. The running QA pass retained its work and recorded endpoint 2,638,771 while the catalog advanced beyond it. No old work was deleted or certified through ambiguous timestamps. Added migration and old-pass/new-gap regressions pass.

A fresh process profile found 1,785/2,452 worker samples in the deliberate commit sleep. Under `taskpolicy -b`, requested 10 ms sleeps measured a 92.31 ms median; requested 2 ms sleeps still measured 54.67 ms. The worker now checks a monotonic 50 ms cadence at transaction boundaries and provides an unlocked 2 ms requested sleep when due, rather than sleeping after every tiny transaction. It updates that cadence after the actual sleep returns. A subsequent sample contained 825/2,257 samples in commit sleeps (workloads differ; this is not a controlled speedup benchmark). A 100-insert/rollback contention probe passed with median 0.340 ms and maximum 91.577 ms, retaining all history rows. Evidence: `capacity-concurrency-after-convergence.json`, `build/inventory-current-profile.txt`, `build/inventory-cadence-profile.txt`.

The inventory counter trigger also used to update statistics when an UPDATE assigned unchanged kind/status values. It now has an exact-change guard. Existing definitions upgrade atomically once without recomputing counters. Tests verify preserved counters, absence of extra stats writes on a no-op update, and correct real bucket transitions. The inventory suite now passes 78 checks, and the final guarded-trigger monitor build passed 192 checks. The viewer source is unchanged.

At 19:52 UTC the QA worker was briefly paused for a consistent integrity check: `quick_check` returned `ok`, `foreign_key_check` returned no rows, and all seven original monitor tables still matched the backup. The catalog database was 1,308,831,744 bytes at that check. The latest worker resumed against that retained catalog; this is still not terminal whole-volume acceptance. At 19:56 UTC its catalog held 2,813,625 entries; the installed trigger guard was verified directly in SQLite and the old refresh endpoint remained 2,638,771 while its frontier advanced to 137,732. The new catalog growth therefore did not extend that pass. See `preservation-after-convergence.json`, `convergence-fix-start.json`, `convergence-fix-progress.json`, and `worker-build.json`.

## Identity-replacement stall — 20:21 UTC

A new profile showed repeated `restartInventoryJob` transactions rather than productive traversal. The Command Line Tools subtree had been replaced during indexing: sampled pending jobs retained old inode identities and had accumulated more than 500–650 retries. Existing restart logic did queue parents, but keeping mismatched children pending and repeatedly postponing parent timestamps could starve the hierarchy repair. A simple isolated child-replacement test passed on the old code; a deterministic interruption test exposed the missing invariant and failed before the fix.

Identity mismatch now retires that obsolete child job as unknown with null totals and leaves parent repair pending with cleared checkpoints. Parent relisting adopts the replacement object and normal pruning removes obsolete descendants. Same-identity directory-content changes retain ordinary checkpoint restart behavior. Root replacement leaves its old job pending and requires retry into a new generation, preventing false terminal completion.

The real QA cohort contained 264 repeatedly retried jobs. By 20:21 UTC all 264 had completed with replacement inode identities and cleared reasons; none increased its retry count. The old refresh frontier advanced beyond the stalled section. The inventory suite passes 84 checks, including the failing-before intermediate invariant, directory-to-file replacement and root-generation replacement. The final monitor build passes 192 checks. No production state was changed. Evidence: `identity-retry-start.json`, `identity-retry-progress.json`, `build/inventory-stalled-phase-profile.txt` and `build/inventory-identity-regression-before.log`.

This resolves the demonstrated stall, not the entire indexing duration. The old bounded refresh and deferred pruning still need to drain. Directory-state counters alone omit unexpanded reconciliation work and are not a completion-time estimate.

## Limits and next step

At 12:43 UTC the unattended crawl had advanced to 1.22 million catalog entries. Two subsequent 20-minute worker slices completed their budgets normally (107,304 and 98,549 entry observations), with no additional blocked-open reports. Production’s 12:30 UTC comprehensive check completed in 6.852 seconds. The catalog still has 43,160 pending directories plus stale reconciliation work; this is progress, not terminal acceptance or a reliable completion-time estimate.

The final continuation found a real blocked directory open in the QA worker. A process sample showed `InventoryOpenDirectory` waiting in `open$NOCANCEL`; the committed catalog remained usable. Inventory now uses the existing coverage watchdog with a 60-second inactivity limit and separate-connection recovery: mark the job unknown/blocked, preserve ancestor uncertainty, then exit so launchd can resume other work. Four added fixture checks verify durable unknown values, forward progress after recovery and explicit-refresh recovery. The inventory suite passes 72 checks. Actual startup-volume recovery is verified for the Music cache and its `fsCachedData` child: both became terminal blocked jobs with unknown size values, and the next worker advanced to other jobs. `blocked-io-recovery.json`, `worker.stderr.log` and process samples retain the evidence. A productive-enumeration heartbeat prevents long prefix replay from expiring solely because of elapsed time. The post-watchdog competing-write probe passed 30/30 inserts/rollbacks (median 0.491 ms, maximum 22.567 ms), and all seven original history tables still match the verified backup. The query table above also uses the new build.

- **The full Data-volume inventory is not complete.** Do not treat this phase as satisfying the entire definition of done yet. The final QA worker is running against the retained isolated catalog with production untouched; its own history-gap/permission states remain explicit.
- Full-volume final counts, initial duration, final memory peak, final database growth and repeated steady-state latency still need measurement after the first reconciliation drains. This development run includes multiple code-update interruptions and is not a clean uninterrupted cold-index benchmark.
- The M2 Air/8 GiB target has not been measured. Full-disk performance and a controlled full monitoring-check comparison need further evidence before installation.
- Permission/consent gaps, excluded mounted filesystems, cloud placeholders and the inventory's own operational metadata directory remain explicit. FDA is never assumed. Inaccessible content is not reported as zero.
- Reported allocation is not unique/reclaimable APFS physical storage. Snapshots/shared extents/compression and open-but-deleted files are not reconstructed into fabricated adjustments.
- Hard-link owning names can change after deletion. Parent sums count once; actual per-object metadata remains available on alias rows. APFS clone objects remain distinct.
- Prefix search is not arbitrary substring search. Queries have an explicit deadline; difficult searches/deep pages can return a retryable error. Historical per-node growth is not yet available.
- Heavy FSEvents intervals exceeding the bounded 4,096-path collector still fall back to full bounded reconciliation; event paging is not implemented. The demonstrated QA queue issue was the old manual refresh, not such an overflow.
- Superseded generations are retained. Generation replacement/index creation costs on a multi-million-node database and automatic compaction are not verified in this pass.

Historical next-step recommendation (superseded by the correction section above): let the isolated startup-volume job reach a terminal state, rerun `scripts/benchmark-inventory.py`, repeat integrity/preservation and concurrent-monitor checks, and verify the completed full-volume browser. Capture a clean initialization benchmark if needed, then validate the smaller machine. Production installation requires separate authorization. The luminous tree should consume the query API only after these acceptance gaps are closed.

## Local evidence

Evidence is intentionally under ignored `build/` because it contains local machine data and temporary QA bundles:

- `build/inventory-tests-final.log`, `build/monitor-tests-final.log`, `build/gui-tests-final.log`
- `build/inventory-build-final.log`, `build/inventory-gui-build-final.log`
- `build/inventory-verification/final-benchmark.json`
- `build/inventory-verification/capacity-concurrency.json`
- `build/inventory-verification/events-d7df0020-f2c1-412e-9e26-d05229085503/host-results.json`
- `build/inventory-verification/homebrew-benchmark.json`
- `build/inventory-verification/preservation-final.json`
- `build/inventory-verification/installed-binaries-final.json`
- `build/inventory-verification/production-copy.preinventory.sqlite3`
- `build/inventory-verification/worker-build.json`, `worker.stdout.log`, `worker.stderr.log`
- `build/inventory-verification/blocked-io-recovery.json`, `capacity-concurrency-after-watchdog.json`, `preservation-after-watchdog.json`
- `build/inventory-idle-profile.txt`, `build/inventory-recovery-profile.txt`
