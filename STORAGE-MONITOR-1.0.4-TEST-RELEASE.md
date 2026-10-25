# Storage Monitor 1.0.4 (build 5) — test release

Date: 2026-10-24. Built and verified on the Mac mini. **Not installed. Not committed.**

Evidence: `build/release-1.0.4/` (test logs, DMG log, checksums) and `build/release-1.0.4/evidence/`.

1.0.4 replaces 1.0.3 (build 4) as the build to test. Both the worker and the viewer change behavior, so it gets a new version rather than a second binary under 1.0.3 (4).

## Artifact

| | |
|---|---|
| DMG | `build/dist/Storage-Monitor-1.0.4.dmg` |
| SHA-256 | `56d4e17a70445d888609d3b2e3bcfde279c4d7c4c17d2b3e5f57275ee635caf2` |
| Viewer `StorageMonitorViewer` | `4be08106dddc75640b715afb410f2cf28ea759ca3202c13ac14ef798eb1b6786` |
| Helper `StorageMonitor` | `6c5185925ee711ced7892807c17b4d0fcaca6efe03c8bb639bdbcd8c3e8a37c8` |
| Versions | App 1.0.4 (5), helper 1.0.4 (5), read from the mounted image |
| Architecture | Both executables universal (arm64, x86_64), deployment target macOS 14.0 |
| Signature | Ad hoc; `codesign --verify --deep --strict` passes. Gatekeeper rejects it (expected for ad hoc). |
| Image | `hdiutil verify`: checksum VALID; `verify-dmg.sh` passes, including the bundled monitor's 233 tests run from the image |

## 1. Root causes

| Defect | Cause |
|---|---|
| "Show 2 folders" lists nothing | The list query filtered nodes by generation, so SQLite scanned every node: about 3 million on this Mac. It overran the viewer's 0.25 s read deadline, and the popover presented the error as "No folders are waiting." |
| Refresh looks like it does nothing | The refresh ran (about 40 minutes for a full recheck), but the status line said only "Reconciling filesystem changes", the message said "queued", and the reload button gave no feedback. |
| Prioritize did nothing visible | It moves the viewed folder to the front of the queue, which has no visible effect once the inventory is complete, and the confirmation never named the folder. |
| Banner overlap in tall windows | The section switcher was a row above the content. On macOS 26, the toolbar's scroll-edge blur is drawn at the top of the section content as if it began under the toolbar, so it covered "Internal storage" and the first overview rows. Reproduced offscreen with full-size content (`evidence/d6-before-tall-fullsize.png`). |
| Empty-screen flicker | The empty state was chosen by `!loading`. The panel reloads every 2 s, so it alternated between the empty state and "Loading inventory results…". |
| No estimate for 20 of 29 minutes | Only a queue-drain fit was used, and on a real disk the queue grows for most of the pass. |
| Quadratic listing of very wide folders (found during this pass) | A folder's partial size was re-summed over all its children at most once a second. For 200k+ entries a re-sum takes about a second, so it ran on nearly every batch: 500k files in one folder took 766 s. |
| Retained Foundation objects (found during this pass) | The worker runs as one long task that never drains an autorelease pool. Each mailbox check (every 250 ms) and each batch read left its enumerator, URLs and errors alive until exit. `heap` showed one set per check. |

## 2. Changes

**Worker** (`Sources/`):
- **Wide folders:** the partial-size interval is max(1 s, 10 × the folder's last re-sum time), so wide folders re-sum at most ~10% of the time. Completed totals are unchanged.
- **Autorelease pools:** around the request-mailbox check and each batch read.
- **Logging:** the log line adds `peak_footprint_bytes` (physical footprint, as Activity Monitor shows) next to the resident-size peak, so the two can be told apart.

**Shared presentation** (`SourcesShared/`):
- **Deferred-folder query:** driven from the deferred jobs (primary-key lookups).
- **Status:**
  - exposes `refreshFraction` and `refreshIsManual`;
  - a requested full refresh reads "Refreshing the entire inventory · about N% rechecked". The percentage is safe because the recheck has a fixed endpoint.
- **New estimator:**
  - **Before the queue drains:** a rough range. Remaining = (objects in use on the volume − items found) ÷ items/s, computed at both the pass's average rate and its recent rate. The object count comes from `statfs`, and is used only when the inventory root is the volume's mount point.
  - **Once the drain is measurable:** the drain fit.
  - **Smoothing:** the shown value is the median of the last nine estimates projected to now.
  - **Gaps:** gaps over 5 minutes between worker runs are excluded from the rate.
- **Placeholder:** `InventoryPlaceholder` decides the results-area placeholder from the status alone.

**Viewer** (`SourcesGUI/`):
- **Toolbar:** the section switcher is a segmented control in the toolbar; the duplicate "Disk Inventory" toolbar title is removed.
- **Deferred-folder popover:** shows Loading, the list, or "Couldn't load the list" with Try Again.
- **Refresh:**
  - the full-refresh progress bar sits under the status line;
  - the reload button shows a spinner while it reloads;
  - the request message explains what a full refresh does and clears once work starts.
- **Prioritize:** the button reads "Index “<folder>” First", appears only while indexing work is active, and its confirmation names the folder.

**Tests:**
- deferred list names the folder;
- manual-refresh headline and fraction;
- placeholder stability;
- early rough estimate and its preconditions;
- volume-count gating;
- the live-probe test now reports "inconclusive" instead of failing when Storage Monitor's own background process writes to its folder during the test.

## 3. Memory

**Isolated scans (current build):**

| Tree | Entries | Folders | Peak RSS | Peak footprint |
|---|---|---|---|---|
| `~/.cache` | 906,059 | few | 29.1 MB | 18.5 MB |
| `~/Library` | 543,387 | 88,869 | 29.0 MB | 20.1 MB |
| `~/Library`, WAL database plus a polling reader | 543,318 | 88,869 | 29.6 MB | 20.0 MB |
| `/Applications` | 283,572 | 31,857 | 28.0 MB | 18.3 MB |
| One folder of 50k / 200k / 500k files | up to 500,001 | 1 | 23.7–27.5 MB | 15.1–17.1 MB |
| 60,000 one-file folders | 120,060 | 60,061 | 25.1 MB | 15.6 MB |

**Production worker, read-only `vmmap -summary` during run 5:**
- footprint 20.8 MB, rising to 38.6 MB at the end of a 1,230 s run;
- SQLite page cache flat at about 8.5 MB, and purgeable;
- Malloc Small growing about 1 MB/min, with part of it already compressed or swapped, because the system was under memory pressure.

**Source attribution:**

| Candidate | Finding |
|---|---|
| SQLite statement caches | Ruled out. The only variable-shape statement is capped at 33 shapes by the 32-listing commit group, and the 60k-folder fixture showed no growth. |
| SQLite page cache | Flat at the default size, purgeable. |
| Directory batches | Flat across 50k–500k entries in one folder. |
| Pending queues and progress tracking | Database-resident. |
| Metadata caches | No evidence of growth. |
| Retained objects | Found: autoreleased Foundation objects from the mailbox check (about 1.5 KB per check, 4 per second), about 7 MB per 20-minute run. After the fix, `heap` shows the enumerators, errors and URLs gone. The live heap drops from 13,330 to 9,550 allocations, at 2.0 MB live. |

**Not explained:** the 85–132 MB resident peaks of the 1.0.3 production runs. No isolated run reproduces them, and the production footprint measured directly was 21–39 MB. Resident size includes memory the system can reclaim, which matters on this heavily loaded machine.
- **Correlation:** the peaks track folders per run (288k folders: 132 MB; 218k: 98; 226k: 85; 156k: 68).
- **Open question:** whether the peak was real dirty memory.
- **How it will be decided:** `peak_footprint_bytes` will settle it on the next production or Air run.

**Residue:** about 136 bytes per mailbox check remain in an XPC dictionary inside Foundation, about 0.65 MB per 20-minute run.

## 4. Time estimate

Replay of the real Mac mini first pass (174 samples, 29 minutes; `evidence/eta-replay-mac-mini-first-pass.txt`):

| | 1.0.3 | 1.0.4 |
|---|---|---|
| First estimate shown | 1,216 s ("about 20 minutes") | **61 s** ("Rough estimate: about 20 minutes", 28 minutes actually left) |
| First 15 minutes | "Estimating…" | Rough range 20–30 minutes against 28–15 actual: within about −20% to +35% |
| Mid-run (15–25 min) | 20 → 5 minutes | Drain fit: 15–20 minutes against 14–4 actual. Errs long by up to 2.9×, the same weakness as 1.0.3. |
| End (last 4 min) | "about 10 minutes" after the queue re-grew, then "less than a minute" | 5 → 2 → 3 → 2 minutes |
| Upward jumps | 3 → 10 minutes | 15 → 20 minutes once, when the drain fit took over at 17 min |

**Restarts:**
- Samples persist across worker runs, and gaps over 5 minutes are not counted as indexing time.
- An isolated `~/Library` scan in 30-second budgets ran four runs: three exits of 75 (`continuing`) and a final exit of 0 (`completed`).

**Limits:**
- **Subfolder roots get no early figure.** An inventory rooted below a mount point (only isolated tests) has no volume count. The 133-second `~/Library` restart test therefore showed "Estimating…" throughout; its drain window never reached 2 minutes.
- **Disk images can't be tested.** The worker refuses roots outside the startup Data volume, so the rough path couldn't be exercised on a disk image.
- **Measurement basis:** the production behavior above comes from the real Mac mini samples replayed through the new code, not from a live production scan with 1.0.4.

## 5. Refresh and UI verification

| Item | Verification | Status |
|---|---|---|
| Deferred-folder popover | Inventory test plus a read-only snapshot of this Mac's 3.45M-node catalog: the list returns the Chrome cache folder in about 0.1 s (before: deadline error) | Verified (data layer) |
| Full-refresh progress | Inventory test: headline "Refreshing the entire inventory · about 25% rechecked" with a valid fraction | Verified (presentation) |
| Refresh controls | Spinner and messages built; no live window check | **NOT VERIFIED on screen** |
| Prioritization only when useful | Shown only while indexing is active; built | **NOT VERIFIED on screen** |
| Prioritization reorders the queue | Existing progressive tests: the focused folder is measured while the wider index is incomplete; foreground turns are bounded at 3 per background turn; interrupted focus is retained | Verified (worker) |
| No empty-state flicker | `InventoryPlaceholder` is stable for the same status whether or not a reload is in flight (test) | Verified (logic); **NOT VERIFIED on screen** |
| Banner overlap | Offscreen render of a 1240×1100 window with full-size content: overlap gone (`evidence/d6-after-tall-fullsize.png`); 780 pt narrow window fine | Verified offscreen only; **NOT VERIFIED in a real window** |
| Toolbar segmented control | Offscreen, the selected segment draws as a blank pill. Most likely the capture cannot draw Liquid Glass vibrancy text, since the unselected segment draws normally. | **NEEDS YOUR CHECK** |

No GUI automation was used, and no app was launched or focused.

## 6. Background behavior (this Mac, production 1.0.3 helper)

| Run (UTC) | Duration | Status, exit | Notes |
|---|---|---|---|
| 1, 20:38 | 1,203 s | continuing, 75 | First pass |
| 2, 20:59 | 543 s | deferred, 0 | First pass complete at 21:07:52 |
| 3, 21:10 | 1,202 s | continuing, 75 | Your full refresh |
| 4, 21:30 | 1,098 s | deferred, 0 | Refresh finished, 1 folder deferred |
| 5, 22:00 | 1,230 s | continuing, 75 | Scheduled check; replayed 792,735 events caused by my test fixtures |
| 6, 22:22 | 1,214 s | continuing, 75 | Fixture pruning (peak 58.4 MB RSS) |
| 7, 22:41 | 858 s | deferred, 0 | Fixture work finished at 22:55:53 |
| 8, 23:00 | 24 s | completed, 0 | Scheduled check; ordinary event catch-up |

**Findings:**
- **No restart loop, no unexplained exits, no SQLite lock errors.** The only ERROR line in the log dates from 2026-10-21 (diskutil).
- **Every relaunch was explained:** a budget exit of 75, a scheduled check, or your refresh.
- **History intact:** 155 readings before the test, 160 now, and 52 alerts. `quick_check` ok on the snapshot.

**Self-inflicted load:**
- **Cause:** my memory fixtures (750k empty files under `/private/tmp`, on the indexed Data volume) made run 5 relist them with the old quadratic code.
- **Cleanup:** I deleted the fixtures at 22:24; runs 6 and 7 pruned them, finishing at 22:55:53.

**Idle between scheduled checks: confirmed.** Read-only `launchctl` polling every 20 s showed:
- the worker not running from 22:56 to 23:00 (exit 0);
- one 24-second scheduled run at 23:00 (exit 0);
- not running again from 23:00:41 to 23:25:43, a full 25 minutes, with no unscheduled launches.

## 7. Regression results

| Suite | Result |
|---|---|
| Inventory (`scripts/test-inventory.sh`) | **266/266** (`inv2.log`). The first run (`inv1.log`) failed one assertion that expected the old refresh headline; the expectation was updated to the new wording, with stricter conditions. |
| Monitor self-test | **233/233** from the build, and again from the mounted DMG |
| Viewer model tests | **357/357** |
| Builds | Monitor, viewer and DMG: no errors or warnings |
| Data preservation, pre-1.0.3 backup of this Mac | 155 readings, 48 alerts, 8 diagnostics, 155 evidence rows, 10 state rows before and after; `quick_check` ok |
| Data preservation, live 1.0.3 database (read-only `VACUUM INTO` snapshot) | 160 readings, 52 alerts, 9 diagnostics, 160 evidence rows, 12 state rows, 3,452,094 inventory nodes, 448 progress samples and the completion milestone, unchanged after `status` and `inventory-status` with the DMG's helper; `quick_check` ok |

**Wide folders:** 500k files in one folder took 766 s before the fix and 161 s after; 200k took 46 s before and 39 s after. Both after-runs overlapped other load.

## 8. Remaining risks

1. **Resident peaks:** the 85–132 MB production peaks are not reproduced or attributed. `peak_footprint_bytes` will tell whether they are real dirty memory.
2. **Drain fit:** it still errs long by up to about 3× in mid-pass, and rose once (15 → 20 minutes) in the replay.
3. **Subfolder roots:** no early estimate (affects tests only).
4. **UI on screen:** none of the UI changes is verified in a real window. The toolbar segmented control's selected label needs your check.
5. **Air:** nothing here was validated on the MacBook Air.
6. **D3 (pre-update snapshot retention):** still needs your decision on a retention policy.
7. **XPC residue:** about 0.65 MB per 20-minute run remains.

## 9. First milestone for the native filesystem explorer

**An expandable folder tree over the existing catalog.**

**What it shows:**
- a SwiftUI `Table` with row children (outline);
- columns: allocated size, logical size, items and coverage;
- sorted by allocated size.

**How it loads:**
- a folder's children load only when the row is expanded, through `InventoryReader.children` paging (first page of 200);
- nothing is materialized beyond the expanded rows.

**Interaction:**
- keyboard navigation (arrows expand and collapse);
- Reveal in Finder and Copy Path;
- the current "Includes earlier sizes", Partial and Access restricted wording.

**Acceptance:**
- expanding any folder of this Mac's 3.45M-node catalog shows its first page in under 100 ms;
- no read exceeds the existing 0.25 s deadline;
- memory stays flat while expanding 1,000 folders;
- sizes match `inventory-children` exactly.

The visual explorer (treemap or sunburst) builds on this tree in a later milestone.
