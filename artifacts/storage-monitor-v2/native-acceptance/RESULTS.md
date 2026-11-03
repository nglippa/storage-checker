# V2 native acceptance — results (2026-10-28)

The agent drove the session with the user's explicit authorization. The dev viewer `build/Storage Monitor.app` ran in legacy read-only test mode on a disposable APFS clone at `/private/tmp/storage-monitor-v2-native-acceptance/catalog.sqlite3`, with Trash disabled. The window was on display 3, starting at 1280×780 and later resized to the 1000×700 minimum. Dark appearance only. No other window was touched.

**Confound:** for roughly the first half of the session (items 1–13 and the switch to Monitoring), the monitor build and the inventory integration suite were compiling and running in the background. Latencies from that half are marked *(under load)*. Latencies from the second half were measured on an idle CPU.

| # | Check | Result | Notes |
|---|---|---|---|
| 1 | Layout, no overlap | PASS | 1280×780 and the 1000×700 minimum (Storage) |
| 2 | Treemap click selects and syncs | PASS, slow | Selecting a nested tile took 2–5 s *(under load)* with no immediate feedback |
| 3 | Navigator selection syncs to the tree/map | PASS | |
| 4 | Whole-row Inspector disclosure | PASS | |
| 5 | Hover feedback and tooltips | PASS | Tile highlight plus size and state tooltip. The tooltip once stayed visible after the pointer left |
| 6 | Living Tree fills the canvas, readable controls | PASS | |
| 7 | Click a branch to select it | PASS, defect | Clicking the branch stroke works. **Clicking a branch label does nothing** |
| 8 | Explore deeper / Esc up | PASS, slow | Each direction took 2–10 s *(under load)*. Only the toolbar spinner shows progress. Selection is kept when returning |
| 9 | Zoom, Fit, Reset, View Selection | PASS | Smooth animated camera, and labels adapt to the zoom level |
| 10 | 3D orbit, then 2D, keeping the selection | PASS | Smooth cross-fade |
| 11 | Help | PASS | |
| 12 | Show/Hide Navigator | PASS | At 780 pt height the tree shrinks to about 200 pt when the Navigator is open |
| 13 | Is branch size understandable? | PARTLY | In 2D the 323.88 GB Users stem is not visibly thicker than the 29 GB Applications branch. The labels carry the size, not the geometry |
| 14 | Review Cleanup, empty state actions | PASS | Clear loading state, with Cancel and "no filesystem scan" |
| 15 | All assessments: select an item | PASS | Status, reason and "Recovery unknown" shown. No Trash action. "Nothing is moved here" |
| 16 | Chart hover snaps to points | PASS | Exact time and value |
| 17 | Click an event point: row, panel and chart linked | PASS, defects | The panel opens 2–4 s later. **The selected row is not scrolled into view** |
| 18 | Point with no visible event | NOT TESTED | |
| 19 | Arrow keys in the event table | PARTIAL | They work after Tab focuses the table. **After a mouse click on a row with the panel open, the table loses focus** (grey selection) and the arrows do nothing. The focus restore window is 0.5 s, shorter than the native panel rebuild |
| 20 | Explanation disclosures | PASS, minor | Whole-row toggle works. The expanding text briefly overlaps the next row during the animation |
| 21 | Minimum window, Monitoring | PARTIAL | The chart's bottom (0 GB line and date axis) is clipped until the summary is scrolled. About 4 event rows fit. The selected row can sit below the visible rows |
| 22 | Settings | NOT TESTED | The input tool cannot send ⌘, |
| 23 | Other appearance (light) | NOT TESTED | |
| 24 | Dark event panel text readable | PASS | The offscreen dimness was a capture artifact |
| 25 | Tab focus | PARTIAL | Tab reaches the search field and the table. Buttons need macOS keyboard navigation turned on (system setting). The search field shows no visible focus ring |
| — | Storage ↔ Monitoring tab switch | **FAIL (performance)** | Storage → Monitoring took 3–7 s *(under load)*. **Monitoring → Storage took 5–13 s on an idle CPU** |
| — | Event list empty by default on old data | Finding | The default time filter (24 h) is not counted as a filter, so "Clear Filters" stays disabled even though the empty state says "clear your filters" |

## Regression pass (same session)
- Monitor `self-test`: 235 passed, 0 failed (`../verification/final-monitor-self-test.log`)
- Inventory integration (`scripts/test-inventory.sh`): 349 passed, 0 failed (`../verification/final-inventory-integration-tests.log`)
- Viewer model: 855 passed. Inventory browser model: 67 passed (earlier the same day)

## Confirmed defects, by priority
1. Monitoring → Storage tab switch takes 5–13 s (idle CPU), plus related multi-second selection and navigation latency without feedback.
2. Clicking a row in the event table drops keyboard focus while the panel is open (regression of the earlier focus fix under native timing).
3. A chart-selected event row is not scrolled into view.
4. Living Tree branch labels are not clickable.
5. At the minimum height, the Monitoring chart bottom is clipped until you scroll.
6. "Clear Filters" is disabled while the default time filter hides every event.
7. Minor: disclosure animation overlap. A treemap tooltip can linger.
