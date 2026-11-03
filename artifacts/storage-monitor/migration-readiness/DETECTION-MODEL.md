# Migration Readiness — detection model

Status: implemented on branch `migration-readiness` (worktree `~/storage-checker-structured-explorer`), not committed, not released.
Code: `SourcesShared/SparseStorage.swift` (model, thresholds, classification, live probe), `SourcesShared/SparseStorageDetector.swift` (scan, cache, report), `SourcesShared/InventoryModels.swift` (catalog queries, `// MARK: Sparse storage`), `SourcesShared/SparseStorageGuidance.swift` (wording), `SourcesGUI/MigrationReadinessView.swift` (viewer).

## What is measured

For every candidate the detector uses two numbers the inventory worker already records with `lstat` (it never follows symbolic links):

| Value | Source | Meaning |
|---|---|---|
| Logical size | `st_size` | The length the file reports. For a raw disk image this is its advertised capacity. |
| Allocated size | `st_blocks × 512` (Darwin `st_blocks` is in 512-byte units) | Blocks the filesystem has reserved for the file. |
| Apparent gap | `max(0, logical − allocated)` | How much larger the file reports itself than what is stored. Never negative: a preallocated file (allocated > logical) has no gap. |
| Allocation ratio | `logical ÷ allocated` | `nil` (shown as "Nothing allocated") when allocated is 0; never a division by zero. |
| Identity | device, inode, birth time | Used to tell "same file, changed" from "a different file now at this path". |

The gap is **not** consumed space and **not** recoverable space. See FILESYSTEM-ACCOUNTING.md.

## Where candidates come from

No second filesystem crawl. The catalog (`inventory_nodes` / `inventory_objects`) already holds both sizes for every indexed file.

1. **Full pass** (first time, a new inventory generation, or a change journal that cannot be continued): primary-key range reads of `inventory_nodes`, 50,000 ids per slice, each a separate short read (the catalog uses a rollback journal, so a long read would hold back the worker's commits). Between slices the detector yields 2 ms. The SQL predicate selects files with `logical ≥ reporting gap`, `logical − allocated ≥ reporting gap`, `logical ≥ reporting ratio × allocated`, plus every folder named `*.sparsebundle`. Hard-link aliases carry zero totals in the catalog, so each object is considered once.
2. **Incremental pass**: the change journal (`InventoryReader.changes(since:)`) names the folders whose listing changed. Only those folders' children are re-read (parent index), plus items whose ancestors had a subtree change (paths may have moved) and sparse bundles (their totals follow their bands). If the journal cannot be continued (another journal, past retention, more than 8 × 4,096 changes), the pass falls back to a full scan.
3. **No change**: no candidate is read again; coverage (inventory status, accounting, known locations) is re-evaluated.

The journal position is taken before a full scan begins, so anything committed during the scan is replayed by the next pass.

A slice that meets a worker commit (`database is locked` after the reader's 100 ms busy timeout) is retried up to three times (100, 200, 300 ms) instead of abandoning the pass. A failed or interrupted hydration read, or a generation change between slices, abandons the pass and keeps the previous report.

The viewer starts a pass when the Storage section appears and when the inventory status changes, at most one every 30 seconds. While the inventory's first pass is unfinished (when the journal moves too fast to replay), passes are at least 5 minutes apart.

The detector owns its own `InventoryReader` actor instance. The browser's reader (folder navigation) never waits behind a scan.

## Live check

After the catalog, each candidate gets one `lstat` (never `stat`, never `open`) unless:

- it is in a **privacy-protected location** relative to the user's home: Desktop, Documents, Downloads, Pictures, Music, Movies, or anything in `~/Library` except `Caches`, `Developer` and `Logs` (the worker's own consent rule). Checking there could show a macOS permission prompt, so the item keeps its indexed values, marked "Not checked on disk". Docker Desktop's image (`~/Library/Containers/com.docker.docker/…`) falls in this group;
- it is in **iCloud Drive or File Provider storage** (`~/Library/Mobile Documents`, `~/Library/CloudStorage`): skipped entirely and counted, because a large file there may be a dataless placeholder;
- it is a **sparse bundle**: sizes are the catalog totals of its band files; the only content read is its `Info.plist` (≤ 64 KB, `O_NOFOLLOW`, never inside a protected location), for the bundle's capacity;
- the per-pass budget (2,000 live checks) is used up: indexed values are shown and the item is counted as not checked.

The live result decides the outcome:

| Live result | Outcome |
|---|---|
| Same identity, same sizes | Reported on its sizes; "Checked on disk; matches the index." |
| Same identity, sizes changed | Re-evaluated on the **live** sizes; "changed since it was indexed". |
| Different identity, a link, or a folder at the path | **UNKNOWN** if the indexed values meet REVIEW, otherwise INFORMATIONAL; "A different item is now at this path". Never followed. |
| `ENOENT` / `ENOTDIR` | Dropped, counted as vanished. |
| `EACCES` / `EPERM` | **UNKNOWN** with indexed values if they meet REVIEW, otherwise INFORMATIONAL (refusal shown). |
| `SF_DATALESS` flag | Dropped (cloud placeholder: data not on this Mac). |
| `UF_COMPRESSED` flag | Dropped (transparent compression, not sparse allocation). |

Successful checks are cached per node by (identity, indexed sizes, modification time); a catalog change to any of those forces a new check. Failed checks are not cached. The Inspector rechecks a selected item on disk unless it was checked within 15 seconds.

## Thresholds and severity

Configurable (`SparseStorageThresholds`; in the viewer also with `defaults write` keys `inventory.migrationReadiness.reviewMinimumLogicalGiB`, `…reviewMinimumGapGiB`, `…reviewMinimumRatio`, `…reportMinimumGapGiB`). Defaults:

| Level | Rule (all inclusive) |
|---|---|
| **REVIEW** | logical ≥ 10 GiB **and** gap ≥ 5 GiB **and** logical ≥ 4 × allocated |
| **INFORMATIONAL** | gap ≥ 1 GiB (optional ratio floor, default 1 : 1, i.e. none), but not REVIEW |
| **UNKNOWN** | met REVIEW in the catalog, but the live check was refused, or the item was replaced |
| not reported | below the reporting floor (on live values when checked) |

These are initial heuristics, not established migration-failure thresholds. Observations from the fixtures:

- With the defaults, the gap rule is implied by the other two (logical ≥ 10 GiB and ratio ≥ 4 give a gap ≥ 7.5 GiB). It stays as an independent knob for custom values; its boundary is tested with custom thresholds.
- A large gap at a low ratio (500 GiB logical, 450 GiB allocated) is INFORMATIONAL, not REVIEW. That is deliberate (the ratio criterion), and a possible under-statement if a 50 GiB difference matters on the destination; it is still listed.
- The reporting ratio floor was first 1.25 : 1. A test showed it would hide that 50 GiB gap entirely (ratio 1.11), so the default became 1 : 1: a 1 GiB gap is reported whatever the file's size.
- On APFS, a file of 16 MiB or less extended with `ftruncate` was fully allocated, while 32 MiB and larger stayed sparse (observed on this Mac, macOS 27; not a documented guarantee). Small sparse files therefore rarely reach the floor anyway.

There is no "Migration will fail" state. REVIEW is worded as "Potential migration compatibility issue".

## Categories and application identification

`SparseStorageClassifier` uses the path only; no file is opened, and nothing is parsed.

| Category | Evidence |
|---|---|
| Container storage | Inside a documented container-runtime folder: `com.docker.docker` / `group.com.docker` (Docker Desktop), `.orbstack` or `*.dev.orbstack` (OrbStack), `rancher-desktop`, `containers/podman/machine`, `.colima`, `.lima` |
| Virtual machine storage | Inside `*.pvm` (Parallels Desktop), `*.vmwarevm` (VMware Fusion), `*.utm` or `com.utmapp.UTM` (UTM), `VirtualBox VMs`, `.tart` (Tart); or a `.qcow2`, `.vmdk`, `.vdi`, `.vhd`, `.vhdx`, `.hdd`, `.hds` name |
| Disk image | `.raw`, `.img`, `.dmg`, `.sparseimage`, or a `.sparsebundle` folder |
| Sparse file | Verified sparse allocation, no format or owner evidence |
| Unknown | A file with no format evidence whose live check was refused or that was replaced |

Folder names are matched anywhere in the path, so no user's home is assumed. Only the item's ancestors are matched for files, so a file merely *named* `com.docker.docker` is not attributed. The UI always says "(from its name)" for formats and "(from its location)" for applications. An extension never proves a file is sparse: only the measured allocation does.

**Virtual capacity** is not parsed for any format and is shown as "Unknown (the format is not parsed)". For a raw image the logical size *is* its capacity; for QCOW2/VMDK/VDI the logical file size is what a copy transfers, which is what matters here. Sparse bundles show their `Info.plist` `size` as "Bundle capacity", separately from the band data.

## Sparse bundles

A `.sparsebundle` is a folder of band files. The bundle is one item: its sizes are the catalog totals of its contents (band data plus `Info.plist` and `token`), labelled "Band data (logical)". Its capacity comes from `Info.plist` and is never summed from bands. Band files are never listed or counted on their own. A 1 TiB-capacity bundle whose bands are fully allocated is not reported (fixture-tested).

## Report and coverage

`SparseStorageReport` lists at most 500 items: REVIEW first, then UNKNOWN, then INFORMATIONAL, largest gap first. Counts are exact. The Overview leads with the largest REVIEW item (else the largest UNKNOWN).

Coverage limits are stated, never hidden:

- the inventory has not started, or its first pass or queued listings are unfinished;
- protected and unreadable folder counts from the accounting;
- known application storage locations the inventory could not measure (Docker Desktop, OrbStack, UTM, Parallels Desktop, VMware Fusion, Lima, Colima, Tart), with "is installed" when `/Applications/<App>.app` is in the catalog. A protected parent is reported unless the application is known *not* to be installed;
- skipped cloud items, cloud placeholders, compressed files, unchecked items.

With nothing detected the text is exactly "No large sparse-storage discrepancies detected in scanned locations." and the Overview adds "coverage limited" whenever coverage is incomplete.

## Known false positives

- **Clones of a sparse file**: each clone reports its own allocation and is listed separately; shared extents are not deduplicated (fixture-tested).
- **Items in protected locations** cannot be checked live. A compressed file there would look sparse; this is unlikely for container and VM images, which are not compressed.
- **Files growing between indexing and the check** are re-evaluated on live values; a file growing *after* the check stays as reported until the next catalog change.
- **Raw images by naming**: a `.img` that is actually a UDIF `.dmg` is called a disk image; harmless, since only allocation decides reporting.

## Known false negatives

- **Unindexed or protected locations** (no Full Disk Access): Docker Desktop's and UTM's images live in `~/Library/Containers`, which the worker does not open without Full Disk Access. They are then absent from the report, and a coverage note says so when the location exists in the catalog as protected.
- **iCloud Drive / File Provider** items are skipped by design.
- **Large gap at a low ratio** (e.g. 300 GiB of 460 GiB allocated) is INFORMATIONAL, not REVIEW.
- **QCOW2/VMDK/VDI images that are not sparse files** (they grow by appending) have no gap and are not reported, even though their *virtual* capacity is larger. That is consistent with what a copy transfers.
- **Below 1 GiB gap** nothing is reported.
- **Other volumes**: the inventory covers the startup Data volume only.
- **Beyond 500 items** the list is truncated (counts stay exact).
