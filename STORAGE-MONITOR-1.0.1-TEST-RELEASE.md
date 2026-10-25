# Storage Monitor 1.0.1 (build 2): installation-test release

2026-10-23. This is a test release for one **explicitly authorized**, controlled installation test on a MacBook Air M2 (8 GB). It is **not notarized** and not beta-ready. Nothing has been installed on either Mac.

| | |
|---|---|
| DMG | `build/dist/Storage-Monitor-1.0.1.dmg` |
| SHA-256 | `43e5ac511ae3ef472ee349b608094e7ca3b868cb4dbe2db18c3e269e649ccdee` |
| Size | 9,623,852 bytes |
| Version | 1.0.1 (build 2) for both the app and the bundled helper |
| Signing | ad-hoc (`Signature=adhoc`, no Team ID); Gatekeeper assessment `rejected` (expected) |

Evidence files are in `build/release-1.0.1/`.

## 1. FSEvents safety review

**Conclusion: the awake-time threshold is kept.** It accepts no more unobserved event history than the previous wall-clock rule. One unrelated defect, in how drops were handled, was found and corrected (§2).

The basis is the local SDK (`MacOSX26.5.sdk`: `FSEvents.h`, `clock_gettime(3)`), the implementation, and a read-only replay probe run on this Mac.

| Requirement | Verdict | Evidence |
|---|---|---|
| 1. A valid replay cursor is required | **PASS** | `reconcileInventoryEvents` requires a cursor stored under the volume's current FSEvents UUID (`FSEventsCopyUUIDForDevice`), with `cursor.eventID ≤ marker`. Anything else queues a full gap. A missing UUID enters the identity-unavailable state, where values stay stale, rather than replaying. |
| 2. Dropped events trigger reconciliation | **PASS after correction** | `FSEvents.h`: a drop (`MustScanSubDirs` + `UserDropped`/`KernelDropped`) means "the client must do a full scan". Previously a drop whose ID was past the replay marker was ignored while the cursor still advanced. Now any drop during a replay is loss. |
| 3. Root changes trigger reconciliation | **PASS** (by root identity, not by an FSEvents flag) | `RootChanged` is delivered only to streams created with `WatchRoot`, and always with ID 0. The inventory stream does not set that flag, and production's root is the Data volume's mount point. Root changes are caught on every run by `prepareInventoryRoot`, which compares device, inode, birth time and volume UUID; a mismatch supersedes the generation and starts a new first pass. A root-level `MustScanSubDirs` is loss. |
| 4. Expired history triggers reconciliation | **PASS** | Expiry checks: a database discarded by macOS (new UUID) leaves no cursor, so it is a gap; a wrapped event ID is loss; a regressed cursor is a gap; age past `maxReplayAge` (6 h) is a gap. Tests: legacy row 9 h, 7 h awake, and a 9 h-old cursor from a previous boot each produce a gap that drains to a catalog matching disk. |
| 5. IDs not assumed consecutive | **PASS** | Each event is filtered on `cursor < id ≤ marker`, never by a running maximum or by contiguity. The boundary is `HistoryDone`, then `FSEventStreamFlushSync`, after which every event up to the marker has been delivered whatever order the IDs arrived in. The cursor advances only to the marker taken before the stream was created. |
| 6. Sleep or wake never advances the cursor silently | **PASS** | The cursor is written in exactly three places, and none depends on age: (a) after a complete replay; (b) together with a gap invalidation, or with identity recovery and its full invalidation, in one transaction; (c) on a generation's very first run, when no cursor exists for the UUID. A retry, timeout, stall or unavailable stream leaves the event ID and acknowledgement time unchanged (existing test). Age only decides between replay and gap. |
| 7. A reboot uses the wall-clock fallback | **PASS** | Awake time is used only when the stored `boot_session` equals the current `kern.bootsessionuuid` and the stored uptime is not ahead of the current one. Any other cursor (previous boot, legacy row, older binary) uses wall time. Tests cover 1 h (`applied`) and 9 h (`gap`) across a restart. |
| 8. Acknowledged only after durable application | **PASS** | Changed directories, including spills at the memory limit, are written as durable invalidations in transactions of 4,096. Only then is the cursor acknowledged, in a separate final transaction. A spill failure throws before acknowledgement, so the same history is replayed (existing test). Relisting is durable queued work afterwards. |

### Why awake time is safe

- **The clock:** `CLOCK_UPTIME_RAW` "does not increment while the system is asleep" (`clock_gettime(3)`). Dark wakes (Power Nap) are awake time and count. While asleep, nothing can modify the volume: another OS, recovery or disk sharing all require a reboot, which falls back to wall time.
- **The documented failure mode:** history becomes invalid when macOS discards the database, which changes the UUID. The UUID check catches that whatever the age.
- **The undocumented failure mode:** silent trimming of the oldest records. Trimming follows the volume of recorded events, and the bound stays 6 h of *awake* activity, exactly what the previous rule already accepted while the Mac was awake. Sleep adds no events, so excluding it adds no exposure.
- **Measured retention on this Mac** (up 13 days; `build/release-1.0.1/fsevents-retention-probe.txt`, probe source alongside): replays from 6, 12, 24, 72 and 168 h ago each reached `HistoryDone`, delivered 1,455–2,313 events in a 30-minute window starting within a few thousand IDs of the requested position, and carried no drop or rescan flags. About 130 M event IDs of history were retained, far beyond 6 h of awake activity.
- **What is not guaranteed:** Apple documents no retention period, so this is evidence, not a guarantee. Step 7 of the test checks it on the Air.

## 2. Source corrections in this pass

`Sources/InventoryCommands.swift` (`reconcileInventoryEvents`): a `UserDropped` or `KernelDropped` callback at **any** event ID now marks the replay as loss. A full gap invalidation is queued, with the cursor at the marker, in the same transaction. Before this change, `CoverageActivity` counted a drop only when its ID was at or below the marker, and the inventory callback ignored IDs past the marker, so a client-side drop reported with a later ID could lose events while the cursor advanced.

The shared capacity-coverage classifier is unchanged, and so is its test, now relabelled as coverage-specific. A test-only hook (`inventoryReplayInjectedEvents`, compiled only under `INVENTORY_TESTS`) delivers synthetic callbacks before the real replay.

Regression tests, on a real fixture with real replay:

- an ordinary event after the marker is applied;
- a **user** drop after the marker produces a gap;
- a **kernel** drop after the marker produces a gap.

The tests were not run against the uncorrected code. Without the change, the drop path returns before any loss is recorded, so those two checks would report `applied`.

All earlier changes (awake-time cursor, 1,200 s slices, durable deferral, completion semantics, status A–E) are described in `STORAGE-MONITOR-INSTALL-READINESS.md`.

## 3. Build verification

| Item | Value |
|---|---|
| Source revision | `46cd26847b8ead7632d60c7a94a99f492eb2de8d` (`master`) plus an **uncommitted** working tree (54 changed or untracked paths) |
| Working-tree fingerprint | `ab5c5e85f180dc8f13121a138f0b063d58db9be011ec78c6fb2ecfd08016850d`: the SHA-256 of `build/release-1.0.1/source-fingerprint.txt`, which lists the SHA-256 of 46 files (Sources, SourcesShared, SourcesGUI, tests, build/test/packaging scripts, icon) |
| Compiler | Apple Swift 6.4 (swiftlang-6.4.0.34.1, clang-2100.3.34.1), swift-driver 1.168.6, on host `arm64-apple-macosx27.0.0` |
| Configuration | `-O`, `-swift-version 5`, `-parse-as-library`, deployment target macOS 14.0, universal `arm64 x86_64` (DMG); viewer SDK `MacOSX26.5.sdk` |

| Suite or build | Result | Log |
|---|---|---|
| `scripts/test-inventory.sh` | **246 / 246 passed** | `inventory-tests.log` |
| `scripts/build.sh` + `StorageMonitor self-test` | **231 / 231 passed**, 0 warnings | `build-monitor.log`, `monitor-self-test.log` |
| `scripts/test-gui.sh` | **339 / 339 passed** | `gui-tests.log` |
| `scripts/build-gui.sh` (26.5 SDK) | OK, 0 warnings | `build-gui.log` |
| `scripts/build-dmg.sh` (1.0.1 / 2) | OK; `verify-dmg.sh` passed every check | `build-dmg.log` |

Development-build executable hashes (`dev-build-hashes.txt`; not shipped):

- monitor: `ce3f9cb8…22953`
- viewer: `d335cfe5…f2c8`

## 4. Package verification (`dmg-integrity.txt`, `dmg-contents.txt`)

- **Integrity:** `hdiutil verify` reports the checksum as VALID, and the SHA-256 matches `Storage-Monitor-1.0.1.dmg.sha256`.
- **Contents:** only `Storage Monitor.app` and an `Applications` symlink.
- **Identifiers:** the app is `local.macbook.storage-monitor.viewer` and the helper `local.macbook.storage-monitor` (background-only, `LSUIElement`). Both are version 1.0.1 (2) with a minimum of macOS 14.0.
- **Executables:** universal (`x86_64 arm64`), system libraries and runtime paths only, with no build-machine paths embedded.
- **Executable hashes in the image:**
  - helper `StorageMonitor`: `0bfa8bdea441b7cb049f215875c13da32997128fa0a5225fd30874c827a6add4`
  - viewer `StorageMonitorViewer`: `6b4e6917183e4b1289325a283d458bba964820b4d487d36ae1a5a6d256b6d1d8`
- **Signature:** ad-hoc on both bundles, and `codesign --verify --deep --strict` passes. **Not notarized.**
- **No stale executable:**
  - the script deletes `build/dist/work` and compiles both architectures from source;
  - the helper contains `kern.bootsessionuuid` and the deferral reason, and the viewer contains "Changes can't be tracked right now" and "Folders that kept changing";
  - the stale 1.0.0 helper (`d927658e…`) contains neither marker;
  - the bundled self-test run from the image reports 231 tests, matching this tree.
- **Install and update code is included:** the helper is the installer. It contains `install`, `uninstall`, the install-transaction journal and `inventory-work … --budget`, and it is at `Contents/Helpers/MacBook Storage Monitor.app`, where Settings looks for it.
- **Unchanged:** the old `Storage-Monitor-1.0.0.dmg` is left in place, still stale, and must not be used.

## 5. Installation test: MacBook Air M2, 8 GB (do not start without authorization)

This supersedes §8 of `STORAGE-MONITOR-INSTALL-READINESS.md`.

Paths on the Air:

- data directory: `DATA="$HOME/Library/Application Support/MacBook Storage Monitor"`
- helper executable: `SM="$HOME/Applications/MacBook Storage Monitor.app/Contents/MacOS/StorageMonitor"`

All database checks run on an APFS clone: `cp -c "$DATA/history.sqlite3" /tmp/sm-check.sqlite3`, then `sqlite3 /tmp/sm-check.sqlite3 "…"`.

**Preconditions**
- macOS 14 or later on the M2 Air, a dedicated standard test account, and at least 20 GB free.
- No prior Storage Monitor: `ls ~/Library/LaunchAgents | grep storage-monitor` and `ls "$DATA"` both empty.
- Chrome installed (for the deferred-folder check). The lid can be closed overnight.
- Written authorization for this test.

1. **Transfer and check the image.**
   - Copy the DMG by USB disk or `scp`, not a browser download or AirDrop.
   - `shasum -a 256 Storage-Monitor-1.0.1.dmg` must equal `43e5ac511ae3ef472ee349b608094e7ca3b868cb4dbe2db18c3e269e649ccdee`.
   - `xattr -l Storage-Monitor-1.0.1.dmg` must show no `com.apple.quarantine`; otherwise see PACKAGING.md → Gatekeeper.
2. **Record a baseline:**
   - `df -h /System/Volumes/Data`
   - `sysctl vm.swapusage`
   - `memory_pressure | tail -1`
   - `sysctl kern.bootsessionuuid`
   - `date -u`
3. **Install the app.**
   - Open the DMG, drag **Storage Monitor** to Applications, eject, and open it. If macOS says it cannot verify the app (ad-hoc build), approve it once in System Settings → Privacy & Security → Open Anyway.
   - Disk Inventory must say "Background indexing has not been installed", and `ls ~/Library/LaunchAgents | grep storage-monitor` must still be empty. No background work may start before consent.
4. **First-launch consent and activation.**
   - Open Settings → Background Monitoring → **Enable Background Monitoring…**. The alert must list the three tasks, including "Disk inventory indexing at low priority…". Confirm.
   - Settings then shows "Background monitoring is on".
   - `ls ~/Library/LaunchAgents | grep storage-monitor` lists exactly `local.macbook.storage-monitor.plist`, `local.macbook.storage-monitor.baseline.plist` and `local.macbook.storage-monitor.inventory.plist`.
   - `launchctl print gui/$(id -u)/local.macbook.storage-monitor.inventory | grep -A8 arguments` shows `inventory-work --budget 1200 --data-dir …`.
5. **Initial inventory**, without Full Disk Access. Every 30 minutes, record:
   - `tail -3 "$DATA/monitor.log"`
   - `ps -o pid,rss,%cpu,etime -p $(pgrep -f inventory-work)`
   - `memory_pressure | tail -1`
   - `sysctl vm.swapusage`

   Expect:
   - the first-pass panel (condition A);
   - runs of 1,200 s or less with a 60 s gap, each logging `inventory {…}`;
   - worker RSS under 100 MB.

   It is complete when `"$SM" inventory-status` shows `"initialCompletion":"complete"`. Record the elapsed time and the final `inventory {…}` line.
6. **LaunchAgent behavior in steady state** (after step 5).
   - Between the :00 and :30 wakes, `pgrep -f inventory-work` prints nothing.
   - Each wake logs one `inventory events {"outcome":"applied",…}` and one `inventory {…}` of 120 s or less.
   - `launchctl print gui/$(id -u)/local.macbook.storage-monitor.inventory | grep -E "runs|last exit"` shows the run count rising and `last exit code = 0`.
   - Check a second, overlapping start: run `launchctl kickstart gui/$(id -u)/local.macbook.storage-monitor.inventory` while the worker is running. `pgrep -f inventory-work | wc -l` must stay at 1.
7. **Sleep and wake.**
   - Note the time and `sysctl kern.bootsessionuuid`, then close the lid for at least 8 h.
   - After waking, the boot session must be unchanged, and the first new `inventory events` line must be `"outcome":"applied"`, **not** `gap`.
   - `SELECT COUNT(*) FROM inventory_reconcile` must be 0 on a clone.
   - Spot-check two folders changed before sleeping with `du -sk`, against the viewer.
8. **Deferred-directory status.**
   - With Chrome open and browsing, wait for the next wake. `"$SM" inventory-status` shows `"deferredDirectories":1`.
   - Disk Inventory reads "Up to date except 1 folder that keeps changing". **Show folder** lists `…/Google/Chrome/Default/Cache/Cache_Data` with a "Previously …" size, and **Show** navigates there.
   - No first-pass panel appears.
   - Quit Chrome. After the next wake the status reads "Inventory is up to date" (or "Showing available measurements" without Full Disk Access) and `"deferredDirectories":0`.
9. **Reboot recovery.**
   - Restart. Within the next half hour the log shows `applied` and the cursor's `boot_session` changes: `SELECT boot_session FROM inventory_event_cursor`.
   - Optional: shut down for more than 6 h. Expect one `gap`, the viewer showing "Rechecking after missed file events", and the recheck draining to B or C. Record its duration and CPU.
10. **Upgrade and recovery.**
    - Record `SELECT COUNT(*) FROM readings` and `SELECT COUNT(*) FROM inventory_nodes` on a clone.
    - Build a 1.0.2 (build 3) DMG, which needs separate approval, and install it over the app. Settings shows that the installed monitor differs → **Update Background Monitor…**.
    - After the update:
      - counts are equal or higher;
      - no `gap` caused by the update;
      - at most one `history.pre-update-*.sqlite3`;
      - `install-transaction/` is absent.
    - The interrupted-update rollback is verified in isolation (`STORAGE-MONITOR-INSTALL-READINESS.md` §5). Do not kill a real update on the test Mac unless that is separately authorized.
11. **Uninstall.**
    - Settings → **Disable…**. Afterwards:
      - `ls ~/Library/LaunchAgents | grep storage-monitor` is empty;
      - `launchctl print gui/$(id -u)/local.macbook.storage-monitor.inventory` fails;
      - `pgrep -f StorageMonitor` prints nothing after 2 minutes;
      - `$DATA/history.sqlite3` still exists with the same row counts.
    - Then follow PACKAGING.md → Uninstalling, deleting data only when the test is finished.

**Stop the test immediately** (Settings → Disable…, then collect `monitor.log`) if any of these happens:

- a `gap` after a sleep with no reboot;
- the worker relaunching every 60 s without the `inventory {…}` counters advancing;
- more than one `inventory-work` process;
- worker RSS over 200 MB, memory pressure "critical", or swap growth over 2 GB attributable to the worker;
- any decrease in history row counts across an upgrade;
- any background task present before consent;
- any Storage Monitor process after Disable.

## 6. Remaining risks

1. **FSEvents retention is not documented.** The awake-time rule rests on measured retention, more than 7 days here, and on the same awake-activity bound as before. Step 7 verifies it on the Air.
2. **A shutdown longer than 6 h** still causes one full reconciliation. That is safe but costly on 8 GB; it is measured in step 9.
3. **Persistent worker failure** retries every 60 s and appears only in `monitor.log`, not in the viewer.
4. **Not notarized and ad-hoc signed.** A quarantined helper may be refused by Gatekeeper with no prompt when launchd starts it. This is detected and reported but **NOT VERIFIED**.
5. **Not exercised on real hardware:** real launchd registration, real sleep and wake, a real reboot, and the native viewer's new popover and wording. All are **NOT VERIFIED** until this test.
6. **The source is uncommitted.** The DMG corresponds to fingerprint `ab5c5e85…850d`, not to any commit. Committing is a separate decision.
7. **QA still runs candidate 3** (`e8e56008…`), without this pass's changes.

No production LaunchAgent, database or app was modified: hashes still match `production-hashes-before.txt`. QA was not interrupted (idle, `runs = 4`, last exit 0). Nothing was installed, committed or pushed.
