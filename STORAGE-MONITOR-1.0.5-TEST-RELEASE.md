# Storage Monitor 1.0.5 (build 6) — Explorer and storage map test release

Date: 2026-10-25. Built and verified on the Mac mini. **Not installed. Not committed.** No GUI automation was used; nothing here has been verified in a real window.

Evidence: `build/release-1.0.5/` (DMG log, test logs, checksums, migration check).

## Artifact

| | |
|---|---|
| DMG | `build/dist/Storage-Monitor-1.0.5.dmg` |
| SHA-256 | `7a3b4f3cc2ef96a3808a6df2d6fcfaa11449ca2b56d4b3efa7177863265900f9` |
| Viewer `StorageMonitorViewer` | `4125243ad443f1d88bd4ca8074781da0e5e3f4d13d3f13067b6aea3900bf28c1` |
| Helper `StorageMonitor` | `9b591b81a8e2e757d03582ae50b9f759ff57da032ac2f4775f61a3a49ea5b313` |
| Versions (read from the mounted image) | App 1.0.5 (6), helper 1.0.5 (6) |
| Architectures | Both executables: arm64 and x86_64; deployment target macOS 14.0 |
| Signature | Ad hoc; `codesign --verify --deep --strict` passes; Gatekeeper rejects it, as expected for ad hoc |
| Image | `hdiutil verify` VALID; `verify-dmg.sh` passed, including the monitor's 233 tests run from the image |
| 1.0.4 identity | Untouched: `Storage-Monitor-1.0.4.dmg` still `56d4e17a…caf2` |

Data preservation, checked with the DMG's own helper running `status` and `inventory-status`:

| Copy | Contents before and after | `quick_check` |
|---|---|---|
| Fresh read-only `VACUUM INTO` snapshot of this Mac's live database | 175 readings, 61 alerts, 10 diagnostics, 175 evidence rows, 12 state rows, 3,006,082 inventory nodes, first pass complete | ok |
| Pre-1.0.3 backup | 155 readings, 48 alerts, 8 diagnostics, 155 evidence rows, 10 state rows | ok |

## Changes in this pass

**Verification of milestones 1 and 2** (`INVENTORY-EXPLORER.md`, `INVENTORY-STORAGE-MAP.md`) by code review and tests:
- one shared controller for outline and map;
- expansion and navigation;
- the memory bounds;
- exact map accounting;
- coverage states;
- index updates;
- unchanged search and rankings, both reader tests and mode logic: the Explorer is bypassed whenever the search field has text, and navigating from a ranking still switches to Contents.

**Consistent reads (Phase 2) — implemented.**
- **New call:** `InventoryReader.explorerSpan(parentID:count:)` reads a folder's loaded span and its exact remainder inside one SQLite read transaction.
- **How the map uses it:** whenever its folder has children beyond the loaded pages, it replaces both from that one snapshot.
- **Test:** a writer thread moves bytes between two children in single transactions (9,820 commits), so the true total never changes.
  - **Span reads:** 0 of 21 inconsistent.
  - **Two separate reads (the previous approach):** 5 of 14 inconsistent, recorded for comparison.

**Interaction defects fixed (Phase 3):**

| Defect | Fix |
|---|---|
| Opening a protected, unreadable or not-yet-listed folder showed "Empty folder" in the outline and the map | Now "Contents not available · Access restricted" (or the folder's coverage wording); "Empty folder" only for a fully listed, empty folder. Test added. |
| A drilled "Other items" window could point past the end of a folder that shrank after an index update | Falls back to the folder's first window |
| While the next page loads, a drilled window showed "Nothing here has a measured size yet" | Shows "Loading…" |
| The map's hover could keep describing a tile from the previous folder or window | Cleared on folder or window change |

**Reviewed, no change needed:**
- keyboard focus (arrow keys handled on the outline);
- small tiles (at least about 13 × 13 pt, with tooltip and status-line detail);
- map resizing (layout recomputed from the current size);
- breadcrumbs (the existing ones; they re-select the folder you came from).

## Tests and benchmarks

| Suite | Result |
|---|---|
| Inventory | **289/289** |
| Viewer model | **393/393** |
| Monitor self-test | 233/233 (from the build, and from the mounted DMG) |
| Builds | Monitor, viewer and DMG: no errors or warnings |

Benchmarks on an isolated copy of this Mac's catalog (3.45M nodes; details in `INVENTORY-STORAGE-MAP.md`):

| Read | Time |
|---|---|
| Map navigation, first page | median 0.31 ms |
| Exact remainder | median 0.23 ms; 10 ms for 199,800 entries |
| Layout | at most 0.05 ms |
| Accounting | exact in 1,000 of 1,000 folders |
| Memory after 1,000 navigations | 25 MB |
| Span read, typical folder | 0.5 ms |
| Span read, 200k-entry folder, 200 entries | 10 ms |
| Span read, 200k-entry folder, full 5,000-entry span | median 28 ms, worst 138 ms; inside the reader's 0.25 s deadline, runs in the background |

## Known limitations

1. **No real-window verification yet:** everything below is for your manual check.
2. **Selection scrolling:** selecting a file on the map selects its outline row but does not scroll the outline to it. The path appears in the selection bar.
3. **Single snapshot is map-only:** it covers the map's folder (tiles plus Other items). Outline pages loaded at different times can still come from different moments until the next reload (at most every 5 s while indexing).
4. **One-level map:** the map is one level deep; drill-down stops at 5,000 entries per folder (Largest items covers the rest).
5. **Labels on small tiles:** labels appear only on tiles of at least 72 × 34 pt; smaller tiles rely on hover and tooltips.
6. **Gatekeeper:** the build is ad hoc signed, so macOS asks for approval on first open (below).

## Installation (manual)

1. Quit Storage Monitor.
2. Open `build/dist/Storage-Monitor-1.0.5.dmg`. Optionally, first confirm its checksum: `shasum -a 256 build/dist/Storage-Monitor-1.0.5.dmg` should print `7a3b4f3c…5900f9`.
3. Drag **Storage Monitor** from the DMG onto Applications, replacing the existing copy.
4. Eject the DMG and open Storage Monitor from Applications.
   - If macOS says it cannot verify the app, go to **System Settings → Privacy & Security → Open Anyway**, then confirm.
   - Do not disable Gatekeeper globally.
5. Open **Settings**. If it reports the background monitor's version differs, choose **Update Background Monitor…**. History, preferences and the inventory catalog are kept, and no full re-scan is started.
6. Check **About** or Settings shows 1.0.5 (6).

Rollback: drag the 1.0.4 (or 1.0.3) app back from its DMG, then **Update Background Monitor…** again. The catalog schema is unchanged since 1.0.3.

## Manual verification checklist

Open **Disk Inventory**.

**Explorer navigation**
- [ ] Opens in **Explorer**, with the map above the outline.
- [ ] Chevron expands and collapses; a "Loading…" row may flash.
- [ ] Return or double-click opens a folder; breadcrumbs extend; mode stays Explorer.
- [ ] Clicking a breadcrumb goes up and selects the folder you came from.

**Map navigation**
- [ ] Tiles look proportional to the outline sizes; the largest is top left.
- [ ] Clicking a folder tile opens it.
- [ ] The status line explains anything not drawn.

**Map and Explorer sync**
- [ ] Clicking a file tile selects the same row in the outline; the path shows in the bottom bar.
- [ ] Selecting a row deep in the outline rings its ancestor tile on the map.

**Keyboard**
- [ ] ↑ and ↓ move through rows.
- [ ] → expands, then moves into the first child.
- [ ] ← collapses, then moves to the parent.
- [ ] Return opens a folder.
- [ ] ⌘C copies the selected path.

**Context menus**
- [ ] Right-clicking a row shows Show Contents (folders), Reveal in Finder and Copy Path.
- [ ] Copy Path pastes the correct path.
- [ ] Reveal in Finder selects the item in Finder (Finder comes forward because you clicked).

**Other items drill-down**
- [ ] In a folder with many entries, hovering Other items shows its count and size.
- [ ] Clicking it shows the next entries, with "Other items from #N" and Back.
- [ ] Back returns to the larger items.

**Map resizing**
- [ ] Dragging the divider between map and outline redraws tiles without overlap or gaps.
- [ ] Resizing the window does the same.
- [ ] The grid button in the bottom bar hides and shows the map, and the choice is remembered after reopening.

**Protected and stale states**
- [ ] A protected folder (for example `~/Library/Accounts`) shows "—" and "Access restricted", with no chevron.
- [ ] Opening it shows "Contents not available · Access restricted", not "Empty folder".
- [ ] "Previously …" and "≈ …" rows carry notes.
- [ ] Their tiles have dashed edges; partial folders are hatched.

**Search and rankings**
- [ ] Typing in the search field shows the results list; clearing it returns to the Explorer.
- [ ] Largest folders, Largest files and Largest items still rank; double-clicking a result opens its folder.

**Visual polish and readability**
- [ ] Tile labels are readable and not clipped.
- [ ] Sizes are aligned.
- [ ] The light and dark appearances both look right.
- [ ] Nothing feels slow when expanding, navigating or drilling.
- [ ] No overlap with the toolbar at the top of the window.
