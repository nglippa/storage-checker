# Storage accounting audit

2026-10-24, Mac mini (M4 Pro). Working tree on `master`, uncommitted, not built into a DMG. **The MacBook Air discrepancy is not claimed resolved**: the updated build has not been run on the Air, and the Air's database was not available here.

## Summary

The inventory's arithmetic is correct. On 2.9 M real nodes, every folder total equals the sum of its children, and the root equals the sum of every indexed file's allocation exactly. No indexed data is dropped.

The gap between macOS "used" and the inventory comes from comparing different things:

1. **Volume boundary.** macOS "used" is the whole APFS container: System, Preboot, VM (swap), Recovery, Update and Data. The inventory indexes only the Data volume. On this Mac, 46.6 GB of the 472.9 GB used is outside the Data volume.
2. **Folders not opened.** Without Full Disk Access, 194 privacy-protected folders, including Desktop, Documents, Downloads, Pictures, Music, Movies, other apps' Containers and Application Support, and Mail, are deliberately not opened. Another 109 are denied by permissions. Their contents are counted as 0, and the root is marked `partial`.
3. **Per-file sizes are not physical, unique usage.** APFS clones share blocks but `st_blocks` reports them in full for each file, which overcounts. Compression is already reflected in `st_blocks`. Snapshots, metadata and space held by files deleted while still open belong to no file. Measured on this Mac, the inventory **over**-attributes by 52.2 GB despite the protected folders, because of clones.

Which of these dominates depends on the machine. The new accounting summary shows the actual figures instead of forcing them to match.

## 1. How totals are calculated (verified against the source)

- **File (regular, symlink, other).** `total_logical = st_size` and `total_allocated = st_blocks × 512` of the inode, both from one `fstatat`. They are recorded only on the node that owns the inode (`inventory_objects.owner_node_id`). Every other name for the same `(device, inode, birth time)` gets 0, so **hard links count once** (`syncInventoryObjectAccounting`).
- **Directory.** `recomputeInventoryNode` sets the following:
  - `direct_* = Σ` of its non-directory children's totals;
  - `total_* = direct + Σ` of its directory children's totals (`COALESCE(…, 0)`).
  - The directory object's own blocks are not added. APFS reports `st_blocks = 0` for directories, even one with 20,000 entries (measured), so nothing is lost.
- **Status.** A directory is:
  - `complete` when every child is complete;
  - `partial` when any descendant is unknown;
  - `stale` while reconciliation, cleanup or a refresh is pending;
  - `pending` while its own listing is unfinished.
- **Unknown, protected or excluded folders.** These get `total = NULL` and contribute 0, and they propagate `partial` to every ancestor (a lower bound). Entries whose metadata is refused are `unknown` with no size (1.0.2).
- **Deferred folders.** They keep the entries committed from earlier batches, and their previous totals stay visible as stale.
- **Root.** `/System/Volumes/Data` is the Data volume only. Recomputation is triggered after every committed listing, deepest first, once per commit (1.0.2).
- **Sparse files.** The logical size is the full length; allocation is only the written blocks.
- **Compressed files.** Allocation is compressed, as `st_blocks` reports it.
- **Clones.** Counted in full per file.

## 2. Verification of the aggregation

| Check | Result |
|---|---|
| A clone of the 2,896,776-node QA catalog (full Data volume, no Full Disk Access): each of 430,966 complete, 129 partial and 10 stale directories against the sum of its children | **0 mismatches** |
| Same catalog: root total against the sum of all 2.47 M non-directory nodes | equal, 478,534,864,896 bytes |
| Fixture against an independent `lstat` walk of unique readable files | root allocated and logical equal (2,826,240 and 102,800,001 bytes) |
| Fixture stopped mid-pass (batch 2, 5 entries) | root equals the sum of indexed files; 0 folder mismatches |
| Hard link (two names) | counted once |
| Protected folder (`chmod 000`, 3 MB inside) | contributes 0; folder `unknown`, root `partial` |
| Sparse file (100 MB logical) | logical 100,000,001; allocated 12,288 |
| APFS clone | full allocation on both files (documented overcount) |

**No accounting bug was found in the aggregation.** The data-loss bugs found earlier (D1, a whole folder dropped because one entry was unreadable) were fixed in 1.0.2 and are covered by its tests.

## 3. Reconciliation on this Mac (measured)

Capacity is from the monitor's reading at 2026-10-24 19:00 UTC (`diskutil apfs list`). The inventory figures come from the QA catalog, a full Data-volume inventory taken without Full Disk Access and last updated 2026-10-23 19:57 UTC, so it is about a day older than the reading.

| | GB (decimal) |
|---|---|
| Container used (capacity 494.38, free 21.44) | 472.94 |
| — Data volume (what the inventory indexes) | 426.29 |
| — Preboot | 21.66 |
| — System (sealed, read-only) | 14.10 |
| — VM (swap) | 6.44 |
| — Recovery | 3.09 |
| — Update | 1.20 |
| — container metadata (used minus the sum of volumes) | 0.16 |
| Inventory: indexed file allocation | 478.53 |
| Indexed minus Data volume | **+52.24** (over-attribution) |

**Clone sharing, measured with APFS private size (`ATTR_CMNEXT_PRIVATESIZE`, clone-aware):**

| Tree | Files | Shared bytes counted again per clone |
|---|---|---|
| `/Applications` | 248,945 | 1.52 of 29.18 GB |
| `/Library` | 76,591 | 1.12 of 1.73 GB (65%) |

Developer caches, simulators, Photos and duplicated app data clone heavily, which explains an overcount of this size. It is not itemised further here.

**Coverage limits in that catalog:**

- 194 privacy-protected folders: 99 consent-gated, 88 privacy, 7 metadata:privacy;
- 109 permission-denied folders;
- 2 excluded locations (an autofs mount, and Storage Monitor's own data folder).

## 4. The MacBook Air

macOS reports 245.7 GB total, 14.76 GB available and 230.9 GB used. The Air's per-volume figures and catalog were not available here, so its split cannot be computed. Every component above applies:

- **Other volumes.** Typically System about 11 GB, plus Preboot, VM swap (larger on an 8 GB Mac under memory pressure) and Recovery. Together they are likely 20–40 GB of "used" that the inventory never sees.
- **Protected folders without Full Disk Access.** The Air reported hundreds of partially measured or inaccessible areas. Folders such as Pictures (a Photos library), Documents, Downloads, Desktop, Movies, Music, `~/Library/Containers`, Group Containers, Mobile Documents and Application Support are commonly the largest user data on a laptop, and none are opened without Full Disk Access.
- **Storage Monitor's own data.** About 1 GB of database plus any `history.pre-update-*` snapshot is excluded from the index by design.
- **Snapshots, metadata, and files deleted but still open.** None of these belong to any file.
- **Clones.** These work in the opposite direction, raising indexed totals.

Run the updated build on the Air and open **Disk Inventory → Details** to get the actual split.

## 5. Changes made

| Area | Change |
|---|---|
| Accounting summary | `StorageAccountingPresentation` (shared, pure) and `InventoryReader.accounting()`. Disk Inventory shows one line, for example "230.9 GB used · 120.3 GB in indexed files · 87.2 GB of the Data volume not attributed", with a **Details** popover. The popover lists used on disk (with free and capacity), macOS and other volumes by name, the Data volume, space in indexed files, and space not attributed (or "Indexed sizes exceed the Data volume by …"). It also explains which causes apply: protected, unavailable and unreadable counts, excluded locations, Storage Monitor's own data size, and snapshots, metadata, clones and compression. It never says "System Data", says the difference is "Not necessarily reclaimable", and never forces the numbers to agree. |
| Units and boundaries | Bytes throughout, shown in decimal units like macOS. The comparison is Data volume to inventory root, both the Data volume. Other volumes are listed separately. |
| Full Disk Access state | The worker records its own probe result (`state` key `inventory_full_disk_access`), because only the helper process's access matters. The viewer reads it and does not probe on the helper's behalf. |
| Guidance | Guidance appears in the popover when protected folders exist without access, with an **Open Full Disk Access Settings…** button that the person clicks. It names `~/Applications/MacBook Storage Monitor.app` and says the viewer does not need access. Nothing changes privacy settings automatically. |
| Tests | Inventory: 7 accounting tests (partial tree, oracle equality, hard link, protected folder, sparse file, clone, reader summary). Viewer: 5 accounting presentation tests. |

## 6. Permission coverage (Phase 3)

- **Which process needs Full Disk Access.** Only the background helper `~/Applications/MacBook Storage Monitor.app` (`Contents/MacOS/StorageMonitor`, launched by launchd as `local.macbook.storage-monitor.inventory`). It does the listing. The viewer in `/Applications` reads only Storage Monitor's database and needs no access.
- **How access is detected.** The worker tries `opendir` on `~/Library/Mail`, `~/Library/Safari` and `/Library/Application Support/com.apple.TCC`. EPERM means not granted.
- **Without access.**
  - **Consent gate:** consent-gated locations are deliberately never opened. Opening them can trigger macOS consent prompts or App Data notifications that would block a background process.
  - **Unopened folders:** they are recorded as protected, with no size.
  - **Everything else:** monitoring and indexing work normally.
- **Ad-hoc signing (expected, not verified here).** TCC identifies ad-hoc-signed code by its exact code hash, and each update changes that hash. After an update, an existing Full Disk Access entry may therefore show as on but not apply. The guidance tells people to remove the entry and add it again if protected folders remain. A Developer ID signature would avoid this.
- **The app works without Full Disk Access.** The accounting summary simply shows more of the Data volume as not attributed, and explains why.

## 7. Remaining unexplained discrepancy and limits

- **The Air's split is not measured.** Its exact decomposition needs the updated build run on the Air.
- **Snapshots and metadata are not sized.** There is no public per-snapshot size, and metadata is not reported per file. Both remain inside "not attributed", described rather than quantified.
- **Clones are not de-duplicated.** Indexed totals use `st_blocks`. A clone-aware figure (APFS private size, as measured above) would need a schema field and a decision about how shared blocks should be attributed. Not done in this pass.
- **The QA catalog is about a day older than the capacity reading** used in §3.
- **The popover is not verified on screen.** Rendering wasn't checked: no GUI may be shown on this Mac.

## 8. Tests run

| Suite | Result |
|---|---|
| `scripts/test-inventory.sh` | 262 / 262 |
| `StorageMonitor self-test` | 231 / 231 |
| `scripts/test-gui.sh` | 349 / 349 |
| `build-gui.sh` (26.5 SDK) | OK, no warnings or errors |

Production databases and LaunchAgents were not modified. The helper in `~/Applications` is unchanged, and the QA database hash is unchanged (`74a10da4…`). The `/Applications/Storage Monitor.app` viewer was found already replaced by the 1.0.2 build at 14:22 CDT today (executable `c2cf078c…`, identical to the 1.0.2 DMG). This session did not install it. Nothing was committed or pushed.
