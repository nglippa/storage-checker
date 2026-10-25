# Disk Inventory explorer — milestone 1

Date: 2026-10-24. Uncommitted. Not packaged or installed.

Evidence: `build/explorer-1/` (test logs) and `build/explorer-1/evidence/` (benchmarks, offscreen renders).

## What it is

"Explorer" is now the first and default mode of Disk Inventory's Browse picker. It replaces the flat table in that mode with an outline of the current folder:
- folders expand in place, largest first;
- sizes are right-aligned, with a thin bar showing each entry's share of its folder;
- a quiet note column appears only when an entry is not fully measured.

The other modes (Contents, Largest folders / files / items, and search) are unchanged.

## Architecture

| Layer | Change |
|---|---|
| Query (`SourcesShared/InventoryModels.swift`) | New `InventoryReader.explorerChildren(parentID:after:limit:)` with `InventoryChildCursor` and `InventoryChildPage`. Keyset pagination follows the existing index `inventory_nodes_children_allocated (parent_id, total_allocated DESC, name NOCASE, id)`, with no sort and no `OFFSET`. Up to three range scans: the rest of the current size tier, smaller sizes, then unmeasured entries. The folder's path and chain staleness are resolved once per page (`childContext`); each row adds only its own staleness terms. The old reader resolved the full ancestry once per row. |
| State (`SourcesShared/InventoryExplorer.swift`, new) | `InventoryExplorerState`: root, expansion, loaded pages per folder (deduplicated by node id), the flattened visible rows with placeholders (loading, more, limit, empty, failed), Finder-style keyboard rules, selection rules, reload plan and memory bounds. Pure, so it is tested without SwiftUI. |
| View (`SourcesGUI/InventoryExplorerView.swift`, new) | `InventoryExplorerController` loads pages through the `InventoryReader` actor and reloads expanded folders after inventory changes, at most every 5 s. `InventoryExplorerView` is a native `Table` with indentation, an animated chevron, Launch Services type icons (looked up by type, no file access), a share bar, the size columns and a selection bar (Show Contents, Reveal in Finder, Copy Path). |
| Integration (`SourcesGUI/InventoryView.swift`) | A new `.explorer` browse mode, the default. The existing model keeps loading status, current folder and breadcrumbs, but fetches no flat page in this mode. Breadcrumbs, Go to folder… and Show Contents all go through the existing `navigate`, which also asks the worker to index the viewed folder first. |
| Presentation (`SourcesShared/InventoryPresentation.swift`) | A deferred folder reads "Kept changing · earlier size". `explorerNote` returns nothing for fully measured entries. |

No inventory engine, schema or worker change. The explorer never touches the filesystem: expansion reads SQLite only.

## Query performance

Isolated `VACUUM INTO` copy of this Mac's real catalog: 3,452,094 nodes, 1.45 GB.

| Read | Result |
|---|---|
| Root, first page | 0.30–0.55 ms |
| 200,000-entry folder, all 1,000 pages | first 1.43 ms, mean 1.22 ms, worst 2.28 ms |
| 177,152-entry folder, all 886 pages | first 1.39 ms, mean 1.24 ms, worst 2.25 ms |
| 50,000-entry folder, all 250 pages | first 1.37 ms, mean 1.20 ms, worst 1.72 ms |
| 1,000 real folder expansions | median 0.30 ms, p95 0.47 ms, max 1.27 ms |
| Existing `children(sort: .allocated)` on the 200k folder | 444 ms in SQL; overran the viewer's 0.25 s read deadline |

Every page of all three wide folders was checked:
- **completeness:** child counts matched exactly (200,000 / 177,152 / 50,000);
- **duplicates:** none;
- **order:** correct.

Equivalence: across 300 real folders, every explorer row matches the existing reader (id, path, status, sizes, reason) with 0 mismatches.

Two query-plan fixes were needed and are commented in code:
- `name >= ? AND (name > ? OR id > ?)` lets SQLite seek within a tier of equal sizes; the plain OR rescanned it (147 ms).
- `+n.generation_id` keeps SQLite on the size index for the unmeasured tier; otherwise it walked the folder (140 ms).

These figures are database reads. Table rendering time is not measured (see limitations).

## Memory

Navigation harness on the same copy: same state type and reader as the view, flattening rows after every change.

| Step | Cached rows | Process footprint |
|---|---|---|
| Start | 0 | 2.8 MB |
| 250 folders expanded and collapsed | 3,154 | 13.4 MB |
| 500 | 7,366 | 22.5 MB |
| 750 | 2,267 (eviction) | 26.0 MB |
| 1,000 | 4,906 | 26.2 MB |
| Then a 200k-entry folder scrolled to its limit | 9,906 | 35.5 MB peak |

**Bounds:**
- 12,000 cached entries overall. Collapsed folders' pages are evicted least recently used first; the root, expanded folders and the selection's ancestors are kept.
- 5,000 entries per folder. Beyond that, the folder shows "Showing the 5,000 largest of N items. Use Largest items to rank the rest."
- A cached entry costs about 2.3 KB. With the first trial budget (20,000 / 10,000), the same walk reached 50.6 MB.

## Data correctness

| State | How it is shown |
|---|---|
| Fully measured | Plain size, no note |
| Partial folder total | "Partial 1.94 GB" plus the note "Partial measurement" |
| Stale folder whose own listing is current | "≈ 330.67 GB" plus "Includes earlier sizes" |
| Previously measured | "Previously 16.52 GB" plus "Previously measured" |
| Protected or unreadable | Dimmed name, "—" in Allocated, no logical size or item count, note "Access restricted"; no chevron unless the inventory holds children for it |
| Deferred (kept changing) | Note "Kept changing · earlier size" |
| Empty folder | No chevron; if reached, an "Empty folder" row |
| Deleted entry | Removed on the next reload; expanding a vanished folder shows a retryable failure row |
| Unattributed space | Stated once, in the existing Disk Inventory header line with Details (for example "indexed sizes exceed the Data volume by 72.24 GB"). An explorer copy of it was rendered, judged redundant, and removed. |

## UI behavior

**Mouse:**
- click the chevron to expand or collapse;
- double-click a folder to toggle it;
- right-click for Show Contents, Reveal in Finder and Copy Path.

**Keyboard:**
- ↑ and ↓ move (native table);
- → expands a folder or moves into its first child;
- ← collapses a folder or moves to its parent;
- Return shows the folder's contents (drill in);
- ⌘C copies the path.

**Navigation:**
- breadcrumbs above the explorer are the existing ones;
- going back to a parent re-selects the folder you came from and reuses its loaded page;
- selection persists across reloads;
- collapsing a folder moves a selection inside it to that folder.

**Scrolling:** reaching the "Show more" row loads the next 200 entries.

**Design:**
- system type icons and thin separators;
- a compact 22-point row height;
- monospaced, right-aligned sizes;
- one subtle accent bar per row;
- no cards, badges or extra containers.

**Visual verification:**
- Rendered offscreen only (`evidence/explorer-tree-offscreen.png`, `evidence/explorer-page-offscreen.png`) from a process that cannot activate and never orders windows on screen.
- **NOT VERIFIED in a real window:**
  - chevron animation;
  - keyboard focus behavior;
  - double-click;
  - the onAppear-driven "Show more";
  - Reveal in Finder (which brings Finder forward by design when you click it).

## Tests

| Suite | Result |
|---|---|
| Inventory | **285/285** (19 new explorer assertions in `tests/InventoryExplorerTests.swift`) |
| Viewer model | **380/380** (23 new explorer state assertions) |
| Monitor self-test | 233/233 |
| Builds | Monitor and viewer, no errors or warnings |

**New inventory assertions** (real fixture plus real worker runs):
- largest-first order;
- a protected folder;
- an empty folder;
- 1,234 entries with repeating sizes paged in 7 pages of at most 200, every entry exactly once and correctly ordered;
- identical to the existing reader;
- under 100 ms per page;
- no duplicate or missing rows while the worker commits 40 new entries between pages;
- nested paths;
- deferred wording;
- a deleted folder;
- the same staleness as the existing reader during a pending refresh.

**New state assertions:**
- loading rows;
- expand, collapse and cached re-expand;
- every keyboard rule;
- the "more" row;
- overlapping pages without duplicates;
- selection across reload;
- deletion;
- the per-folder limit;
- the memory budget after 8,000 visited entries;
- back-navigation selection;
- failure and empty rows.

## Remaining limitations

1. **On-screen behavior is unverified** (see UI behavior).
2. **Long tail:** a folder shows only its largest 5,000 entries; the rest are reachable through the Largest items rankings and search.
3. **Reload is coarse:** after inventory changes, expanded folders reload their loaded span every 5 s at most, so an entry that grows can reorder under the pointer. Selection is kept by id.
4. **Header line:** the header's "Startup Data" title, the breadcrumbs and the explorer are separate rows; the page header was not redesigned in this pass.
5. **Clones:** entries are counted per file, so totals can exceed the volume; this is stated in the header.
6. **Readiness signal:** the QA "page data ready" readiness signal is driven by the flat page, which Explorer mode does not fetch. QA automation that waits for it should select Contents mode.

## Next milestone: the visual storage map

A squarified treemap of the current folder beside, or toggled with, the outline, built on `explorerChildren`.

**Data:**
- render the largest children of the current folder (the first page or two);
- lay out one level deep, with each child's own largest children as nested tiles only when the tile is large enough.

**Shared model:**
- selecting a tile selects the same row in the outline (same `InventoryExplorerState`);
- double-click drills in through the same `navigate`.

**Honesty:**
- partial, stale and protected tiles use the same notes (hatched or dimmed, never colored as measured);
- the unmeasured remainder of a partial folder is drawn as an explicit "not yet measured" region, never scaled into its siblings.

**Acceptance:**
- the map of any folder in the 3.45M-node catalog draws from at most two page reads (under 5 ms of SQL);
- layout and draw stay within a frame budget for 400 tiles;
- memory is shared with the outline's cache.
