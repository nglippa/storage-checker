# Migration Readiness — guidance and wording

Source of truth: `SourcesShared/SparseStorageGuidance.swift`. Model tests check that no sentence predicts failure, promises recovered space, or recommends deleting, pruning, compacting or excluding anything.

## Background

The feature was motivated by a Mac mini → Mac Studio migration with Docker-related storage, repeated Migration Assistant failures and unexpectedly large temporary migration data. That experience is a motivation, **not** evidence of a general Migration Assistant defect. Storage Monitor does not know how Migration Assistant sizes or copies sparse files, and does not claim to.

## Principles

1. State the measurement: logical size, allocated size, apparent gap, ratio.
2. Phrase consequences as possibilities ("may require", "may not preserve").
3. Separate a detected storage condition from a confirmed incompatibility, every time.
4. Never recommend deleting, pruning, compacting, moving or excluding application storage.
5. Point to the application's own tools and documented procedures.
6. Never suggest the gap is reclaimable or in use.

## Text by severity (explanation paragraph)

- **REVIEW**, under the headline "Potential migration compatibility issue": "Although this disk image reports 460 GB of logical size, about 45 GB is currently allocated on disk. Some transfer methods may require more destination space than the current allocation suggests, or may not preserve sparse allocation." (The numbers are always the item's measured values. 460/45 here is illustrative only.)
- **INFORMATIONAL**: "This … reports X of logical size; about Y is allocated on disk. Sparse allocation was detected; no specific compatibility concern is established."
- **UNKNOWN**: "The inventory recorded X of logical size and Y allocated for this …, but it could not be checked on disk now. Treat these values as unconfirmed."

The noun follows the category: "disk image" (disk images, container storage), "virtual disk", "file", or "sparse bundle's band files".

## Considerations by category ("Learn More" and the Inspector's "Migration considerations")

### Docker Desktop, OrbStack and other container runtimes

- Container images, volumes and databases can all live inside this one disk image.
- Its logical size is the most it currently reports; its allocated size is what is stored now. Both describe the same file.
- Before migrating, review the storage that *the application* manages, using its own settings or commands.
- Back up or export data you need, such as volumes and databases, with *the application*'s own tools.
- Do not delete or move this file by hand while *the application* uses it.

### Virtual machines (Parallels Desktop, VMware Fusion, UTM, VirtualBox, Tart, unowned virtual disks)

- Virtual disks are often sparse: they report a large size while storing only what the virtual machine has written.
- A virtual disk can contain an entire operating system, its applications and documents.
- Use *the application*'s documented procedure to move or export virtual machines.

### Disk images, sparse files and unknown items

- Copy tools differ: some preserve sparse allocation, others write every logical byte to the destination.
- If you are unsure how a tool copies, make sure the destination has room for the logical size.
- (When an owner was inferred) This file is in *the application*'s storage; manage it with *the application*.

### Sparse bundles (in addition)

- A sparse bundle's capacity is a limit, not stored data; copying it transfers its band files.

### Always shown

- These are filesystem measurements, not a confirmed migration incompatibility.
- Storage Monitor cannot predict whether Migration Assistant or another tool will succeed, and does not exclude anything from backups or migrations.
- The apparent gap is neither space in use nor space that can be recovered.

## Data safety (Inspector, always visible for a detected item)

- Container and VM storage: "Deleting a container or virtual machine disk image can destroy application data, databases or entire virtual machines. Storage Monitor offers no delete action for these items; manage them in their application."
- Disk images: "A disk image can hold a whole volume of files. Storage Monitor offers no delete action here; open it with the application that created it to review its contents."
- Other files: "This file may belong to an application. Storage Monitor offers no delete action here; keep it unless you know what it holds."

Migration Readiness adds no delete or cleanup action, and detected items are not added to cleanup recommendations. The existing Cleanup Inspector section is unchanged. Its separate, validated "Move to Trash…" flow (collapsed by default, confirmation required) is outside this milestone and was not modified.

## What the app never does

No deletion, truncation, disk-image compaction, Docker pruning, VM modification, filesystem repair, automatic cleanup, snapshot deletion, disk-image mounting, Docker or VM launch, privilege elevation, network upload, backup or migration exclusion.

---

# Phase 2: Destination Capacity Assessment (design only; not implemented)

## Goal

Before a migration, give a **range** of destination space that the selected content might need, under explicitly stated copy assumptions. It would not be a prediction of Migration Assistant's behavior.

## Inputs

| Input | Source |
|---|---|
| Destination Mac total capacity | Entered by the user (or read from a mounted destination volume's `statfs`, read-only, only when the user picks it) |
| Destination available space | Same |
| Selected migration content | User choice of top-level groups (Users, Applications, other files), mapped to inventory subtrees |
| Detected sparse-storage items | Current Migration Readiness report |
| Coverage | Current report's coverage notes |

## Model

For the selected subtrees, using catalog totals (allocated) and the report:

- **Lower bound (holes preserved)**: Σ allocated of selected content. Shared clone extents are counted once per file, so this can still overstate the physical need.
- **Upper bound (holes written)**: lower bound + Σ apparent gap of detected sparse items in the selection.
- **Unknown additions**: listed, not estimated. Unchecked items, protected or unindexed folders, iCloud items that may be downloaded, snapshots, and temporary space a tool may use during transfer.

## Presentation (illustrative numbers)

> Selected content: about 612 GB if sparse files keep their holes, up to 1.03 TB if every logical byte is written. The destination has 900 GB available.
> The upper figure assumes a copy that writes sparse files in full. Storage Monitor does not know which method Migration Assistant or another tool will use, and does not reproduce Apple's capacity calculation.

Three states only: *fits under both assumptions*, *fits only if holes are preserved*, *does not fit under either*. Each is worded as an estimate with its assumptions, never as "Migration will succeed" or "will fail".

## Explicit non-goals

- No migration executor; no control of, or automation of, Migration Assistant.
- No claim to reproduce Apple's proprietary capacity calculations.
- No automatic exclusion of items from a migration or backup.
- No writes to either Mac.

## Open questions before implementation

- How Migration Assistant handles sparse files across transfer methods (network, Thunderbolt, Time Machine source). This needs documented evidence before any wording beyond "may".
- Whether to read destination capacity only from user input, to avoid any access to external volumes.
- Native QA with a real second Mac.
