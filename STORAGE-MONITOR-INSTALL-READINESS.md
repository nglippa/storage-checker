# Storage Monitor: install readiness

2026-10-23. Working tree on `master` (HEAD `46cd268`, uncommitted).

**Verdict: ready for a controlled installation test. Not beta-ready.**

Every scheduling path from install to steady-state maintenance is accounted for. Four gaps were found and corrected in source, and every automated suite passes. What remains unverified is the real-machine behavior listed in §7. The DMG has not been rebuilt, and nothing was installed, deployed or committed. Production and the QA environment were not touched: production agent and app hashes still match `build/inventory-qa-upgrade-20261023/production-hashes-before.txt`.

## 1. Scheduling architecture, as audited before any change

The production install writes three per-user LaunchAgents (`MonitorInstallLayout.agents`, `Sources/StorageMonitor.swift`). QA does **not** match production: the QA worker has no periodic trigger.

| Label | Program | Trigger |
|---|---|---|
| `local.macbook.storage-monitor` | `check` | `RunAtLoad`, `StartCalendarInterval` :00 and :30 |
| `local.macbook.storage-monitor.baseline` | `initialize-baseline` | `RunAtLoad`, `KeepAlive {SuccessfulExit: false}`, throttle 300 s |
| `local.macbook.storage-monitor.inventory` | `inventory-work` | `RunAtLoad`, `KeepAlive {SuccessfulExit: false}`, throttle 60 s, `WatchPaths` = `inventory-requests/` |

| Question | Finding (before changes) |
|---|---|
| What triggers the initial inventory? | Bootstrapping the agent at install (`RunAtLoad`) starts it. `runInventory` creates the generation if none exists. Each unfinished slice exits 75, and launchd relaunches it after 60 s. |
| What triggers incremental maintenance? | Every scheduled `check` ends with `launchctl kickstart gui/<uid>/…inventory` (no `-k`). The worker also starts when the viewer writes to `inventory-requests/`, and at login. |
| Does a successful exit leave maintenance scheduled? | **Yes, in production.** Exit 0 is not relaunched by `KeepAlive`, but the next :00/:30 check wakes the worker. (QA has no such check, which is why QA runs needed manual starts.) |
| Is a deferred directory eventually retried? | Yes. Deferral was run-local only, so the next wake retries it. **However**, see gap G2. |
| Sleep and wake | Calendar intervals missed during sleep run once on wake, and that check wakes the worker. A worker suspended mid-run continues after wake. |
| How long can the Mac be inactive before FSEvents history is unusable? | Apple's header (`FSEvents.h`, `FSEventsCopyUUIDForDevice`) documents a persistent per-volume database. A *discarded* database gets a new UUID, which the code detects. It documents no retention period and no signal for partial trimming. The code imposes its own 6 h wall-clock limit (`maxReplayAge`). **Gap G1.** |
| Does an expired cursor cause a safe reconciliation? | Yes. Expiry queues one full-volume gap invalidation, the existing tests show it drains, and the catalog then matches disk. It is safe, but on 2.9 M entries it is expensive. |
| Does a reboot preserve pending maintenance? | Yes. Jobs, invalidations, reconciliation frontier and cursor are durable in SQLite. `RunAtLoad` at login restarts the worker. LaunchAgents run only while the user is logged in. |
| Can runs overlap? | No. launchd runs one instance per label, and `kickstart` without `-k` never restarts a running job. `inventory-command.lock` and `inventory.lock` (non-blocking `flock`) refuse a second worker, which reports `busy`. |

### Gaps found

- **G1. Overnight sleep forces a full-volume rescan.** Cursor age was measured in wall time, so any sleep or shutdown over 6 h expired it and queued a whole-volume reconciliation on the next wake. For a laptop closed overnight that means one rescan every morning. The earlier steady-state rationale ("a quiet volume is acknowledged on every slice, so its cursor never ages") holds only while the Mac is awake.
- **G2. The production slice was too short for the deferral to work.** The agent passed no `--budget`, so each slice got the 20 s default. Candidate 2 averaged about 5 s per Chrome cache relist, so three retries plus event replay may not fit in one 20 s run. Deferral counts were run-local, so a run that hit its time limit first exited 75, the next run started counting from zero, and the worker could relist Chrome about once a minute indefinitely. QA was verified at 1,200 s and never exercised this.
- **G3. A first-pass directory that never stops changing blocked completion.** The first-pass milestone needs every first-listing job finished. A Chrome cache that changes during every listing of the *first* pass keeps `completed_token=0` forever, so the viewer would show "Building your storage inventory" indefinitely.
- **G4. The viewer treated a deferred folder as active indexing.** Its job counted as a queued listing, which kept `indexingActive` true. The viewer then re-queried status every 2 s while visible, and showed "1 listings queued" while nothing was running.

## 2. Changes made (source only; uncommitted)

| File | Change |
|---|---|
| `Sources/Inventory.swift` | `InventoryEventCursor.age()` counts **awake time within one boot session** (`CLOCK_UPTIME_RAW` stops during sleep; Power Nap dark wakes still count; boot session from `kern.bootsessionuuid`). After a restart, or for a cursor without a stored session, it uses wall time as before. Additive migration: `inventory_event_cursor.boot_session TEXT DEFAULT ''`, `awake_at REAL DEFAULT 0`. One helper writes all three cursor acknowledgements. A deferral writes `inventoryDeferredReason` to the job and node; the next listing attempt clears it. The first-pass predicate ignores first-listing jobs with that reason. |
| `Sources/InventoryCommands.swift` | The inventory agent runs `inventory-work --budget 1200`, the configuration verified on QA. The cursor check and replay budget use `cursor.age()`. The exit policy is extracted as `inventoryWorkExitCode` without behavior change. |
| `Sources/StorageMonitor.swift` | The check's wake is extracted as `scheduledInventoryWake`. Behavior is unchanged, and it returns nil when the agent is not installed. |
| `SourcesShared/InventoryModels.swift` | `inventoryDeferredReason` is moved here from the worker. `InventoryStatus` gains `deferredDirectories` and `eventHistoryUnavailable`. First-pass discovery ignores deferred jobs. New `InventoryReader.deferredDirectories(limit:)`. |
| `SourcesShared/InventoryPresentation.swift` | New `InventoryCondition` (A–E), plus `affectedDirectories` and `activeListings`. The first-pass panel is hidden when only deferred folders remain. |
| `SourcesGUI/InventoryView.swift` | The busy state and "listings queued" exclude deferred folders. A "Show folder(s)" link opens a native popover listing each deferred folder with its previous size and a **Show** button. No new window or dashboard. |
| Tests | `tests/InventoryReconciliationTests.swift`, `tests/InventoryReconciliationScenarios.swift`, `tests/GUIModelTests.swift`, `Sources/InstallSelfTest.swift` |

**Why awake time is safe.** fseventsd trims the oldest history as event volume accumulates, and a sleeping Mac records almost no events. The existing policy already accepted up to 6 h of awake activity; that limit is unchanged and now excludes only sleep, so the exposure to a silent trim is the same as before. A changed database UUID, dropped or wrapped events, a root rescan and a regressed cursor still cause reconciliation. A cursor from a previous boot keeps the wall-clock rule, because the awake time before shutdown is unknown. This is an inference from the documented design, not an Apple guarantee, so step 7 of §8 checks it on real hardware.

Nothing else changed: no new service, no polling loop, no change to the 6 h limit, retry limit, engine traversal or monitor coverage.

## 3. Inventory status semantics

The viewer derives one condition from durable state (`InventoryStatusPresentation.condition`). Stale values are never hidden: they render as "Previously …", and rankings stay qualified as partial.

| Condition | When | Headline (examples) |
|---|---|---|
| — not started | no generation | Inventory has not started |
| **A** initial inventory | first pass unfinished (`initial_completion='pending'` with first-listing work) | first-pass panel, plus "Discovering files and folders" |
| **B** current | first pass done; nothing queued, stale or deferred | Inventory is up to date |
| **C** stale or deferred | listings queued, stale folders, or deferred folders | "Updating changed folders" · "Updates are pending" (states the folder count) · **"Up to date except 1 folder that keeps changing"** with a "Show folder" popover |
| **D** reconciliation | reconcile, prune or tombstone work | "Rechecking after missed file events" or "Reconciling filesystem changes" |
| **E** unavailable or failed | event history unavailable with no reconciliation running; reader errors use the existing error banner with Retry | Changes can't be tracked right now |

A Chrome cache that changes during every listing now produces condition C with one affected folder. It never makes the inventory look like a first scan, and the folder is retried on every scheduled update.

## 4. Test results (2026-10-23, this working tree)

| Suite | Result | Previously |
|---|---|---|
| `scripts/test-inventory.sh` | **243 / 243 passed** | 227 |
| `scripts/build.sh` + `StorageMonitor self-test` | build OK; **231 / 231 passed** | 227 |
| `scripts/test-gui.sh` | **339 / 339 passed** | — |
| `STORAGE_MONITOR_SDK_PATH=…MacOSX26.5.sdk scripts/build-gui.sh` | build OK, no warnings | — |

New coverage. All tests run on isolated `/private/tmp` fixtures with real FSEvents replay, and on an isolated home with a recording launchd fake.

- **Idle exit, then scheduled maintenance:**
  - the exit policy as launchd applies it: 75 for unfinished or busy runs; 0 for complete, partial, stale, paused and deferred-only runs;
  - after an idle exit the scheduled check produces `kickstart` without `-k`;
  - the agent plist has `KeepAlive SuccessfulExit=false`, `WatchPaths`, no interval of its own, and `--budget 1200`.
- **Deferred directory retried in a later run:** with the folder still changing, the second run retries it exactly 3 more times and defers it again. Once quiet, the next run lists it and the catalog matches disk.
- **Sleep, wake and reboot:**
  - 9 h asleep with 10 min awake → `applied`, nothing full-volume queued;
  - previous boot, 1 h of wall time → `applied`;
  - previous boot, 9 h → `gap`, then the reconciliation drains to a catalog that matches disk;
  - 7 h awake → `gap`;
  - legacy cursor row, 9 h → `gap`.
- **No overlapping workers:** a held `inventory.lock` makes a second worker report `busy` (exit 75, retried later), and a second `inventory-command.lock` is refused.
- **First pass with one stale directory:** a first pass where only `Cache_Data` (4,000 files) changes on every listing records the milestone. The folder stays unlisted, deferred and stale, the first-pass panel is hidden, and the condition is C with one affected folder. Once quiet, all 4,000 entries are listed and the condition is B.
- **State transitions:** A → C → B (engine and presentation); D for gap recheck and cleanup; E for unavailable history; D takes precedence over E while history recovers.
- **Background monitoring disabled:** after `uninstall`, no check wakes the worker, and a check against another data directory never wakes it.

## 5. Installation path review (read-only; nothing installed, DMG not rebuilt)

| Item | Status |
|---|---|
| DMG build process | `scripts/build-dmg.sh` builds a universal app, signs it (ad-hoc by default, or `STORAGE_MONITOR_SIGN_IDENTITY` with hardened runtime), and finishes with `scripts/verify-dmg.sh` (mounted `-nobrowse`, runs the bundled self-test). **The existing `build/dist/Storage-Monitor-1.0.0.dmg` (Oct 23 02:03) is stale.** It predates candidate 3 and these changes and must not be used for the test. |
| First-launch consent | There is no automatic first-launch prompt. Monitoring stays off until the person chooses **Settings → Enable Background Monitoring…**, whose alert lists all three tasks, including "Disk inventory indexing at low priority. The first pass over a large disk can take hours." Until then the inventory view says "Background indexing has not been installed." Enabling starts the first pass immediately (`RunAtLoad`). |
| LaunchAgent installation and removal | Transactional install, verified against an isolated home: three agents, each enabled, bootstrapped and confirmed with `print`. `uninstall` boots out and removes all three and keeps history and the helper. Real launchd registration: **NOT VERIFIED.** |
| Upgrade preserves databases | Verified in isolation: an APFS-clone snapshot; history row counts preserved; additive migration (this change adds two defaulted columns, so the update keeps one `history.pre-update-*.sqlite3`). |
| Interrupted upgrade recovery | Verified in isolation: fault injection at each of the 6 phases restores the previous helper and agents; a killed update leaves a journal that recovery reverts; after registration the update completes and is never rolled back. |
| Uninstall | Disable removes the agents only; app removal and data deletion are manual and documented (`PACKAGING.md`). |
| Signing | The development build is `Signature=adhoc`, no team, and `codesign --verify --strict` passes. Gatekeeper rejects ad-hoc builds, as expected. A *downloaded* ad-hoc helper may be silently blocked from running under launchd: **NOT VERIFIED**; quarantine is detected and reported. |
| Version detection | "Update available" compares bundle versions. A rebuilt DMG that is still `1.0.0` would not be offered as an update over an existing 1.0.0 install, and an older install's inventory agent would keep its 20 s slices. Build the test DMG with a new version. |

## 6. What this change does not cover

- QA still runs candidate 3 (`e8e56008…`), without the awake-time cursor or the durable deferral marker. No QA deployment was authorized.
- The native viewer was built but not launched. The popover, the status wording in context and the 30 s versus 2 s refresh behavior are **NOT VERIFIED**: no GUI interaction is permitted on this Mac.

## 7. Remaining risks

1. **Awake-time cursor age rests on fseventsd's trimming being driven by event volume.** That fits the documented persistent database, but Apple does not state it. The exposure is equal to the previous 6 h awake window, but a silent trim during sleep would go undetected. It is checked in §8.
2. **Restart after more than 6 h** (shutdown overnight) still triggers one full-volume reconciliation. That is safe but costly; on 2.9 M entries the QA reconciliation took about three 1,200 s slices at about 80% of one core. Measure it on the Air.
3. **Persistent worker failure** (`outcome: failed`, for example a full disk or a damaged database) exits 1, and launchd retries every 60 s indefinitely. Each retry is short, but the viewer does not surface worker failures; they appear only in `monitor.log`.
4. **Each scheduled run retries a deferred folder 3 times.** On QA a maintenance run cost 31–40 CPU-s every 20+ min, about 2–3% of one core averaged. Measure it on an 8 GB M2 Air with Chrome open.
5. **The first pass on 8 GB.** The worker's RSS peaked at 28–39 MB on QA, but the catalog database reached 1.49 GB for 2.9 M entries and SQLite page cache competes with apps. Watch memory pressure and swap.
6. **Without Full Disk Access** outcomes are `partial`, protected folders show as inaccessible, and condition B reads "Showing available measurements".
7. **LaunchAgents run only while logged in.** Fast user switching or a logged-out user means no maintenance; the cursor is then aged by wall time after a reboot.

## 8. Next steps: isolated installation test on a MacBook Air M2 (8 GB)

**Approvals still needed:** rebuilding the DMG, and installing on the test Mac.

1. **Build** (dev Mac, once approved): `STORAGE_MONITOR_VERSION=1.0.1 STORAGE_MONITOR_BUILD=2 scripts/build-dmg.sh`. It must finish with `verify-dmg.sh` passing, including the 231-test self-test from the mounted image. Record the DMG's SHA-256.
2. **Transfer without quarantine** (USB disk or `scp`, not a browser download or AirDrop). On the Air, `xattr -l Storage-Monitor-1.0.1.dmg` should show no `com.apple.quarantine`. If it does, follow PACKAGING.md → Gatekeeper.
3. **Isolate:** use a dedicated standard user account on the Air, with no existing `~/Library/Application Support/MacBook Storage Monitor`. Record a baseline:
   - `df -h /System/Volumes/Data`
   - `sysctl vm.swapusage`
   - `memory_pressure | tail -1`
   - `pmset -g log | tail -5`
4. **Install:**
   - Drag the app to /Applications, open it, then **Settings → Enable Background Monitoring…**. Confirm the alert text lists the three tasks.
   - Then run `launchctl print gui/$(id -u)/local.macbook.storage-monitor.inventory | grep -A8 arguments`. The arguments must include `--budget 1200`.
   - `ls ~/Library/LaunchAgents | grep storage` must list exactly three plists.
5. **Initial inventory, without Full Disk Access first.** Every 30 minutes, record:
   - `tail -3 "~/Library/Application Support/MacBook Storage Monitor/monitor.log"` (lines `inventory {…}` and `inventory events {…}`);
   - `ps -o pid,rss,%cpu,etime -p $(pgrep -f inventory-work)`;
   - `memory_pressure | tail -1` and `sysctl vm.swapusage`.

   Pass criteria:
   - no swap growth attributable to the worker;
   - worker RSS under 100 MB;
   - slices of 1,200 s or less with a 60 s gap;
   - the viewer shows the first-pass panel (A) until `inventory-status` reports `"initialCompletion":"complete"`.
6. **Steady state**, after the first pass completes:
   - Between :00/:30 wakes, `pgrep -f inventory-work` returns nothing and CPU is 0.
   - Each wake logs one `inventory events {"outcome":"applied"…}` and one run of 120 s or less that exits 0.
   - With Chrome open and browsing, `StorageMonitor inventory-status` shows `"deferredDirectories":1`, and the viewer reads "Up to date except 1 folder that keeps changing", with a "Show folder" popover listing `…/Google/Chrome/Default/Cache/Cache_Data`.
   - After Chrome quits, the next wake returns to B.
7. **Sleep:** close the lid for at least 8 h overnight. On wake, the first `inventory events` line must be `"outcome":"applied"`, not `gap`, and `inventory_reconcile` must stay empty. Check this on a `cp -c` copy with `sqlite3 copy.sqlite3 "SELECT COUNT(*) FROM inventory_reconcile"`. Spot-check two changed folders against `du -sk`.
8. **Reboot:**
   - Restart (under 6 h): expect `applied`.
   - Shut down for more than 6 h: expect one `gap` and a reconciliation that drains. Record its duration and CPU.
9. **Full Disk Access:** grant it to `~/Applications/MacBook Storage Monitor.app`. Outcomes should move from `partial` toward `complete` on later runs.
10. **Upgrade:**
    - Build 1.0.2 (build 3), then **Settings → Update Background Monitor…**.
    - Compare `SELECT COUNT(*) FROM inventory_nodes` and `readings` on `cp -c` copies taken before and after.
    - Expect no full rescan, and at most one `history.pre-update-*.sqlite3`.
11. **Uninstall:** **Settings → Disable…**. All three plists must be gone, `launchctl print …inventory` must fail, and history must be retained. Then follow PACKAGING.md → Uninstalling.

**Stop the test** on any of:

- a `gap` after sleep;
- a worker that relaunches every minute without making progress;
- worker RSS over 200 MB, or sustained memory pressure "critical";
- any loss of history rows across an upgrade.
