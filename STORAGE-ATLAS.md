# Storage Atlas — Disk Inventory redesign

Date: 2026-10-25. Uncommitted. Not packaged or installed. No GUI automation; nothing here has been verified in a real window.

Evidence:
- `build/storage-atlas-1/` (test logs);
- `build/storage-atlas-1/evidence/` (dark and light renders, benchmarks, render timing, `vmmap` attribution).

## 1. Architecture and files changed

**Reused unchanged:**
- the indexer, SQLite schema and worker;
- `InventoryReader` (`explorerChildren`, `explorerSpan`, `explorerRemainder`);
- `InventoryMapPlan` (proportional squarified layout, exact Other items and residual);
- `InventoryExplorerState` (expansion, lazy pages, keyboard, selection, bounds);
- the shared `InventoryExplorerController` (one navigation and selection model, nested cache, single-snapshot reads).

| File | Change |
|---|---|
| `SourcesShared/StorageAtlas.swift` (new) | Pure, testable presentation logic: `AtlasPalette` (region hues, depth steps, treatments), `AtlasZoom` (uniform-scale enter/leave transforms, Reduce Motion), `AtlasHitTest` (top-level and nested plates), `InventoryInspectorPresentation`, `InventoryNavigatorGlyph`, `InventoryRecency` (bounded least-recently-used keys) |
| `SourcesGUI/StorageAtlasView.swift` (new) | The Atlas: one `Canvas` paints every plate; hover lens; click to select, double-click to open; enter/leave zoom; legend; basis label; up button; accessibility children per plate |
| `SourcesGUI/InventoryNavigatorView.swift` (new) | The Navigator (native `List`), shared actions, and the Inspector |
| `SourcesGUI/InventoryExplorerView.swift` | Layout: the Atlas on top (resizable, remembered), then the Navigator or Table, then the collapsible Inspector; the nested cache uses `InventoryRecency` and never re-adds a folder evicted mid-read |
| `SourcesGUI/InventoryMapView.swift` | **Removed**, replaced by the Atlas (its behavior is preserved there) |
| `tests/GUIModelTests.swift`, `scripts/test-gui.sh` | 14 new assertions; `StorageAtlas.swift` added to the test build |

## 2. Major visual design decisions

- **A landscape of plates, not a mosaic:**
  - top-level entries are raised plates lit from above (vertical gradient, a highlight along the top edge, a soft shadow);
  - folders large enough become recessed basins with a name strip, holding their contents as smaller raised plates;
  - plates sit on a quiet ground with 3 pt channels between them.
- **Restrained region hues:**
  - each top-level region takes one of six muted hues (slate, teal, violet, sage, clay, steel) so neighbouring places read as different;
  - contents keep their region's hue a step brighter;
  - files are near-neutral graphite tinted by their region.
- **Honest states, independent of hue:**
  - partial is hatched;
  - an earlier size is quieter, with a dashed edge;
  - Other items is dotted neutral; the residual ("Rest of folder") is flat and recessed;
  - unmeasured entries are never drawn and are counted in the footer.
  - When most entries share an earlier-size state, the footer states it once and plates drop the per-plate dashes; hover and the Inspector still give each item's exact state.
- **Geometry is untouched:** every plate's area is exactly proportional to indexed allocated size, as before. Transitions use uniform scaling only.
- **Context without clutter:**
  - labels appear only on plates at least 84 × 40 pt (96 × 42 pt inside regions);
  - everything else is in a small material lens that follows the pointer;
  - the persistent basis label reads "Showing indexed allocation · Shared APFS blocks may be counted more than once".
- **One design language across the three parts:** the Navigator's share bars use the same region hues as the Atlas, and the Inspector uses the same states, glyphs and wording.
- **Both appearances:** dark and light are tuned separately (lightness, saturation, shadows, highlight strength).

## 3. Behavior

**Atlas**
- **Click:** selects; the Navigator and Inspector follow, and a nested file expands its folder in the Navigator and scrolls to it.
- **Double-click:** opens a folder, or the region holding a grouped plate.
- **Other items:** clicking it shows the next window (Back returns).
- **Up button:** goes to the enclosing folder; the breadcrumbs in the header also navigate.
- **Entering a folder:** the new view grows out of the plate it occupied. **Leaving:** the parent starts enlarged around the folder you left, then settles.
- **Reduce Motion:** a 0.15 s cross-fade instead.
- **Hover:** brightens the plate and shows the lens. Nothing animates while idle.

**Navigator** (default; the detailed table remains as **Table**, the technical view)
- **Rows:** a disclosure chevron, the file-type icon, the name (folders medium weight, unmeasured entries secondary), a state glyph only for exceptions, the compact size, and a share-of-parent bar in the region's hue.
- **Keyboard:** native ↑/↓; ← and → collapse, expand and move; Return opens; ⌘C copies the path.
- **Mouse and menus:** double-click opens; the context menu has Open, Reveal in Finder and Copy Path.
- **Paging:** "Show more" loads lazily, up to the 5,000-entry limit per folder.
- **Search:** typing in the search field shows the results list, as before.

**Inspector** (collapsible, remembered; slides in, or fades under Reduce Motion)
- **Identity:** the selection's icon, name and type (Launch Services description), and the full path (selectable).
- **Sizes:** allocated, logical, contents (items, files, folders) and the measured time.
- **Share of parent:** a bar with the exact share.
- **Measurement:** the state, with a plain explanation (for example "macOS did not allow Storage Monitor to read this folder, so its size is unknown, not zero").
- **Actions:** Open, Reveal in Finder, Copy Path.
- **Nothing selected:** it describes the current folder.

## 4. Performance

Isolated `VACUUM INTO` copy of this Mac's catalog, about 3.0M nodes.

| Measure | Result |
|---|---|
| Atlas first-page read, 1,000 navigations | median 0.32 ms, p95 1.0 ms |
| Exact remainder | median 0.22 ms |
| Layout | at most 0.12 ms |
| Accounting | exact in 1,000 of 1,000 folders |
| Nested reads, 500 maps | median 0.35 ms per map, p95 4.2 ms; per nested folder at most 5.3 ms; nested layout at most 0.04 ms; 1 of 544 nested folders drawn scaled to fit (its children's total exceeds its own) |
| Full-page offscreen draw (header, Atlas canvas, Navigator, Inspector, 1440 × 1000) | median 33 ms; unchanged after 40 navigations (Atlas hidden: 25 ms) |
| Cached rows / nested folders after 40 round trips | 215 / 6 (bounded at 12,000 rows and 24 folders) |

**Memory, measured in the offscreen harness:**
- **Footprint:** about 120 MB before the first navigation, rising to a **stable plateau of about 243 MB** from the 10th to the 40th round trip. With the Atlas hidden it stays about 116–123 MB.
- **Attribution (`vmmap`):** the difference is about **110 MB of "owned unmapped (graphics)"**, GPU memory allocated once by SwiftUI's Metal-backed `Canvas` renderer. The malloc heap is the same with and without the Atlas (about 51–54 MB dirty).
- **What it isn't:** disabling shadows, zoom, fade or accessibility children did not change it.
- **Reclaimed:** a reading taken after the run's final `vmmap` was back to 121.9 MB.
- **Open question:** whether a real window behaves the same is not established.

**Memory, observed in a real window (2026-10-25, development build, isolated read-only database clone):**
- Baseline 224 MB (eight seconds after launch, view state not recorded); 226 MB a few seconds later.
- Monitoring tab: 135 MB, with 2.6 MB dirty graphics. After switching to Disk Inventory: 108 MB.
- Three samples over 15 seconds on Disk Inventory: 130 MB, stable.
- The 109 MB of graphics seen at baseline was absent in every later sample. The cause is **not established**: I could not locate the Atlas toggle in the accessibility tree, so no controlled visible-versus-hidden comparison was made.
- **Not verified:** resize, return to idle after navigation, and the Atlas hover, click and Reduce Motion behavior in a real window. Screenshots were blocked by Screen Recording permission.
- The offscreen figures above (120 MB versus 243 MB) are **not reproduced** in the real window. Do not treat the graphics overhead as eliminated, and do not redesign the renderer on this evidence.

## 5. Tests

| Suite | Result |
|---|---|
| Inventory | 290/290 |
| Viewer model | **414/414** (re-run on the current tree; the earlier 413 count predates the latest test edit) |
| Monitor self-test | 233/233 |
| Builds | Monitor and viewer: no errors or warnings |

**New assertions:**
- **Palette:** distinct neighbouring hues, a fixed order; contents brighter in the same hue; earlier sizes keep the hue; files near-neutral (dark and light); treatment mapping.
- **Zoom:** entering centres the whole view inside the plate; leaving centres the folder you left; transitions end exactly at identity; Reduce Motion disables spatial zoom.
- **Hit testing:** nested plate, top-level plate, outside the map.
- **Inspector:** exact share of parent; a protected entry has no share and says "unknown, not zero".
- **Navigator glyphs:** none for measured entries; protected, earlier and waiting states each have their own.
- **Cache bounds:** least-recently-used capacity and drop order.
- **Atlas-to-Navigator sync:** a nested selection expands its folder, becomes a visible row, and ← moves to its folder.

**Existing assertions still pass:**
- exact area accounting, nested accounting and the single-snapshot read under concurrent commits;
- protected, empty and deleted states;
- keyboard behavior;
- index updates during navigation;
- large directories.

## 6. Offscreen renders (not real-window verification)

- `build/storage-atlas-1/evidence/atlas-root-dark.png`, `atlas-home-dark.png`
- `build/storage-atlas-1/evidence/atlas-root-light.png`, `atlas-home-light.png`

## 7. Known limitations

1. **No real-window verification:** nothing is verified in a real window (checklist below). That includes the zoom feel, hover lens placement, List selection colors and the Inspector's slide.
2. **Atlas graphics memory:** about 110 MB of GPU memory in the offscreen harness. It is stable, but it's the biggest cost of the redesign; a Core Graphics or layer-based renderer is the fallback if it shows up in a real window.
3. **Approximate label widths:** label truncation in the canvas uses an estimated character width, so a few long names lose a character at plate edges.
4. **Leave transition:** the "leave" zoom needs the parent's previous geometry. The first visit to a parent (via breadcrumbs from deep inside) cross-fades instead.
5. **One level of nesting:** the Atlas shows one nested level (with dominant-subfolder following, as before). Long-tail folders are better read in the Navigator.
6. **Behavior change:** single click on a folder plate now selects it (the Inspector shows it), and double-click opens it. Previously a single click opened.

## 8. Manual real-window checklist

**Atlas**
- [ ] Disk Inventory opens with the Atlas above the Navigator and the Inspector on the right.
- [ ] Regions have distinct, restrained hues; basins show their contents; nothing looks like flat rectangles.
- [ ] Hover a plate: it brightens and a small lens shows name, size and state; tiny plates have no text.
- [ ] Click a plate: the Navigator row and the Inspector follow; a file inside a region expands its folder in the Navigator and scrolls to it.
- [ ] Double-click a folder: it zooms in from its plate. Press the up button or a breadcrumb: it zooms back out around the folder you left.
- [ ] With Reduce Motion on (System Settings → Accessibility → Display), the same moves are short cross-fades.
- [ ] Other items opens the next window and Back returns.
- [ ] Hatched (partial), dashed (earlier, when not the folder's shared state) and the footer counts of unmeasured items appear where expected.

**Navigator**
- [ ] ↑/↓, ←/→, Return and ⌘C behave as described.
- [ ] Right-click offers Open, Reveal in Finder and Copy Path.
- [ ] "Show more" loads.
- [ ] Switching to **Table** shows the detailed columns, and back again.

**Inspector**
- [ ] The Inspector shows sizes, share, state with explanation, and actions.
- [ ] Hiding and showing it is smooth and remembered.

**Layout and appearance**
- [ ] Drag the divider under the Atlas: the height follows and is remembered.
- [ ] Light and dark appearance both look right (the app's Appearance setting).
- [ ] Watch for sluggishness and, if curious, Activity Monitor's memory for the viewer.
