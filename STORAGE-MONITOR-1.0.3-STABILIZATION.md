# Storage Monitor 1.0.3 stabilization (pass 1)

2026-10-24, Mac mini. Source changes only: no DMG was built, nothing was committed, and the MacBook Air was not touched. This pass responds to `~/Downloads/STORAGE-MONITOR-1.0.2-AIR-UPGRADE-TEST.md`.

**Nothing here is validated on the MacBook Air.**

Evidence is in `build/release-1.0.3/` (test logs, D6 renders, ETA observations, migration check).

## Root causes and fixes

| ID | Root cause (confirmed) | Fix | Regression coverage |
|---|---|---|---|
| **D10**: exit 1 after the update, nothing in the log | **Reproduced** with the 1.0.2 helper on an isolated fixture. Right after an in-place update, launchd starts every agent at once. The worker opens the history database first, and its schema statements need the write lock while the check holds it. The worker waited only 3 s (history connection) or 100 ms (inventory connection), then threw "SQLite: database is locked" and exited 1. The message went only to stderr, which the LaunchAgent sends to `/dev/null`. | The worker waits up to 30 s for a lock, in its history connection, inventory connection and pre-migration probe. Any failed background command (`inventory-*`, `initialize-baseline`) now writes `ERROR <command> failed: …` to `monitor.log`, with the home folder shown as `~`. It still exits non-zero, so launchd retries after 60 s. After the fix, the same reproduction exits 0 after waiting 5 s. | **Self-test:** the helper relaunches itself as `inventory-work` while another connection holds the write lock (exit 0). A failing launch writes a redacted `ERROR` line. **Inventory tests:** startup waits for a writer. |
| **D9**: "database is locked" after 600 s at the :00 check | The worker's inventory connection used a 100 ms busy timeout. Any write by the scheduled check (its reading, then coverage saves in 1,000-row transactions), or a read while the worker committed, that lasted more than 100 ms made a statement fail. The whole slice then ended `busy`. **Holder:** the check process; nothing else writes this database. **Progress lost:** only the uncommitted transaction and the buffered listings (at most 32); committed work is durable. | Same change: the worker waits up to 30 s. The monitor's own connections (check, status) wait up to 10 s instead of 3 s, so the check isn't starved by the worker's once-per-second fairness yield. The journal mode (rollback, `synchronous=FULL`) and transaction scope are unchanged; every write still uses `BEGIN IMMEDIATE`, so there is no upgrade deadlock. | **Inventory tests:** a full worker run meeting a 2.5 s foreign write lock completes (it had ended `busy`). The existing cleanup-authority test now accepts waiting: the peer completes after the lock and deletes nothing (20/20 retained). |
| **D6**: monitoring header labels clipped | **Rendered offscreen and reproduced.** A harness drew the real `MonitorRootView` in a window that was never ordered on screen, from a process that cannot take focus. The Monitoring layout needs about 720 pt, but the window allowed about 568–652 pt below the toolbar. The outer `.frame(minHeight:)` sized to the content, and the hosting view **centred** the overflow, so the top rows slid under the title bar and toolbar. That is exactly "Available now", used, total and "Recorded 1-hour change" under a blurred bar. | The window content is top-aligned and bounded (`maxHeight: .infinity, alignment: .top`) at both the scene and the root view, so overflow can never go under the toolbar. The event table (minimum 72 pt) and the capacity chart (72–118 pt) now give way. The window's minimum is raised from 620 to 700 pt: `NSWindow.minSize` is the frame size, so 620 left 568 pt of content. | Offscreen renders at 1240×820, 1000×700, 780×648 and a forced 780×560: every label is visible below the toolbar (`evidence/d6-before-narrow.png`, `after-*.png`). Native appearance on the Air is **not verified**. |
| **D7**: notifications delivered on an upgraded install | macOS permission belongs to the helper's bundle and carries over between versions. The 1.0.2 consent text said notifications "stay off until" allowed, which is false for upgrades. Settings couldn't show the real state, because only the helper can read it. | Each production check, the installed helper records what macOS reports for its own notifications (`state.notification_authorization`). Settings reads it read-only and says: allowed (including permission carried over from an earlier version), turned off, not yet allowed, or not yet recorded. "Allow Low-Space Notifications…" appears only while macOS can still prompt; otherwise **Notification Settings…** opens System Settings. The consent and install text are corrected. Nothing resets or changes permission. | Viewer tests for the state parsing, the prompt eligibility and the consent wording. |
| **D11**: the `Users` row reads "Previously 98.54 GB" | A folder is `stale` if any child is stale, so one deferred cache made every ancestor show its total as wholly previous. | The engine now records why: a folder whose own listing is current but that includes stale descendants gets the reason `inventoryDescendantStaleReason`. The viewer shows it as "≈ 98.54 GB · Includes earlier sizes". A folder that is itself stale or deferred still reads "Previously … · Previously measured", and current folders read "Complete". The status stays `stale`, so nothing is presented as fully current. | Viewer test with all three cases. |
| **D12**: normal runs logged as `interrupted` | `outcome` came from the zero-budget closing pass, which reports queued event work as interrupted. | Each `inventory {…}` log line keeps `outcome` (compatibility) and adds `"status"`: `completed`, `deferred`, `continuing`, `paused` (user or low space), `skipped` (another worker active) or `failed`. | Inventory test of every mapping. In the real run below, slices logged `continuing` four times, then `completed`. |
| **ETA**: never shown during a real pass | **Found by real observation (below).** The estimator fitted the whole 10-minute window, including the discovery phase in which the queue grows (0 → 38,715). The fit and the "queue shrank" check failed throughout a 9.5-minute pass. | Fit only the draining stretch after the queue's latest peak, with the same confidence rules: at least 6 samples, at least 2 minutes, recent data, a falling slope, R² ≥ 0.7. | Viewer test: a growth-then-drain series has no estimate during growth or in the first 2 minutes of draining, then the correct one (342 s). |

## Progress and ETA on a real tree

**Setup:** `~/.cache` (905,146 entries), isolated database, release CLI under background policy (`taskpolicy -b`), in 120 s slices with 15 s gaps to exercise restarts. An observer recorded what the first-pass panel would show every 10 s.

- **Worked, across all 5 worker restarts:**
  - items indexed, examined bytes, folders completed and queued;
  - items per second: about 3,100/s early, about 1,100/s late at background priority;
  - elapsed time.
- **Slices:** exit 75 with `continuing` ×4, then exit 0 with `completed` after 567 s. Peak RSS 24.8–27.8 MB.
- **Completion:** the panel switched off when the first pass was recorded complete.
- **Estimate before the fix:** "Estimating time remaining…" for the entire run.
- **Estimate after the fix**, replaying the *real* recorded samples (`evidence/eta-replay-after-fix.txt`):

  | Elapsed | Shown | Actually remaining |
  |---|---|---|
  | 0–216 s | Estimating time remaining… | 566–350 s |
  | 246 s | about 10 minutes (436 s) | 320 s |
  | 408 s | about 10 minutes (536 s) | 159 s |
  | 468 s | about 5 minutes | 99 s |
  | 528 s | about 3 minutes | 39 s |
  | 564 s | less than a minute | 3 s |

  - The estimate **never under-estimated**: it appears once the drain is established and errs long by up to about 3×, because the last, leaf-heavy folders drain fastest.
  - It is conservative by design and never a countdown or a percentage.
  - It has not been observed on a full-volume pass; the Air's pass (about 35 minutes) would show it for most of its length.

## Verification

| Suite | Result |
|---|---|
| `scripts/test-inventory.sh` | **265 / 265** |
| `StorageMonitor self-test` (built app) | **233 / 233** |
| `scripts/test-gui.sh` | **352 / 352** |
| `build.sh` and `build-gui.sh` (26.5 SDK) | OK, 0 warnings |
| Migration on a read-only backup of this Mac's history | 154 readings, 48 alerts, 8 diagnostics, 154 evidence and 10 state rows preserved; `quick_check` ok |

Production databases and LaunchAgents on this Mac were not modified, and QA was not touched.

## Remaining risks

1. **Unverified on the Air:**
   - D9 and D10 are fixed by reasoning plus reproduction here. The Air's exact lock holder at 07:00 was not captured, but the check is the only other writer.
   - The D6 fix is verified by offscreen rendering, not on the Air's display.
2. **A 30 s lock wait** means a stuck foreign lock (for example a backup holding a read lock) delays the worker by up to 30 s per statement before it reports busy. It no longer discards the slice on short contention.
3. **D3, upgrade disk cost:** the pre-update snapshot is a full copy, about 1 GB on the Air. Not addressed in this pass.
4. **The ETA errs long.** It was validated on one real 9.5-minute tree and on synthetic series.
5. **Not yet run on the Air:** the remaining lifecycle steps (sleep of 8 h or more, reboot, Disable/uninstall).

## Recommended next steps

1. **Second stabilization pass:**
   - an independent review of this pass's diff;
   - repeated suite runs for timing-sensitive tests;
   - D3: make the pre-update snapshot an APFS clone where possible, or skip it when only additive tables change.
2. **Build 1.0.3 (4)** and verify it as 1.0.2 was.
3. **Fresh first-pass test on this Mac mini**, which has never indexed in production. Install 1.0.3, choose **Repair** (this Mac has the 1.0.0 helper with two agents), then observe, without touching the screen:
   - throughput, ETA and resources;
   - the accounting summary against macOS;
   - idle behavior.
4. **Air validation:** upgrade 1.0.2 → 1.0.3, then the lifecycle steps.

## Recommended first native file explorer (smallest practical version)

The Disk Inventory screen already has a breadcrumb trail, a paged `Table` of one folder's children with size, coverage and sort, and "Open folder / Show enclosing folder" actions. The smallest real explorer builds on that instead of adding a new view.

1. **One folder view with disclosure.** Replace the flat page with a SwiftUI `Table` using `OutlineGroup` / `children:` rows. Each folder row expands lazily, one `InventoryReader.children` page of up to 256 items sorted by allocated size. There is no new query, index or worker change: `inventory_nodes_children_allocated` already serves it.
2. **Keyboard and native behaviour.**
   - Arrow keys expand and collapse.
   - Return opens the folder in the breadcrumb.
   - ⌘↑ goes to the enclosing folder.
   - The context menu offers Reveal in Finder, Copy Path, and Prioritize this folder (existing).
3. **Honest sizes in place.** Reuse `InventoryNodePresentation` for "≈ / Previously / Partial / Access restricted", plus a thin size bar relative to the parent. No new numbers.
4. **Out of scope for the first version:**
   - deletion or moving files, which would be destructive and need their own consent design;
   - treemaps;
   - multi-selection totals;
   - search inside the outline. The existing search mode stays.

**Estimated size:** one view file, about 200–300 lines, plus model tests for lazy expansion and paging. The engine and schema are unchanged.

## Pass 2 and the 1.0.3 (4) build

- **Repeat runs:** the inventory suite passed 265/265 in three consecutive runs and the self-test 233/233 in three runs.
- **Diff review:** no defects found.
  - **Lock waits:** the worker's 30 s lock wait does not affect the viewer's read connections, which keep 100 ms and a 0.25 s query deadline.
  - **Watchdog:** its replay query can wait at most 30 s, below its 60 s limit.
  - **Notification state:** it is read after the check's reading is committed.
  - **Failure logs:** they redact the home folder.
- **D3:** the pre-update snapshot **is** an APFS clone, so it costs nothing at creation. It diverges as SQLite rewrites pages in place, and a large reconciliation right after an update (as on the Air) makes most of it unique.
  - 1.0.3 adds no schema change, so updating to it creates no new snapshot and the existing one is kept.
  - Options for a future release, needing a retention decision:
    - delete the kept snapshot after a fixed number of successful checks;
    - skip it when a migration only adds tables.
- **DMG:**
  - Path: `build/dist/Storage-Monitor-1.0.3.dmg`, 10,788,024 bytes.
  - SHA-256 `4baeb48d0e851dacd2580e66f9db2e354358fe2afcdf030c346db707583a87d9`.
  - `hdiutil verify` VALID. App and helper are 1.0.3 (4), universal, ad-hoc signed (not notarized).
  - The bundled self-test passes from the image (233).
  - Helper `4026d18e…acfe7`, viewer `d58b754b…5d65`.
  - Source fingerprint `275675464d2c…127f` (uncommitted tree on `46cd268`).
  - Built locally, so no quarantine attribute.
