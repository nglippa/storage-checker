# Storage Monitor V2 — visual evidence

Two collages:

- `storage-monitor-v2-collage-1-inventory-cleanup.png` (6400 × 21740)
- `storage-monitor-v2-collage-2-monitoring-experience.png` (6400 × 17260)

Unretouched originals at 2× pixels are in `source-screenshots/`. Tiles prefixed `before-` are copies of the prior UX milestone's renders (`artifacts/visual-review/source-screenshots/`), used for before/after rows.

## Capture method — HEADLESS, not native

Every image is an **offscreen render** of the real SwiftUI views (`capture-tools/Capture.swift`, built by `capture-tools/prepare.py`):

- activation policy `.prohibited`
- borderless windows at −30000,−30000 that are never shown (asserted per capture; final log: `visibleWindows=0`)
- no pointer, keyboard or accessibility input; states are set through model properties

Data is an APFS clone of the preserved QA catalog `build/inventory-fresh-20261023T031313Z/previous-catalog.sqlite3`, placed in `/private/tmp`, with trash disabled (`allowsTrash = false`). Live capacity is real.

The native title bar and toolbar are absent. These renders do **not** demonstrate click, hover, focus or keyboard behaviour.

Known capture artifact (also present in the prior milestone): the inspector column of an offscreen split view renders dim text, and in light mode its disclosure chevrons are missing (m04, m05). The same component renders correctly on its own (m06, m08). Native appearance of that column is **NOT VERIFIED**.

## Verification status

| Area | Status | Evidence |
|---|---|---|
| Viewer model suite | VERIFIED | `../verification/final-viewer-tests.log`: 855 PASS, 0 FAIL (baseline 847; +8 chart-selection checks) |
| Inventory browser model suite | VERIFIED | `../verification/final-inventory-model-tests.log`: 67 passed, 0 failed |
| Viewer build (macOS 26.5 SDK) | VERIFIED | `../verification/final-build-gui.log` |
| Cleanup authority, evidence, diagnostics and shared code unchanged | VERIFIED | 30 files byte-identical to `../baseline/source/` (all `SourcesShared`, `CleanupInspectorView`, `DiagnosticAnalysis`, `EventPanelText`, `HistoryReader`, `LiveCapacity` and cleanup tests) |
| Chart → event mapping only by exact measurement ID, container and timestamp | VERIFIED (model) | `StorageChartSelection` tests; filtered-out or orphan readings select nothing |
| Layout at 1000 × 640 pt content (1000 × 700 window), both appearances | PARTIALLY VERIFIED | m02, m03, m05, m10, i02 headless renders |
| Living Tree 2D/3D, selection and Inspector synchronization | PARTIALLY VERIFIED | i04–i07 headless renders of model-driven state |
| Chart click, hover, Living Tree gestures and camera transitions, disclosure clicks, keyboard focus, VoiceOver | NOT TESTED | needs an attended native session |
| Inventory integration suite (`scripts/test-inventory.sh`) and monitor `self-test` | NOT TESTED in V2 | sources under test are byte-identical to baseline |

## Remaining UX limitations

- At minimum height the event table shows about 4 rows, by design (270 pt reserve), and the summary scrolls independently.
- The Living Tree encoding is approximate. Branch width ≈ indexed allocation, while length and position show hierarchy, not bytes. The legend under the tree states this.
- Cleanup Review on this QA catalog has no current review candidates: the saved evidence is stale. The empty state explains this and offers next steps. Populated eligible-candidate rendering was not captured on fresh evidence.
- The chart's y axis starts at 0 GB, which is honest but compresses changes of a few GB. Change values appear on hover and selection, not as permanent labels, to avoid collisions.
