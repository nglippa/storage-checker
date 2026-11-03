# Navigation performance: measurements and root causes (2026-10-28)

## The 5–13 s figure was a measurement error

The figure came from the earlier native acceptance session. The click, a 5 s wait and a screenshot were sent in parallel. The "not switched yet" screenshot was taken about 3 s after the click was sent, and it still shows **Monitoring** selected in the section picker, so the click had not yet been processed. The only valid bound from that session is "switched within about 12 s". It is **not** evidence of a 5 s or longer delay. The earlier session also ran builds and test suites in the background for half of its duration.

The real delays were shorter than reported, but they were real. They are measured below, from inside the process.

## Method

**Data:** a fresh APFS clone of `build/inventory-fresh-20261023T031313Z/previous-catalog.sqlite3` for every run:

- 2,959,505 nodes
- 334 pending jobs
- reconciliation pending, so the viewer's 2 s indexing poll is active

**Instrumentation:** `SourcesGUI/PerformanceTrace.swift`.

- Signposts (Instruments → Points of Interest).
- With `--perf-log` (QA only), a line per mark: section, folder, selection and visualization changes; `inventory.load`, `history.load`, `explorer.children/span` and `livingTree.read/layout` durations.
- The first committed frame after each change.
- Every main run-loop pass longer than 50 ms.

**Driver:** `SourcesGUI/PerformanceScript.swift`, QA only, with `--perf-script`. It sets the same state the controls set; there is no pointer, keyboard or accessibility input.

- 5× Storage ↔ Monitoring
- 5× open the largest folder, then its parent
- 3× nested tile selection
- 4× folder selection with the Inspector open
- 3× Atlas ↔ Living Tree
- 3× Storage ↔ Monitoring with the Living Tree showing

**Headless harness:** `bench/` (`prepare.py`, `Bench.swift`, `analyze.py`). It hosts the real `MonitorRootView` in a never-shown window. With `--render`, the full hierarchy is drawn each frame.

**Native runs:** these were authorized. The dev viewer opened on display 3 and was quit with SIGTERM.

- `native-baseline-run1.log`: the profiler `sample` (1 ms) was attached from about t=12 s. That inflates later baseline stalls, so compare medians and pre-profiler steps.
- `native-after-run1.log`: no profiler; load average about 3.4.

Read the result tables as follows:

- **first frame:** from the change to the end of the main run-loop pass that commits it.
- **ready:** the model is idle with the folder and map loaded.
- **blocked:** main-thread passes over 50 ms within 1.5 s of the change.

## Root causes (measured)

1. **Redundant full catalog reloads on every return to Storage.**
   - Showing Storage again bumped the shared refresh tick while the view's own appear-time load was running. The reload gate then queued another load.
   - Result: 3 × `inventory.load` (median 282 ms each) per return, every time (`[3,3,3,3,3,3,3,3]`). Each load republished status and triggered explorer and tree refresh checks.
   - Fix: `ViewerStore.setInventoryVisible` no longer bumps the tick. The appear-time load is the refresh.
2. **The accounting query scanned the whole generation on every load.**
   - The profile (`native-baseline-run1-sections.sample.txt`) puts `InventoryReader.accounting()` at 1,264 of 1,382 samples in `loadPage`.
   - `status IN ('unknown','excluded')` could use only the `generation_id` prefix of `inventory_nodes_status(generation_id,kind,status)`. It walked about 3 M index entries: about 140 ms in the sqlite3 CLI and about 250 ms in the app, against a **0.25 s read deadline**. The call is `try?`, so a slower Mac could silently lose the storage accounting.
   - Fix: a loose index scan enumerates the kinds present, and each `(kind,status)` pair becomes an index seek. Identical rows, about 10 ms. No schema change.
3. **`launchctl` launched synchronously on the main thread on every store update.**
   - `AppearanceSettings` initialized `@State var monitoring = Self.monitoringState()`. SwiftUI evaluates a State initial-value expression on every init.
   - The app scene is rebuilt on every `ViewerStore` publish: the 2 s indexing tick, history refresh, live capacity and section switches. Each rebuild ran `launchctl list` plus `launchctl print-disabled`, plus plist and SQLite reads, on the main thread. That accounts for 502 main-thread samples.
   - Idle cost is about 8 ms per call. It is a cross-process wait that grows with system load, which fits the much slower first half of the earlier session, when builds were running.
   - Fix: the status is read off the main thread when Settings appears. Settings shows "Checking background monitoring…" with its actions disabled until the read completes.

## Checked and ruled out

- **Drawing in a hidden window:** `--render` adds 50–100 ms; it is not the cause.
- **The 2 s refresh loop running headlessly:** `--live-loop` makes no material difference.
- **Accessibility tree construction:** not testable headlessly, because a hidden window exposes only 1–2 elements. No longer needed to explain the measurements.
- **Disk I/O:** the catalog is warm in cache, and `pread` is under 1% of samples.
- **Memory:** headless RSS 71 → 107 MB over the run (after: same shape). Native RSS at the end: 204 MB before, 194 MB after.

## Results (`analyze.py`)

### Native, same script and dataset

The medians are the most comparable figures. The baseline's later steps include profiler overhead; its pre-profiler Monitoring → Storage first frames were 101–105 ms.

| Transition | Before: first frame med/max | Before: ready med/max | After: first frame med/max | After: ready med/max |
|---|---|---|---|---|
| Storage → Monitoring | 345 / 961 | 0 / 0 | 142 / 182 | 0 / 0 |
| Monitoring → Storage | 592 / 1048 | data already loaded; 3 reloads follow | 129 / 131 | 1 reload, plus the indexing poll |
| Open largest folder | 33 / 226 | 328 / 1048 (cold) | 46 / 55 | **113 / 146** |
| Parent folder | 42 / 308 | 332 / 1101 (cold) | 46 / 53 | **106 / 124** |
| Nested tile selection | 54 / 85 | 0 | 29 / 62 | 0 |
| Folder selection, Inspector open | 42 / 44 | 0 | 71 / 75 | 0 |
| Atlas → Living Tree | 54 / 54 | 398 (cold) | 62 / 89 | 406 (cold) |
| Living Tree → Atlas | 48 / 51 | 0 | 48 / 50 | 0 |
| Monitoring → Storage, tree showing | 223 / 254 | — | 163 / 173 | — |

Whole run:

| Measure | Before | After |
|---|---|---|
| `inventory.load` | median 220 ms, max 703 ms | median **67 ms**, max 257 ms |
| Main stalls over 50 ms | 78 (14.2 s total; profiler-inflated) | 60 (5.2 s total), longest **182 ms** |

### Headless, `--render`, warm medians, same harness

| Transition | Before (ms) | After (ms) |
|---|---|---|
| Monitoring → Storage | 445 | 207 |
| Open folder | 406 | 160 |
| Parent folder | 400 | 161 |
| Monitoring → Storage, tree showing | 537 | 319 |
| Cold startup | 437 | 372 |

### Cold and warm

The first open of a folder is the cold case: 1,048 ms before, 146 ms after, natively. Warm navigation is everything after it.

## Remaining limits

- The first frame of a section switch is still 110–180 ms natively. SwiftUI rebuilds the whole section because `MonitorRootView` swaps two view trees. Atlas painting and the event table account for most of it. That is below the 500 ms target, so no structural change was made.
- First Living Tree build: about 400 ms off the main thread (read plus layout), with the previous view kept on screen.
- The headless and native after-runs were made on a moderately loaded Mac (load average about 3–4). The numbers are conservative.

## Final build, native (`native-final-run.log`, no profiler, load average about 2)

| Transition | First frame median/max (ms) | Ready median/max (ms) | Longest stall (ms) |
|---|---|---|---|
| Storage → Monitoring | 141 / 193 | — | 193 |
| Monitoring → Storage | 109 / 128 | — | 128 |
| Open folder | 35 / 99 | 106 / 119 | 99 |
| Parent folder | 37 / 91 | 107 / 142 | 91 |
| Nested tile selection | 56 / 61 | — | 103 |
| Folder selection, Inspector open | 70 / 120 | — | 120 |
| Atlas → Living Tree | 41 / 45 | 380 (cold, first build) | 72 |
| Living Tree → Atlas | 31 / 35 | — | 97 |
| Monitoring → Storage, tree showing | 157 / 160 | — | 160 |

RSS at the end: 203 MB (204 MB before the changes).

## Interaction repairs (phase 3)

### A. Event-list keyboard focus

**Root cause, found natively:** a mouse click on a SwiftUI `Table` row leaves the **window** as first responder. The table never takes focus, so there was nothing for the old 0.5 s timer to restore.

**Fix:** `EventTableBridge` in `HistoryView.swift`. It does not depend on `@FocusState`, which does not report a click-focused table.

- It observes `window.firstResponder` with KVO.
- A click inside the table gives the table first responder.
- Ownership is kept with `EventListFocusOwnership` (`Models.swift`) until a deliberate move: a click outside the table, Tab or Shift-Tab, or ⌘F.
- Focus is handed back after any rebuild, whenever a table is in the window again. There is no time window.

**Native result: VERIFIED.**

- Click 00:10, then ↓ → 00:05: the row has the focused accent highlight, and the panel and chart marker follow.
- Tab moves to Search, and ↑ then leaves the list alone.
- Esc closes the panel, and the list keeps focus.
- ↑ reopens the panel on the previous event.

### B. Chart → event

The chart's exact-identity matching is unchanged (`StorageChartSelection`). The selected row is scrolled into view with `scrollRowToVisible`, and the list takes focus, so the row shows the focused highlight.

**Native result: VERIFIED.** Clicking the Oct 21 22:00 point selected that event, scrolled its row into view, highlighted it and updated the panel.

A point with no event is still model-tested only: it selects nothing and shows a message.

### C. Living Tree labels

`LivingTreeLabel.hit` checks the drawn label rectangles first, using the tips the label canvas draws at, then the branch hit index. Drag, orbit and pan logic is unchanged, because the target is used only for clicks.

**Native result: VERIFIED in 2D (light).**

- Clicking the "var" label selected var, and the Inspector and Navigator followed.
- A drag starting on a label panned without changing the selection.
- 3D label clicks: NOT TESTED natively. The same code path is used.

### D. Minimum-window chart

- Compact chart 108 → 96 pt, compact vertical padding −2 to −4 pt, and the event-list reserve 270 → 254 pt.
- Probe: at 1000×640 the summary needs 379 pt and gets 379 pt, so 0 pt is clipped. Before the change it needed 387 pt and got 370 pt.
- At 1240×760 and 1440×840 the summary and table are unchanged.

**Native result: VERIFIED** at 1000×648 content (QA banner on). The whole chart, including the 0 GB line and the date axis, is visible with no scrolling, with 5 rows below it.

### E. Filters and empty state

`EventListEmptyState` (`Models.swift`) handles three cases:

- If there are no events in the range, it names the range and the latest event date, and offers the narrowest preset range that holds it (or a range from the first event).
- It offers Clear Filters only when non-time filters are set.
- The toolbar Clear Filters stays disabled at the defaults, which is consistent with the empty state.

**Native result: VERIFIED.**

- Clear Filters gives the default 24 h range, and the empty state says "No events in this time range … most recent change was Oct 22" with **Show Last 7 Days**.
- That button reveals 21 of 29 events and enables Clear Filters.
- At minimum height the message was truncated. Fixed afterwards: the icon gives way and the text wraps. That fix is verified **headlessly only** (`after-screens/m-empty-state-minimum-light.png`).

### F. Cosmetic defects

- **Disclosure overlap:** the content now appears at once and only the chevron animates, so the overlap cannot occur. Native expansion shows no overlap; a mid-animation frame cannot be captured.
- **Atlas lens:** cleared by a container-level hover end, by the window resigning key, and by a click. **Native result: VERIFIED.** An instant pointer jump off the window cleared the lens.

## Living Tree size (phase 4)

- The trunk width in the fixed layout space is 18 → 26, shared by 2D and 3D (`LivingTreeGeometer.maximumTrunkWidth`). Widths stay proportional to √share, so the encoding implies no extra precision.
- Labels add the share of the shown folder, rounded to a whole percent ("323.88 GB · 70%", "<1%").
- Headless render: `after-screens/i04-living-tree-overview-dark.png` against `../visual-review/source-screenshots/i04-…`. Native light view seen during the session.
- Small branches keep `minimumWidth`.

## Regression results (`../verification/perf-*.log`)

| Suite | Result |
|---|---|
| Viewer model | 871 passed: 852 existing, 18 new (6 focus ownership, 7 empty state, 4 label hits and share, plus the `/private/tmp` alias test that only runs with `/private/tmp` fixtures) |
| Inventory browser model | 67 passed |
| Inventory integration | 349 passed |
| Monitor self-test | 235 passed |

Cleanup authority, evidence, Trash safety, diagnostics and the cleanup tests are byte-identical to `../baseline/source`. The only shared-code change is the accounting query, which returns identical rows on the QA catalog.

## Not verified natively

- Settings: the "Checking…" then status read. A click to raise the Settings window was denied as outside the main window.
- Living Tree label click in 3D.
- Dark appearance after these changes. Dark was verified in the previous session; this session ran in light.
- The empty-state wrap fix at minimum height (headless only).
- VoiceOver.

## QA-only additions

`PerformanceTrace` signposts are always on and cost nothing when unrecorded. The file log and `PerformanceScript` run only with a QA database plus `--perf-log` and `--perf-script`.

## Stabilization pass (2026-10-28, V2 frozen)

- Accounting query equivalence: 6,000 randomized in-memory catalogs (SQLite 3.54.1; kinds incl. case variants, empty and numeric strings; statuses incl. near-misses; NULL/'' reasons; 1-3 generations; queried generations 0..n+1; with and without ANALYZE) gave identical rows and identical app tallies. The QA catalog copy (3.5 M nodes, system sqlite3 3.54.0, read-only immutable) gives byte-identical sorted output. `kind` is `TEXT NOT NULL`, so `kind IN (distinct kinds of the generation)` is always true for the generation's rows, and both WHERE clauses select the same rows. The index `inventory_nodes_status` has existed since the inventory was first committed (e3da2eb). The plan uses index seeks only.
- QA tooling boundary: `--perf-log` and `--perf-script` require `isQA` (a `--database-path` or the QA bundle); signposts are always on and inert. Known, not fixed: the dev bundle shares `local.macbook.storage-monitor.viewer` with the installed app, so `@AppStorage` view preferences (and the perf script's temporary visualization switch, restored at the end) write the shared standard domain in QA runs. This predates V2; V2 adds `treeNavigatorExpanded` and `event.showEvidence`.
- Fixed from the diff review: (1) the Trash preflight called `realpath` for empty observation lists, which could use up the 20 s budget on large folders (result unchanged); (2) refusal guidance matched keywords inside the person's folder paths; (3) refusal guidance for PATH executables, changed items, unassessable Git or database state, and permission-limited budget refusals; (4) a confirmation's 60 s lifetime is enforced again at the moment of the move (user decision); (5) the window focus guard re-armed and leaked its monitor when its view moved into the same window again; (6) the QA marker vanished from the window title after leaving Monitoring (this was also in HEAD).
- Native (dark, 1000×648, disposable catalog): empty-state wrap VERIFIED; Settings VERIFIED (status loads asynchronously, QA disables actions). NOT VERIFIED: 3D label click and VoiceOver. The session was stopped because other automation brought Chrome forward over the viewer, and one click may have landed on that page's static text. The QA-title fix was verified by build and tests only.
- Suites on final source: viewer 883, monitor self-test 235, inventory model 67, inventory integration 349 (logs: verification/rc-*.log).
