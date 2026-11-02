# V2 native acceptance checklist

The session uses the dev viewer `build/Storage Monitor.app` in legacy read-only test mode, on a disposable APFS clone of the QA catalog. This is **not** the strict QA app that `QA-WORK-STOPPED.md` forbids.

```
open -n "/Users/nicholaslippa/storage-checker/build/Storage Monitor.app" --args --database-path /private/tmp/storage-monitor-v2-native-acceptance/catalog.sqlite3
```

Trash is disabled in this mode. Do not use Finder actions on real paths.

Side effect: view-state preferences (visualization, panels, window frame) are written to the installed viewer's preference domain, `local.macbook.storage-monitor.viewer`.

Mark each item PASS, FAIL (with what you saw) or SKIP.

## Storage
1. The window opens at the minimum size, or resize it down to the minimum. Header, toolbar and Review Cleanup are visible and nothing overlaps.
2. Click a treemap tile. The same folder is selected in the Navigator, and the Inspector shows its name, size and share of parent.
3. Select a folder in the Navigator. The treemap highlight follows.
4. Inspector: click anywhere on the **Storage details** row and the **Cleanup & safety** row, not just the chevron. Each expands and collapses.
5. Hovering over tiles and rows shows hover feedback, and tooltips appear where expected.

## Living Tree
6. Switch to Living Tree. The tree fills the canvas and the controls are readable.
7. Click a branch. It highlights, and the Inspector shows its name, size, share of parent and **Explore Folder**.
8. Explore Folder (or double-click) moves deeper with a smooth camera move. **Up** or Esc returns. You stay oriented.
9. Zoom −/+, Fit, Reset and View Selection each do what their label says.
10. 3D: drag to orbit, then switch back to 2D. The selection is kept and the view is not disorienting.
11. Help opens readable navigation help.
12. Show/Hide Navigator works, and the tree stays usable with the Navigator open.
13. Is it clear which branches are biggest and what branch width means? (Judgement: yes / partly / no.)

## Cleanup Review
14. Review Cleanup opens the review. The empty state's buttons work: See all assessments, Refresh review.
15. All assessments: select a row. The Inspector shows its status and reason. No Trash action is offered.

## Monitoring
16. Hovering the chart snaps to recorded points and shows the time and value.
17. Click an orange or green event point. The matching row is selected and the explanation panel opens.
18. Click a point with no visible event. A message explains why, and nothing else gets selected.
19. Up/Down arrows in the event table move the selection, and the panel follows.
20. Explanation panel: **Full explanation** and **Details and evidence** toggle by clicking the whole row.
21. Minimum window: the chart is not clipped, events are visible, and the panel is usable.
22. Settings opens. **Permission details** toggles.

## Appearance
23. Repeat items 2, 7 and 17 in the other appearance (System Settings → Appearance), or launch again with `--appearance light` / `--appearance dark`.
24. The dark-mode event panel text is readable. The offscreen renders showed it dim; this confirms whether the native app does.

## Keyboard
25. Tab moves focus through the toolbar and the primary controls, with a visible focus ring.
