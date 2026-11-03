# Migration Readiness — regression results

Machine: this Mac, macOS 27 (Darwin 27.0.0), APFS. SDK for the viewer: `MacOSX26.5.sdk` (per AGENTS.md). All runs are headless; no app was launched or focused. Logs were kept in the session scratchpad (`final/` and `baseline/` folders).

## Suite results

**Baseline** = unmodified `master` `8ba2e00`, run on an APFS clone of the tree before any edit. **Final** = the worktree with every change, including the code-review fixes, in one uninterrupted run with no source edits during it. (An earlier run was discarded: one compile failed with "input file was modified during the build" because I edited a file mid-run. A complete run before the review fixes also passed every suite.)

| Suite (command) | Baseline | Final | New tests |
|---|---|---|---|
| Monitor build (`scripts/build.sh`) | exit 0 | exit 0 | — |
| Monitor self-test (`StorageMonitor self-test`) | exit 0, 235 passed | exit 0, **235 passed, 0 failed** | 0 |
| Inventory integration (`scripts/test-inventory.sh`) | exit 0, 350 passed | exit 0, **379 passed, 0 failed** | 29 (`sparse catalog: …`) |
| Viewer model (`scripts/test-gui.sh`) | **exit 133, crashed after 785 passes** (see below) | exit 0, **1,032 passed, 0 failed** | 70 (57 `sparse storage: …`, 13 `migration review: …`) |
| Structured filtering (`scripts/test-structured-filtering.sh`) | exit 0, 23 passed | exit 0, **36 passed, 0 failed** | 13 (`migration review: …`) |
| Viewer build (`scripts/build-gui.sh`, SDK 26.5) | exit 0 | exit 0 | — |
| Headless inventory browser (`scripts/test-inventory-model.sh`) | exit 0, 69 passed | exit 0, **85 passed, 0 failed** (rerun with the agreement test) | 16 (`migration readiness/review: …`, `agreement: …`) |

Skipped tests: none reported by any suite.

After that run, one source change was made: a comment in `SparseStorageDetector.swift` documenting the same-process SQLite invariant (no code change). The agreement test was also added. The headless browser suite, which compiles every shared and viewer source, was rerun: exit 0, 85 passed. The other suites were not rerun for the comment-only change.

**Pre-existing viewer-suite crash (baseline only):** on unmodified `master` the viewer model suite stopped with `Fatal error … TrashSafetyFixture … "Active-use observations are stale; review the item again."` A Trash preflight rejects process observations older than 5 s (`CleanupTrashSafety.swift:180`). On this heavily loaded machine (dozens of Codex app servers) the process scan sometimes exceeded that. It did not recur in the final run. It is timing-dependent and unrelated to this milestone: no cleanup or Trash code was changed. It is still worth tracking as a flaky test.

## Coverage of the required regression list

"Model" = pure tests with synthetic values (`tests/SparseStorageTests.swift`, in the viewer model suite). "APFS" = real files created under `/private/tmp` on APFS. "Catalog" = real files indexed by the real inventory worker, then detected (`tests/SparseStorageCatalogTests.swift`, inventory suite; thresholds scaled to MiB). "Browser" = headless `InventoryBrowserModel` with real APFS files at the **default GiB** thresholds (`tests/InventoryModelTests.swift`).

| # | Requirement | Tests | Kind |
|---|---|---|---|
| 1 | Sparse regular files | APFS probe (64 MiB logical, 16 KB allocated); catalog `data.img`, `hole.bin`; browser 12 GiB and 20 GiB images | APFS, Catalog, Browser |
| 2 | Fully allocated files | model 1 : 1; APFS `full.bin`; catalog `full.bin` not reported | Model, APFS, Catalog |
| 3 | Zero-byte files | model; catalog `zero.bin` not reported | Model, Catalog |
| 4 | Zero-allocation files | model (unbounded ratio, no division); catalog `hole.bin` (allocated 0) REVIEW | Model, Catalog |
| 5 | Large logical, tiny allocation | catalog `Docker.raw` 256 MiB / 64 KB; browser 35 GiB logical, 868 KB allocated | Catalog, Browser |
| 6 | Threshold boundaries | inclusive at 10 GiB and 4 : 1, one byte past each; gap boundary (custom); reporting floor; optional ratio floor; clamping | Model |
| 7 | Logical ≈ allocated | model 20 GiB vs 20 GiB − 4 KB; catalog `close.bin` | Model, Catalog |
| 8 | Symlinks | APFS probe reads the link itself; evaluator: a link at the path is UNKNOWN; catalog `link.raw` never reported or followed | Model, APFS, Catalog |
| 9 | Hard links | catalog: `hardlink.bin` + `hole.bin` → one item | Catalog |
| 10 | APFS clone limitation | catalog: `clone.img` reported separately with the same allocation (documented, not deduplicated) | Catalog |
| 11 | Sparse bundles | model plist parse; catalog: 1 TiB-capacity bundle with fully allocated bands not reported; sparse-band bundle reported with capacity from `Info.plist` separate from band data; bands never listed | Model, Catalog |
| 12 | Unsupported formats | model `.xyz` → sparse file, no format; catalog `data.unknownformat` | Model, Catalog |
| 13 | Missing / inaccessible files | model ENOENT/EACCES/EPERM; catalog `gone.raw` dropped and counted, `secret.raw` (folder chmod 000) UNKNOWN | Model, Catalog |
| 14 | Metadata changing during inspection | model changed sizes and replaced identity; catalog `grows.raw` re-evaluated on live values, `replaced.raw` UNKNOWN | Model, Catalog |
| 15 | Cancellation | catalog: a cancelled paced scan stops between reads, publishes nothing; the next pass completes | Catalog |
| 16 | Cache invalidation | catalog: after relisting, new item added, filled image removed, replaced file confirmed, unchanged items kept, with **no full rescan**; failed checks retried, successes cached | Catalog |
| 17 | Duplicate catalog entries | catalog: hard link counted once; identity de-duplication in the detector | Catalog |
| 18 | Inspector synchronization | browser: Reveal in Inspector opens the enclosing folder; the revealed item becomes the shared selection; the Inspector resolves its details; repeated selection within 15 s does no filesystem access; catalog: a recheck keeps report counts exact | Browser, Catalog |
| 19 | Accurate storage totals | catalog: catalog bytes identical before/after detection, root totals unchanged; browser: totals stay allocated (868 KB of 37.58 GB logical); filter: node sizes unchanged | Catalog, Browser, Model |
| 20 | Migration Review highlighting | 13 filter tests (off = no effect, drawn item vs nearest shown folder, outside view ignored, dim, hide, combined with size, no matches, isolation, path focus, sizes unchanged, selected ancestor on a path, item grouped at the centre); browser: real catalog tree highlights `Data` and `b` | Model, Browser |
| 21 | Incomplete scan coverage | model coverage notes; catalog: protected Docker Desktop folder reported as not inspected instead of "clear"; empty catalog says nothing was checked | Model, Catalog |
| 22 | No unexpected catalog rereads | catalog: a pass with no journal changes reads 0 slices, hydrates 0 candidates, retries only the 2 failed checks | Catalog |
| 23 | Navigation responsiveness | browser: 12 folder loads during a running scan p50 3.0 ms, max 3.3 ms (idle max 4.2 ms) | Browser |

Also covered: classification of Docker Desktop, OrbStack, Parallels, VMware Fusion, UTM, Lima, Colima, Podman, Tart and unowned formats, for two different user names; protected and cloud locations; `~` redaction; iCloud skip; compression and placeholder exclusion; guidance wording (no failure prediction, no delete, prune, compact or exclude advice; data-safety warning present); request coalescing in the controller.

## Three-view agreement on one APFS image (follow-up)

`tests/InventoryModelTests.swift`, "agreement": one image created by Apple's tools rather than this app's code. `/usr/sbin/mkfile -n 64g` makes a sparse 64 GiB file, then `/bin/dd if=/dev/urandom … bs=1m count=48 conv=notrunc` writes 48 MiB of real data. It sits in Docker Desktop's directory layout and is indexed by the real worker. Ground truth is `/usr/bin/stat -f '%z %b'`: 68.72 GB logical, 50.3 MB allocated. All 5 checks pass:

1. stat confirms a 64 GiB sparse file with 48–64 MiB allocated;
2. the **Overview** headline is this file, "Docker Desktop disk image", with exactly stat's logical, allocated and gap, confirmed on disk;
3. the **Inspector**, after Reveal in Inspector, selects the same node and path; its Migration readiness sizes equal the Overview's, and its "Indexed size" equals stat's allocated size;
4. the **Living Tree** draws the same node at the allocated size (label "50.3 MB"), on the same ancestry as the report, with the Migration Review ring on it;
5. the three show identical text (68.72 GB logical, 50.3 MB allocated).

This is fixture acceptance on real APFS metadata. It is not acceptance against a real Docker Desktop installation (see below).

## Real-world acceptance (kept separate)

On this Mac's real catalog the detector reports nothing: no item meets the 1 GiB floor, the worker lacks Full Disk Access so `~/Library/Containers` is not indexed, and no Docker Desktop, OrbStack, UTM or Parallels installation is present. Docker and VM identification has therefore **not** been validated against an installed application's own storage. Identification is by documented locations and names, and is tested only on fixtures that copy those layouts. Validating it needs one of: an installed container or VM app with a disk image, plus Full Disk Access for the worker where the image is under `~/Library/Containers`; or a catalog from a Mac that has them. Status: **NOT VERIFIED**.

## Not covered headlessly

Rendering inside the running app, popover and Inspector interaction, small-window layout under real window resizing, VoiceOver. See NATIVE-QA-PLAN.md (all NOT VERIFIED). Offscreen renders in `renders/` show layout only, not interaction.
