# Disk Inventory: nested storage map, polish and the Chrome signing clones

Date: 2026-10-25. Uncommitted. Not packaged or installed. No GUI automation; nothing here has been verified in a real window.

Evidence:
- `build/map-polish-1/` (test logs);
- `build/map-polish-1/evidence/` (offscreen renders, benchmarks, the Chrome clone listing).

## Files changed

| File | Change |
|---|---|
| `SourcesShared/InventoryModels.swift` | `explorerSpan(parentID:count:pageLimit:)`: a page-size parameter, so nested tiles read one page of 60 in one snapshot with their exact remainder |
| `SourcesShared/InventoryMap.swift` | Optional `residual` region (the folder total beyond the children shown); `residualID` |
| `SourcesShared/InventoryPresentation.swift` | `compactSize` (no "Previously"/"≈" prefix; partial values keep "Partial"); `sharedFreshness` (the earlier-size note most entries share) |
| `SourcesGUI/InventoryExplorerView.swift` | Nested-content cache (`InventoryNestedContent`, at most 24 folders, least recently used dropped, refreshed in place after index changes); `select(_:)` reveals and scrolls to entries chosen on the map; resizable, remembered map height; shared-freshness line; "Measurement" column; compact sizes with full wording on hover |
| `SourcesGUI/InventoryMapView.swift` | Nested tiles with a title strip; dominant-subfolder following; selection ring and fill; legible-only labels; hover from nested tiles |
| `SourcesGUI/InventoryView.swift` | Header: one status line, with counts, details, deferred folders and the completion note behind **Indexing details** (remembered) |
| `tests/GUIModelTests.swift`, `tests/InventoryExplorerTests.swift` | New assertions (below) |

No schema, indexer, worker or LaunchAgent change.

## Nested storage map

**When a tile nests:** folder tiles at least 150 × 96 pt (at most 16 per map, in map order) show their own contents under an 18 pt title strip.

**What it reads:**
- One `explorerSpan` per folder: its 60 largest children and the exact remainder, in one SQLite snapshot.
- **Dominant subfolder:** if one subfolder holds at least 90% of the folder, the tile follows it (up to 4 hops, one bounded read each). The strip then reads, for example, "Users › nicholaslippa" or ".ollama › models › blobs". Without this, the root map showed Users as one undivided block.

**Accounting inside a tile:**
- children, the exact **Other items** (count, bytes, unmeasured count) and a **Rest of folder** region together divide the folder's own allocated total;
- Rest of folder is the folder total minus the children's indexed total, which includes the outer folder's other entries when a subfolder is followed;
- areas are proportional within the folder, and unmeasured entries get no area;
- if the children's indexed total exceeds the folder's (mixed stale sizes; 1 of 544 nested folders on this catalog), the contents are scaled to fit the tile.

**Interaction:**
- a nested folder opens it;
- a nested file selects it, expands its folder in the outline and asks the outline to scroll to it;
- a nested Other items or Rest of folder opens the folder shown;
- hover shows the full state.

**Freshness:** nested contents are kept while indexing and re-read in place, at most every 5 s.

## Visual polish

- **"Previously" stated once:** rows and tiles show compact sizes. When most entries share an earlier-size state, one line above the map says so. The new **Measurement** column shows only exceptions (Access restricted, Partial measurement, Kept changing, and so on), and the full wording stays in tooltips and the map status line. "Partial" stays on values because it means a lower bound.
- **Labels:** drawn only on tiles at least 72 × 34 pt; nested folders use a one-line strip.
- **Map height:** 400 pt by default, resized by dragging the divider, and remembered. The outline keeps at least 170 pt.
- **Selection:** the selected tile gets a 2.5 pt accent ring and a stronger fill. A nested file selected on the map is revealed and scrolled to in the outline (scroll is **not verified** in a real window).
- **Header:** the title, path, one status line, the refresh progress bar when present, and the accounting line. The technical counts, detail sentence, deferred folders and completion note sit behind **Indexing details**.
- **Status column:** headed **Measurement**.
- **Style:** no gradients, cards or new chrome; existing tokens and system colors are used in both appearances.

## Benchmarks (isolated `VACUUM INTO` copy of this Mac's catalog, 3.0M nodes)

| Measure | Result |
|---|---|
| Top-level map, 1,000 navigations | page read median 0.31 ms, p95 0.51 ms; remainder median 0.21 ms; layout at most 0.09 ms |
| Top-level accounting | 0 of 1,000 folders where tiles plus Other items differ from the indexed children total |
| Nested reads, 500 maps (544 nested folders, 496 dominant-subfolder hops) | per map median 0.39 ms, p95 4.8 ms, max 12 ms; per nested folder median 0.74 ms, max 9.5 ms; nested layout at most 0.06 ms |
| Widest real folder (Chrome `Cache_Data`, 33,579 entries) | first page 25 ms (cold), exact remainder 1.9 ms, 121 tiles plus Other items of 33,459 entries / 1.06 GB |
| Memory | outline and map cache 26 MB after 1,000 navigations; nested cache bounded at 24 folders (5.8 MB in the nested harness) |

## Tests

| Suite | Result |
|---|---|
| Inventory | **290/290** (new: a 60-entry nested span plus exact remainder equals a 1,234-entry folder's indexed total) |
| Viewer model | **398/398** (new: nested children, Other items and residual divide the folder tile proportionally and sum to its total; unmeasured counted, not drawn; compact vs. full sizes; "Partial" kept; shared freshness with exceptions) |
| Monitor self-test | 233/233 |
| Builds | Monitor and viewer: no errors or warnings |

Earlier assertions still pass: explorer state, selection sync, index updates, protected and empty states, and the single-snapshot consistency test.

## Not verified in a real window

- the nested tiles' look and legibility;
- hover;
- the drag-to-resize divider and its cursor;
- scroll-to-row from the map;
- the Indexing details toggle;
- both appearances.

**Limitation found:** drilling into Other items in a long-tail folder, such as Chrome's 33k-entry cache, reveals only the few entries large enough to see at true proportional area per click. The outline's sorted list is the better tool there.

## Chrome code-sign clone investigation (read only)

**Location:** `/private/var/folders/bk/8wp2n0gs68ld90xn1nbj04lm0000gn/X/com.google.Chrome.code_sign_clone/`.

| Question | Finding | Confidence |
|---|---|---|
| Count, owner | 50 subfolders `code_sign_clone.XXXXXX`, each holding one `Google Chrome.app.bundle`; owner `nicholaslippa`, mode `drwx------` | Established |
| Ages | Created and last modified 2026-10-10 to 2026-10-24: 21 on Oct 10, 8 on Oct 19, 9 on Oct 22, and the rest spread out. None modified after creation | Established |
| Versions | 154.0.8037.99 ×22; 155.0.8059.40 ×2; 155.0.8059.41 ×2; 155.0.8059.80 ×10; 155.0.8059.85 ×7; 156.0.8078.47 ×7. Installed Chrome: 156.0.8078.47 | Established |
| In use | The running Chrome (pid 40733, started Oct 22 09:23, version 155.0.8059.85) executes from `code_sign_clone.C5tZVH`, created that minute. macOS's open/save panel service has a resource open in `vJjl3R`. The other **48 have no open files**. No updater process was running. | Established at 01:21 CDT on Oct 25 (a point in time) |
| Apparent totals | Per-clone allocated size summed: **100.8 GB** (apparent 100.7 GB). The inventory catalog records the parent folder as complete, 50 children, **100.74 GB** | Established |
| APFS clone sharing | `F_LOG2PHYS_EXT` (files opened read-only, no data read) mapped the 526 MB framework binary at 3 offsets (start, middle, end). Within every version, **all clones map to the same physical device offsets**, and the 7 version-156 clones map to the **same blocks as the installed app** | Established for the framework binary at the sampled offsets; inferred for every other file and offset |
| Physical space | At most about one bundle per version: 2.25 + 1.51 + 2.26 + 2.26 + 1.51 + 1.52 ≈ **11.3 GB**. Less, because version 156 shares its blocks with the installed app, and versions may share blocks with one another (not measured) | Inferred upper bound |
| Contribution to the gap | The catalog counts 100.74 GB here, but the blocks are at most about 11.3 GB. So these clones alone over-attribute roughly **89 GB**, which accounts for the "indexed sizes exceed the Data volume" gap (63–72 GB, other effects pulling the other way) | Inferred, high |
| Active or stale | 2 active (in use); 48 **appear stale**: older runs of the installed or previous versions, with nothing open in them. Whether Chrome would still reference them later is not established | Indeterminate for the 48 |
| Reclaimable | Not the 100.8 GB sum. At most the blocks unique to versions no longer installed or running: 154.0.8037.99, 155.0.8059.40, .41 and .80, about **8.3 GB** upper bound. Less if those versions share blocks. Removing a single clone of a version frees almost nothing while others of that version remain | Inferred upper bound |

**Safe, user-controlled follow-up** (nothing was changed):
1. **Relaunch Chrome.** The running copy (155) is older than the installed one (156), and Chrome is expected to clear its own signing clones. Then count the folders again: `ls /private/var/folders/bk/8wp2n0gs68ld90xn1nbj04lm0000gn/X/com.google.Chrome.code_sign_clone | wc -l`, or look at the folder in the map.
2. **If many remain with Chrome quit,** removing the folders whose version is not installed is a choice only you should make. Expect at most about 8 GB back, and check the result with `df`.
3. **Storage Monitor shows the folder at 100 GB** because it counts each clone in full, as the header's "indexed sizes exceed the Data volume" note already warns. A possible later improvement is clone-aware attribution (comparing physical extents of large files), which would need an indexer change and is out of scope here.

## Refinement round (after screenshot review)

Evidence: `build/map-polish-2/` (logs and offscreen renders).

1. **Hierarchy-aware palette, same hue:**
   - neighboring top-level groups alternate slightly in brightness;
   - nested contents are a step brighter than their parent;
   - a nested group gets a soft band behind its title strip and a firmer 1.25 pt edge;
   - files stay neutral, and the state cues (hatched partial, dashed earlier size) are unchanged.
2. **Labels:** drawn only on tiles at least 84 × 40 pt at the top level and 96 × 42 pt inside groups. Smaller tiles rely on hover.
3. **Header consolidated:**
   - the breadcrumb trail is the title, with the current folder as bold text and earlier folders as links;
   - the full path is on hover;
   - one line carries the status, inline refresh progress, Indexing details and the accounting summary with Details;
   - the separate path line and breadcrumb row are gone, so the map starts about 120 pt higher.
4. **Persistent basis label** above the map: "Showing indexed allocation · Shared APFS blocks may be counted more than once", with a tooltip explaining why this is not reclaimable space. The shared freshness note moved into the map's status line, and appears as its own line only when the map is hidden.
5. **Fix found in the renders:** a protected folder re-queued by a refresh is "stale" with no earlier value. It was labelled "Previously measured" (then hidden as the shared note) and showed "Not measured" twice with "0" items. It now reads **"Waiting to be rechecked"** with a single "—" (viewer test added).

The relationship between the map and the Explorer is unchanged.

Tests: inventory 290/290, viewer 399/399, monitor 233/233; builds have no errors or warnings. Real-window behavior remains **NOT VERIFIED**.

## Real-window checklist

**Map**
- [ ] The root map divides Users into "Users › nicholaslippa" with readable child tiles; private shows its dominant subfolders.
- [ ] Clicking a nested folder opens it; clicking a nested file selects it, expands its folder in the outline and scrolls to it.
- [ ] Hover over nested and top-level tiles shows name · size · state; tiny tiles have no text.

**Layout**
- [ ] Drag the divider under the map: the cursor changes and the height follows.
- [ ] Reopen the app: the map height is kept.

**Measurement wording**
- [ ] Rows show plain sizes; the "Most sizes in this folder…" line appears once; the Measurement column lists only exceptions.

**Header**
- [ ] The header shows one status line; Indexing details reveals the counts and deferred folders and is remembered.

**Navigation**
- [ ] Explorer, breadcrumbs, keyboard (↑ ↓ ← → Return ⌘C), context menu, Other items drill-down, search and rankings behave as in 1.0.5.

**Appearance**
- [ ] Both light and dark look right.
- [ ] Nothing overlaps the toolbar.
- [ ] Nothing feels slow.
