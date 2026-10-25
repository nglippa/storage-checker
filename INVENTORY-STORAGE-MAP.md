# Disk Inventory explorer readiness and storage map — milestone 2

Date: 2026-10-25. Uncommitted. Not packaged or installed. No GUI automation; nothing below was checked in a real window.

Evidence: `build/storage-map-1/` (test logs) and `build/storage-map-1/evidence/` (benchmark, offscreen renders).

## 1. Files changed

| File | Change |
|---|---|
| `SourcesShared/InventoryMap.swift` (new) | `InventoryMapPlan`: the window of tiles, the exact "Other items" group, drill-down, selection lookup, squarified layout |
| `SourcesShared/InventoryModels.swift` | `explorerRemainder(parentID:skip:)` and `InventoryChildRemainder` |
| `SourcesShared/InventoryExplorer.swift` | The root is no longer recorded as "expanded", which had pinned every visited folder in memory; reloads keep the root's pages |
| `SourcesGUI/InventoryMapView.swift` (new) | The map: tiles, hover, click, legend, status line, drill-down header |
| `SourcesGUI/InventoryExplorerView.swift` | Controller owned by the browser model; map windows and remainders; the map above the outline in a split view with a toggle; double-click opens a folder |
| `SourcesGUI/InventoryView.swift` | The model owns the shared `explorer`; navigating keeps Explorer mode (it used to drop to Contents) |
| `tests/GUIModelTests.swift`, `tests/InventoryExplorerTests.swift`, `scripts/test-gui.sh` | New tests and compile entries |

## 2. Explorer readiness (Phase 1)

Each item below is verified by code review and by model or fixture tests. **Not verified in a real window.**

- **Default view:** Explorer is the default Browse mode. Navigating now keeps it; the offscreen render showed that it previously switched to Contents (`evidence/bug-navigation-left-explorer.png`), which is fixed.
- **Expand and collapse:**
  - via the chevron, → and ←;
  - collapsing moves a selection inside the folder to the folder;
  - cached pages are reused on re-expansion.
- **Focus and selection:**
  - selection is held as a node id in one shared state, used by the outline rows, the map and the selection bar;
  - it survives reloads;
  - going back up selects the folder you came from.
- **Double-click:** now *opens* a folder, the same as Return, a map tile click and Show Contents. The chevron and arrow keys expand in place. On a file, double-click does nothing beyond selecting it.
- **Context menu:** Show Contents (folders), Reveal in Finder, Copy Path. The selection bar repeats them, and ⌘C copies the path.
- **Truthful states:**
  - protected entries show "—" and "Access restricted", with no size;
  - earlier and partial sizes are labelled.
- **Distinct placeholder rows:** loading ("Loading…"), failure ("Couldn't load this folder." with Try Again), empty ("Empty folder") and the per-folder limit each have their own row.

## 3. Layout and interaction architecture

**One navigation model:**
- `InventoryBrowserModel` owns a single `InventoryExplorerController`;
- the outline and the map both observe it;
- the browser model's current folder (breadcrumbs, Go to folder…, Show Contents, map clicks) is the root of both.

**Map data:**
- **Source:** the root folder's pages already loaded for the outline (largest first), plus one exact remainder query for the children beyond the loaded span.
- **Remainder query:** `explorerRemainder` reads only the covering index `(parent_id, total_allocated DESC, name, id)`: `COUNT`, `SUM(total_allocated)` and the count of entries without a size, after the first *n* in explorer order.
- **Never touched:** the filesystem.

**Plan (`InventoryMapPlan`):**
- **Tiles:** up to 120 of the largest measured entries, each drawn when its region would be at least about 160 pt² (about 13 × 13).
- **Other items:** everything after the tiles in the window is one group with the **exact** indexed sum and count, plus how many have no measured size.
- **Unmeasured entries** (protected, unreadable, not yet listed) are never given area. They're counted in the group and in the map's status line.
- **Measured at zero** is reported as such, not as unmeasured.

**Drill-down:**
- Clicking Other items opens the next window of the same folder, starting after the drawn tiles. It loads another explorer page if needed, and the header shows "Other items from #121" with Back.
- Drill-down is offered only when it would show something new, and stops at the outline's 5,000-entry per-folder limit, which points to Largest items.

**Layout:** squarified treemap, in input order. Equal input gives an identical layout, and area is exactly proportional to the tile's indexed allocated size.

**Interaction:**
- clicking a folder tile navigates into it; breadcrumbs navigate back up;
- clicking a file tile selects that row in the outline;
- selecting a row in the outline outlines its tile, or the tile of its ancestor at this level;
- hover brightens the tile and shows name · size · coverage · items in the status line, with a native tooltip;
- tiles cross-fade and move with a 0.22 s ease when the folder or window changes.

**Visual language:**
- folders take a low-opacity accent tint, files neutral gray;
- partial folders are hatched;
- earlier or stale sizes get a lighter fill and a dashed edge;
- Other items is dashed neutral;
- the selection gets a 2 pt accent ring;
- labels (name and size) appear only in tiles of at least 72 × 34 pt;
- a small legend sits in the map header.

The map can be hidden with the grid toggle in the selection bar (remembered).

## 4. Performance

Isolated `VACUUM INTO` copy of this Mac's catalog: 3,452,094 nodes. Headless harness using the same state, plan and reader code as the views (`evidence/map-benchmark.txt`).

| Measure | Result |
|---|---|
| 1,000 map navigations, first page read | median 0.31 ms, p95 0.82 ms, max 5.0 ms |
| Exact remainder (21 of those folders had unloaded children) | median 0.23 ms, max 1.39 ms |
| Plan plus squarified layout | median 0.003 ms, p95 0.020 ms, max 0.046 ms (at most 121 tiles) |
| Accounting check, all 1,000 folders | **0** where tiles plus Other items differ from the indexed children total (bytes and count) |
| Memory after 1,000 navigations | 4,908 cached rows, footprint 25.3 MB |
| 200,000-entry folder | first page 39.8 ms (cold), exact remainder 10.1 ms for 199,800 entries, layout 0.02 ms |

**Notes:**
- **Generation filter:** with a per-row generation check, the remainder query took 244 ms. A parent's children always share its generation, verified across all 3.45M nodes, so the check was dropped.
- **Memory budget bug:** before the fix, navigating 1,000 folders kept 16,914 rows (41 MB) against the 12,000-row budget, because every former root was pinned as "expanded".
- **The real 200k folder** holds only empty files, so the map correctly shows "200,000 items, none using allocated space" with no drill-down. Drill-down through a large folder with real sizes is covered by tests.
- **Render time is not measurable without a real window.** Offscreen, the full page including the map renders, but that time is not representative.

## 5. Tests

| Suite | Result |
|---|---|
| Inventory | **288/288** (3 new map assertions on a real fixture) |
| Viewer model | **392/392** (12 new map and map/outline assertions) |
| Monitor self-test | 233/233 |
| Builds | Monitor and viewer: no errors or warnings |

**Map assertions:**
- areas proportional to size (to 1e-9);
- regions inside the map and non-overlapping;
- order preserved, and layout deterministic;
- Other items equals the exact sum and count, including entries beyond the loaded pages;
- a 200,000-entry folder draws 121 regions;
- drill-down shows the next entries and continues;
- a protected entry has no area and is counted as unmeasured, while partial and earlier sizes keep their values;
- zero-size entries are "no space", with no empty drill-down;
- an empty folder draws nothing;
- a file selected on the map is the outline's selected row;
- a deep outline selection outlines its ancestor tile;
- after an index update, tiles reorder and totals stay exact.

**Real-fixture map assertions:**
- 1,234 files: 121 regions plus Other items equal the indexed total exactly;
- the protected folder is counted as unmeasured;
- after the worker commits 40 more files during navigation, the map totals match a fresh read of the folder (1,274 entries).

## 6. Remaining limitations

1. **Real window:** nothing here is verified in a real window (checklist below).
2. **One level:** the map draws one level, children of the current folder only. Nested tiles (grandchildren inside large folder tiles) are not drawn.
3. **Per-folder limit:** drill-down stops at the outline's 5,000-entry limit; the rest is reachable through Largest items.
4. **Snapshot timing:** the remainder is read right after the loaded pages, from a different snapshot. If the worker commits between the two reads, the group can be off by those entries until the next reload (at most every 5 s while indexing).
5. **Tiny tiles:** a selection whose tile is very small is outlined, but the ring can be hard to see.
6. **Labels:** labels appear only on tiles of at least 72 × 34 pt. Smaller tiles rely on hover and tooltips, which are not available to keyboard users; VoiceOver labels are set per tile.

## 7. Real-window checklist

Use the installed build, with Disk Inventory open on this Mac's catalog.

**Explorer:**
1. Disk Inventory opens in **Explorer**, with the map above the outline.
2. Click a chevron: the folder expands with a short rotation, and a "Loading…" row may flash. Click it again to collapse.
3. Arrow keys: ↓/↑ move; → expands, then moves into the first child; ← collapses, then moves to the parent. Focus stays in the outline.
4. Return or double-click on a folder opens it: breadcrumbs extend, the map redraws, and the mode stays **Explorer**.
5. Click a breadcrumb: you go up, and the folder you came from is selected.
6. Right-click a row: Show Contents, Reveal in Finder (Finder comes forward, as you asked) and Copy Path (paste to check). ⌘C copies the selected path.
7. A protected folder (for example `~/Library/Accounts`) shows "—" and "Access restricted", with no chevron. "Previously …" and "≈ …" rows carry their notes.
8. An empty folder shows no chevron. A folder whose page fails shows "Couldn't load this folder." and Try Again, not "Empty folder".

**Map:**
1. Tile areas look proportional to the outline's sizes; the largest is first, top left.
2. Hover a tile: it brightens and the status line shows name · size · coverage · items.
3. Click a file tile: the same row is selected in the outline. Select a row deep in the outline: its ancestor tile gets the accent ring.
4. Click a folder tile: you navigate into it (breadcrumbs update).
5. In a folder with many entries, click **Other items**: "Other items from #N" and Back appear, and the tiles show the next entries.
6. Dashed tiles are earlier sizes and hatched tiles are partial; protected entries are not drawn and are counted in the status line.
7. The grid button in the selection bar hides and shows the map, and the choice is remembered.
8. Watch for anything slow when expanding, navigating or drilling (the database reads are 1–40 ms).

## 8. Next milestone

Nested tiles for large folders: draw each large folder tile's own largest children inside it, from the outline's cached pages only, with no new queries beyond one page per visible large folder. Also:
- keyboard navigation on the map (arrow keys between tiles, Return to open);
- an option to color tiles by file type.
