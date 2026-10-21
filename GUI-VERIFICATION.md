# Native viewer verification

The desktop viewer is a separate SwiftUI/Charts/AppKit application, bundle ID `local.macbook.storage-monitor.viewer`. It opens the existing `~/Library/Application Support/MacBook Storage Monitor/history.sqlite3` with read-only SQLite access. The background `MacBook Storage Monitor.app` and its LaunchAgent retain their original identity, schedule, configuration, and database schema. No monitor code or production data was changed for the viewer.

The built, ad-hoc-signed application is `build/Storage Monitor.app`; the installed application is `/Applications/Storage Monitor.app`. Launch it from Finder or Spotlight, or `open '/Applications/Storage Monitor.app'`. No Terminal, administrator privileges, or open GUI is needed for monitoring. The build explicitly targets Apple Silicon macOS 14.0 and uses only system frameworks. This host runs macOS 27; older supported macOS releases were not available for runtime testing.

## Automated data verification

`scripts/test-gui.sh`: **61 model/read-only tests passed** on 2026-10-21. They cover every event-type, preset-time, preset-size, and severity filter; combined type/time/size/severity/search; custom sizes and inclusive local-date endpoints; all five exact sort orders; filter persistence; missing/empty/corrupt databases; subsecond SQLite timestamps; strict decimal size boundaries; binary swap conversion; comparable diagnostic metrics; unknown/partial evidence; APFS predecessor matching; and sufficiently recent hour/day baselines. Isolated fixture databases are clearly labelled QA and never inserted into production history. Tests confirm byte-identical source SQLite contents and no GUI-created journal/WAL.

`scripts/build-gui.sh` succeeds; installation verifies the bundle signature with `codesign --verify --strict`. The exact same original `AppIcon.icns` is copied into the viewer; no artwork was redesigned. SHA-256 for both viewer and background icon is `0ee0a5d7cc3fa0cc88f4ede9764cecf94ed8bfc39c812b350eeee638b2a67a64`. The earlier task-created GUI in `~/Applications/Storage Monitor.app` was moved to `build/previous-viewer.bundle` and unregistered so the final app entry resolves to `/Applications`. The separate `~/Applications/MacBook Storage Monitor.app` background worker was untouched.

`bin/storage-monitor self-test`: **37 original monitor tests passed**, including alert lifecycle, SQLite reopen, retention, locking, calendar schedule, and diagnostic deadlines.

## Native interaction and visual evidence

**49 native control assertions passed**: 43 in `build/gui-verification/native-controls.log`, two focused custom-date assertions in `native-dates.log`, and four chart-range assertions in `native-chart.log`. These exercise all eight event types; all preset history time and size ranges; real typed custom sizes and invalid values; every severity; diagnostic search; combined type/time/size/severity/search; all five actual table row orders; row selection and evidence certainty labels; valid and reversed custom-date edits; and chart range point counts. Exact byte thresholds and inclusive date boundaries are checked by the model suite. The harness uses Accessibility actions on an explicitly QA-labelled window and sends text key events only to that QA process. Direct AXValue edits do not reliably commit SwiftUI text bindings on this SDK, so they are not used as evidence of typing behavior.

WindowServer captures from the current host sometimes return a small perspective/minimization animation instead of the window. Those thumbnails are not accepted as layout evidence. The QA-only `--capture-window-path /absolute/path.png` option captures the actual running NSWindow content using AppKit's `cacheDisplay`; this is an actual native view render, not a WindowServer screenshot, and excludes native title-bar chrome. Earlier full production-window screenshots are also retained under `build/gui-verification`.

Reviewed actual native view renders: `qa-light-render.png`, `qa-dark-render.png` (standard); `qa-narrow-light-render.png`, `qa-narrow-dark-render.png` (780-point width); `qa-empty-light-render.png`, `qa-empty-dark-render.png`; and `qa-error-render.png`. There are no fabricated production rows. Narrow views use a compact filter popover, and overview capacity reflows when the inspector reduces available space. Native table columns can scroll horizontally when the inspector is open at narrow widths. Detail views were additionally inspected in `qa-inspector-render.png` (dark) and `qa-inspector-light-render.png`; a native inspector text-color inheritance issue on this SDK was fixed with an explicit appearance-aware foreground.

## Background independence and refresh

An independent QA-only SQLite writer added one reading while the GUI stayed open and active. Without a refresh click, restart, or second activation, the visible count changed from 10 of 16 to 11 of 17 within 36 seconds (`native-refresh.log`). Runtime evidence confirms a 30-second tick with an active, visible native window (`qa-refresh-runtime.log`). Earlier attempts with an inactive LaunchServices-launched window correctly did not refresh under the active-window policy. No production reading was inserted or edited for this test.

With the desktop viewer quit, `launchctl print gui/501/local.macbook.storage-monitor` still showed the separate worker executable, calendar minutes 0 and 30, five completed runs, and last exit code 0. Evidence is in `background-after-gui-quit.log`. The LaunchAgent plist SHA-256 remained `822d3ae85703c9d490cd1788473178d368f3d67c7b61275a27f93ac2e2181647`; its executable remains `~/Applications/MacBook Storage Monitor.app/Contents/MacOS/StorageMonitor`.

Normal LaunchServices launch using `open -b local.macbook.storage-monitor.viewer` resolved to `/Applications/Storage Monitor.app/Contents/MacOS/StorageMonitorViewer` without database or appearance overrides. The real window had no QA label and read 12 actual events, with 17.00 GB available at the 04:00:10 local scan (`production-final-ax.log`). Production filter preferences stayed separate from QA preferences.

## Evidence actually supported

- Physical APFS container free/used/total capacity and changes between adjacent same-container readings.
- Stored alert reasons, severity, notification status, and orphan alert records.
- Per-reading APFS allocation objects, with changes matched by volume UUID.
- Stored diagnostic commands and their complete/partial/denied/timed-out status.
- Comparable complete swap, temporary-directory, Application Support, Chrome signing-clone, and recorded APFS diagnostic measurements when the corresponding snapshot data exists.

Snapshot comparisons show their own timestamps. Directory apparent/block sizes, allocated swap, volume allocations, and physical APFS capacity are separate measurements; they are not added together and are not proof that an application caused storage loss. Partial/unmatched metrics remain unknown. Scheduled versus manual scan origin was not recorded, so the UI uses “Recorded Scans.” The viewer does not invent snapshots or scan the disk.

## Limitations

The independent Claude review was attempted but returned no review because that account's usage limit was reached. Direct source review, build/tests, real app interaction, and native visual inspection are the verification basis. Ad-hoc signing is suitable for this local installation; distributing to other Macs would require a Developer ID/notarization workflow. Full VoiceOver traversal and older-macOS runtime testing were not performed. Chart range changes and actual point counts were exercised; the native hover tooltip interaction was not independently confirmed on this host.

## Diagnostic inspector redesign — 2026-10-21

Verified in the native app (QA windows on copies of production history; the production database and the running viewer were not touched):

- **Real 4:00 AM event** (`production-copy.sqlite3`, reading #12): Likely Causes is first and ranked Data volume growth +1.10 GB, Virtual memory growth +1.07 GB, Other system allocation +1.05 MB. All are marked Confirmed contributor · measured APFS allocation increase, with Responsible application: Unknown. The breakdown shows 19.18 → 17.00 GB, −2.18 GB, 3:30 → 4:00 AM, and "Measured volume changes account for the recorded loss exactly." The 2:21 → 4:00 AM swap change is shown with its own interval and labelled a different interval from this event. The collection summary reports 78 protected locations, 3 timeouts, and the truncated APFS output that was not used.
- **Schema-2 snapshots from two real collections** (`schema2-real.sqlite3`): a +3.99 GB recovery ranks Virtual memory reduction −3.22 GB and Data volume reduction −0.76 GB. Same-interval swap allocation −3.22 GB appears as the likely mechanism. All 9 measurements are complete with 0 permission refusals; each collection took about 4.5 s with no `du`/`find` processes.
- **Disclosures**: all technical sections start collapsed, expand and collapse through native AX press, and reset when another event is selected. `GUIAXTests --inspector-only`: 55 / 53 / 19 checks passed on the three databases.
- **Light, dark, narrow (780 pt)**: captured in `build/gui-verification/diagnostic-inspector-*.png`. Live dark mode was also checked on screen. The offscreen `--capture-window-path` render draws inspector text and symbol tints with the wrong appearance in dark mode. That is a capture artifact; the live window is correct.
- **Accessibility crash found and fixed**: reading the inspector through Accessibility after changing the selection caused a SwiftUI stack overflow. It came from whole-inspector `.textSelection(.enabled)` together with `.id(event.id)`. Text selection is now limited to technical-detail text, and disclosure state resets with `onChange`. A five-switch AX repro passes.
- **Not verified here**: the full popup-driven filter AX run (`GUIAXTests` without flags) was not re-run because it opens menus over the active desktop. Filter and sort code is unchanged, and all filter and sort model tests pass.

## Folder growth attribution — 2026-10-21

- **Monitor self-tests (82):** real files and real FSEvents history under `/private/tmp`, covering creation, growth, deletion, a move between folders, an APFS clone (flagged `cloned`), a sparse file (+500 MB logical, under 1 MB allocated), two simultaneous writers, a new folder, a permission-locked folder (not comparable), rejected nested and symlinked roots, a process holding a writable file in a grown folder (correlated), a folder with no open files (not correlated), a quiet interval (1 folder re-measured), an FSEvents database change (full rescan, still compared), a missed reading (nothing compared), the event cap, a database reopened between every collection, and retention.
- **Real folders, scratch database** (`attribution-probe`): first run is a full baseline of 348 subfolders in 7 roots, about 34 GB, in 14.2 s. One minute later: 26 file events, 6 subfolders re-measured, 342 carried forward, 0 changes, in 2.2 s.
- **Viewer (129 model tests):** folder evidence attaches only to the reading whose previous reading matches. The Data cause gains measured folder growth and process correlation; application stays "Unknown"; the unattributed remainder is explicit. Mismatched-interval and baseline-only evidence is never used. Old databases without the table load unchanged.
- **Native UI:** offscreen QA renders of `attribution-view.sqlite3`, the Accessibility tree of Supporting Evidence (folder growth, changed files, process correlation rows), and `GUIAXTests --inspector-only` (46 checks on that database; 55/53/19 on the others). The event-switch crash repro passes.
- **Not done:** the new monitor was not installed, so production history has no folder evidence yet and the live UI shows "Responsible folders: not recorded for this event" for existing events.

## Live capacity and appearance — 2026-10-21

- **Live reading.** `statfs` on `/System/Volumes/Data` matched `diskutil` `CapacityFree` to within about 100 KB of live drift, and total matched `CapacityCeiling` exactly. The live Data volume UUID matches the recorded container. Model tests cover in-memory storage, the 60 s cadence, staleness after 3 minutes, a failed refresh keeping the last good reading as stale, dropping overlapping refreshes, comparing only the same container, unchanged events and chart points after live refreshes, and identical monitor files (database, log, lock) after real probes. `test-gui.sh` also checks that the viewer binary does not link UserNotifications and that the live code launches no process and writes no SQL.
- **Appearance.** Defaults to System; the choice persists; unknown values fall back to System; the launch override is not persisted. Runtime switching through the real View → Appearance menu (Accessibility press, QA instance) was verified by sampled pixels of on-demand QA renders: Dark 40, Light 255, System 255 (macOS is light), Dark again 40, across overview, table, inspector and chart. It was also verified on screen for System and Dark.
- **Screenshots.** `build/gui-verification/live-{system,light,dark}-wide.png` and `live-{light,dark}-narrow.png`. The offscreen render still draws inspector text dimmer in dark mode than it appears on screen; this is the known capture artifact.
- **Native checks.** `GUIAXTests --inspector-only`: 55/53/46/55 on four databases. The event-switch repro passes.
- **Not run.** The popup-menu filter and chart-range AX suites, which open menus over the desktop. Filter code is unchanged, and the chart test's label expectation was updated to "N points".

## Viewer-only installation — 2026-10-21

- **Installed viewer:** `d86ee259…`. It rebuilds byte-identically from the source, matches the tested build exactly, and has a valid signature. The monitor binary (`14e49550…`) and the LaunchAgent plist were unchanged.
- **Found during post-install checks and fixed before the final install:**
  1. Selecting System after Dark left the window dark. SwiftUI's `preferredColorScheme` pinned the window appearance. The app appearance is now set directly and window-level appearance cleared, so windows inherit and System follows macOS. Verified for Dark→System→Light→Dark→System, offscreen and on screen.
  2. Every launch restored only the Settings window. Settings shown within 3 s of launch is now treated as restored: the history window opens and the restored Settings window closes. ⌘, still opens Settings normally.
  3. Accessibility exposed a stale live status, and the recorded line was announced as "Clock". Both now have explicit, current labels. New `GUIAXTests --overview-only` (3 checks) covers them.
- **Verified on the installed app:**
  - Available now matches `statfs`.
  - The recorded line is separate.
  - The chart's 3 points equal the database readings in the saved "Last Hour" range.
  - The inspector values match readings #18 and #19.
  - ⌘R advanced the live time on screen.
  - The stale state appeared after the app sat idle and cleared on Refresh.
  - Dark and System were confirmed on screen by pixels, and both persisted across restarts.
  - Production rows up to the pre-install reading are identical, and the attribution baseline was not reset.
- **Observed separately, not caused by this change:** one monitor check at 11:08 logged a diskutil timeout (likely a wake catch-up). It recorded no reading; it is the only error today.
