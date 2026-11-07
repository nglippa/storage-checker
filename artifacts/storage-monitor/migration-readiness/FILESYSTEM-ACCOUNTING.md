# Migration Readiness — filesystem accounting

What the two sizes mean on APFS, what the detector can and cannot conclude from them, and how the feature keeps Storage Monitor's storage-accounting contract.

## The two measurements

- **Logical size** (`st_size`) is the file's length: the number of bytes a reader sees, including any unwritten ranges (holes), which read as zeros.
- **Allocated size** (`st_blocks × 512`) is what the filesystem reports as reserved for the file.

A **sparse file** has holes: ranges that were never written and occupy no blocks. Raw VM and container disk images (Docker Desktop's `Docker.raw`, OrbStack's `data.img`, Lima's `diffdisk`, raw `.img` files) are typically created at their full capacity and allocate blocks only as the guest writes.

## Not memory

Sparse allocation is a property of files on disk. It has nothing to do with RAM, virtual address space, memory pressure or swap. A 460 GB logical disk image does not reserve 460 GB of memory, and the feature never reads or reports memory statistics.

## What the apparent gap is not

The apparent gap (`logical − allocated`) is:

- **not consumed space**: the blocks do not exist;
- **not recoverable space**: deleting or compacting nothing can return space that was never allocated;
- **not a destination requirement by itself**: a copy that preserves holes needs about the allocated size; a copy that writes every byte needs about the logical size. Which one happens depends on the tool, the destination filesystem and the transfer path, and Storage Monitor does not know or predict it.

The feature adds no number to any storage total. The Storage overview, the Atlas, the Structured Explorer and the Inspector's "Indexed size" keep showing allocated sizes, as before. Migration Readiness shows logical and allocated side by side only in its own section.

## Why allocated size is itself imperfect on APFS

| Effect | What happens to `st_blocks` | Consequence for detection |
|---|---|---|
| **Clones** (`clonefile`, Finder duplicate on APFS) | Each clone reports its own full allocation, though the extents are shared until modified. | Two clones of a sparse image are two items with the same allocation. Their allocations must not be added together. Fixture-tested (`clone.img`). |
| **Shared extents after partial modification** | Each file still reports its own allocation. | Same as clones: allocation overstates physical use; it never creates a false gap. |
| **Snapshots** (Time Machine local snapshots, APFS snapshots) | Not reflected in the live file's `st_blocks`. A deleted or rewritten image's old blocks can stay in a snapshot. | Invisible to the detector, and one reason the gap is not "recoverable". |
| **Transparent compression** (`UF_COMPRESSED`, decmpfs) | Allocated can be far smaller than logical without any hole. | The live check excludes compressed files and counts them. Files in protected locations cannot be checked (see below). |
| **Cloud placeholders** (`SF_DATALESS`; iCloud Drive, File Provider) | Allocated is about zero while logical is the full size. | Items in `~/Library/Mobile Documents` and `~/Library/CloudStorage` are skipped and counted; any dataless file found elsewhere by the live check is dropped and counted. The worker records such *files* as measured, so this guard matters. |
| **Hard links** | Every link reports the same allocation. | The catalog counts each object once (aliases carry zero totals); the detector also deduplicates by device and inode. Fixture-tested. |
| **Preallocation** | Allocated can exceed logical. | The gap is clamped at zero. |
| **Purgeable space, APFS metadata, other volumes in the container** | Not attributed to files. | Outside the scope of a per-file measurement. |
| **Small extended files on APFS** | Observed on this Mac (macOS 27): a file of 16 MiB or less extended with `ftruncate` was fully allocated; 32 MiB and larger stayed sparse. | An observation, not a guarantee. It affects fixtures (the 8 MiB band fixture is fully allocated) more than real images. |

## Sparse bundles

A `.sparsebundle` folder stores its data in band files (usually 8 MiB each) plus `Info.plist` and `token`. Its **capacity** (`Info.plist` `size`) is a ceiling, not stored data. The detector reports the bundle once, with:

- **Band data (logical)** and **Allocated on disk** from the catalog totals of the folder's contents (what a copy transfers);
- **Bundle capacity** from `Info.plist`, when it can be read without a permission prompt, otherwise "Unknown".

Band lengths are never summed into a "capacity". Band files are never listed individually.

## Measurement sources and freshness

- Catalog values come from the inventory worker's `lstat` at its last listing of the folder. The worker relists folders on file events, so values can lag briefly.
- The live check (`lstat`) replaces catalog values when the file's identity matches. Its time is shown ("Checked on disk").
- In protected locations the catalog values are shown unchanged, labelled "Not checked on disk: this location is protected by macOS, and checking it could show a permission prompt."
- `statfs` of the inventory root gives the filesystem type shown in the Inspector ("APFS"). No other filesystem call is made.

## Storage-accounting contract (unchanged)

- No catalog write: the detector's connections are `SQLITE_OPEN_READONLY` with `PRAGMA query_only=ON`. Fixture test: catalog bytes are identical before and after a full detection pass, and the root's totals are unchanged.
- No change to the worker, its schema, its indexes, or how it measures.
- No change to the Storage accounting summary or "Disk details".
- The Structured Explorer keeps sizing nodes by allocated size; Migration Review only changes emphasis (fixture-tested: node radii are identical with the filter on).
- Cleanup rules and the Cleanup Inspector are unchanged. Detected items are not routed into cleanup recommendations, and Migration Readiness adds no delete, Trash, compact, prune, mount or exclude action.
