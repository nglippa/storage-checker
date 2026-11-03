# Migration Readiness — implementation report

**Milestone:** Migration Readiness — Sparse Storage Detection
**Worktree / branch:** `~/storage-checker-structured-explorer`, branch `migration-readiness`, created from `master` at `8ba2e00`. The brief named this worktree, but it did not exist, so it was created for this milestone. Nothing was committed, merged, pushed, packaged, installed or released.
**Release authority:** none exercised. The protected v2.1 release, existing DMGs, installed apps, production databases, preferences and LaunchAgents were not modified. The running production inventory worker (`local.macbook.storage-monitor.inventory`) was observed but not touched.

## Baseline provenance (follow-up check)

The worktree was recreated from `master` at `8ba2e00`, so I checked that it contains the stabilized Structured Explorer work rather than an older integration base:

- The original worktree (`~/storage-checker-structured-explorer`, branch `integration/structured-explorer`, base `873e069`) recorded its stabilization work (input acceptance, label layout, monitoring hover, navigation throttle, double-click fix) in `artifacts/structured-explorer-integration/stabilization/`. That work was committed in `4b8d772` (Release 2.2.0 with Structured Explorer).
- Focus & Filtering (size filter, Dim/Hide, focus, isolation, Reset) is `a98fa0f`. The verified 2.3.0 focus-filtering candidate DMG records `sourceCommit a98fa0f`, `sourceTree 73fd16a`; `git rev-parse a98fa0f^{tree}` = `73fd16a`, an exact match. `a98fa0f` is an ancestor of `8ba2e00`.
- Between `a98fa0f` and `8ba2e00` the only source changes are `SourcesGUI/CleanupInspectorView.swift`, `tests/InventoryModelTests.swift` and two cleanup-scroll scripts. These are exactly the uncommitted edits the 2.3.0 package recorded as preserved, committed in `ef6095e`. No Structured Explorer, Living Tree, filtering or navigation file changed.
- Every identifier named in the stabilization and focus-filtering records is present at `8ba2e00`, except `window.sendEvent`, which the hover record describes as a scratch-only probe, not product code.
- No other branch, stash or worktree holds Structured Explorer work. The only stash holds `.DS_Store`; `origin/living-tree` is fully merged.
- `artifacts/storage-monitor-v2/baseline/source-hashes.json` differs in 24 files, but it is an **older** snapshot. Each differing file matches either `6218eba` (2.1.0 local test, 27 Oct) or that day's uncommitted UX edits (`status.txt`, `working-tree.patch`), which were later committed in `b43f8d5`.

Conclusion: this branch is built on the latest stabilized and filtered Structured Explorer, the same sources as the verified 2.3.0 candidate apart from the later Cleanup Inspector scroll fix.

## Safety inspection (before any change)

- Main checkout `~/orca/projects/storage-checker`: clean, on `master`. No other worktrees existed.
- Running: the production inventory worker (left alone) and a VS Code Codex session whose working directory was `/` (not this repo). No other agent was editing these files.
- Focus & Filtering (`StructuredExplorerFilter` / `StructuredExplorerVisibility`, commit `a98fa0f`) was complete on `master` and not being modified, so Migration Review **extends that engine** rather than adding a second one.
- Baseline suites were run on an APFS clone of the untouched tree before any edit (see REGRESSION-RESULTS.md). The viewer model suite already crashed on unmodified `master`.

## What was built

1. **Detection engine** (`SourcesShared/SparseStorage.swift`): `SparseAllocation` (logical, allocated, gap, ratio with zero-allocation handling), `SparseStorageThresholds` (configurable, inclusive boundaries, clamped), `SparseStorageClassifier` (path-only category, format and owning application, with evidence text), `SparseStorageLocations` (privacy-protected and cloud locations relative to the home folder, `~` redaction), `SparseStorageProbe` (`lstat` only; `Info.plist` read for sparse bundles, `O_NOFOLLOW`, ≤ 64 KB), `SparseStorageEvaluator` (live vs indexed, identity checks, compression and cloud-placeholder exclusion).
2. **Catalog queries** (`SourcesShared/InventoryModels.swift`, `// MARK: Sparse storage`): primary-key slice scan, changed-folder candidate reads (parent index), and candidate hydration with ancestry. Read-only connections with the reader's existing deadline and cancellation handler.
3. **Detector** (`SourcesShared/SparseStorageDetector.swift`): an actor with its own reader. It runs a full pass (sliced, paced, cancellable), incremental passes from the change journal, identity-keyed live-check cache, coverage (inventory state, accounting, known application locations), and a sorted, bounded report. It commits only finished passes.
4. **Guidance** (`SourcesShared/SparseStorageGuidance.swift`): all user-facing explanation, consideration and data-safety text, tested for forbidden claims.
5. **Viewer** (`SourcesGUI/MigrationReadinessView.swift` + small hooks):
   - `MigrationReadinessController`: runs passes off the main actor, at most one at a time, coalesced to one per 30 s; disabled with `defaults write … inventory.migrationReadiness.enabled -bool false`; thresholds tunable with `defaults` keys.
   - **Overview**: one line under the Storage header's status line ("Migration readiness: 1 item to review · Docker Desktop disk image · coverage limited") with a **Details** popover. The popover shows the leading item's logical size, allocated size and gap, the qualified headline, the explanation, **Reveal in Inspector**, **Learn More**, other items, "Show in Explorer with Migration Review", coverage notes, and the thresholds used.
   - **Inspector**: a "Migration readiness" section for detected items: severity, category, format and likely application (each labelled as inferred), logical, allocated, gap, ratio, bundle or virtual capacity, filesystem, values when indexed, verification status, explanation, a data-safety box, and collapsible considerations. Each selection triggers a recheck on disk (cached for 15 s).
   - **Structured Explorer**: a **Migration Review** toggle in the existing filter row. It reuses node identity, Dim/Hide, focus, isolation and Reset. Each REVIEW/UNKNOWN item's deepest shown node gets a dashed violet ring, its path is context, and unrelated branches fade. Node sizes stay allocated sizes. The footer, the no-match banner and VoiceOver labels mention it.
6. **Tests, benchmark, renders**: see REGRESSION-RESULTS.md, PERFORMANCE-RESULTS.md and `renders/`.

## Decisions made during verification

- **Reporting ratio floor removed by default.** It was first 1.25 : 1. A test showed that this hid a 500 GiB file with 450 GiB allocated (a 50 GiB gap, ratio 1.11). The default is now 1 : 1, so any verified gap of 1 GiB or more is reported; the knob remains.
- **Band files are never listed.** A bundle with sparse 64 MiB bands initially listed each band; bands are now represented only by their bundle.
- **Failed live checks are not cached.** A file in a folder that later becomes readable is checked again on the next pass.
- **Inspector type line.** For detected items the Inspector names the item by its Migration Readiness title. Previously macOS's type lookup called `Docker.raw` a "Panasonic raw image".

## Code review

A code review of the worktree (the session's `code-review` skill at high effort; the Codex cross-model reviewer could not be used because the worktree is outside its allowed roots) reported 10 findings. All 10 were verified against the code and fixed:

1. With Migration Review on, a selected ancestor on a review path was called "not on a migration review path". Fixed by separating `reviewPaths` from ringed `reviewHighlights`; VoiceOver uses the paths. Tested.
2. An item grouped in the shown folder's own "Other items" got no highlight and "no matches". That group is now highlighted. Tested.
3. "Show in Explorer with Migration Review" did nothing with the map hidden. It now shows the map, like the existing reveal path.
4. Hydration ignored SQLite step errors (an interrupted ancestry read could produce an empty chain). It now throws.
5. A generation change during hydration returned an empty set as a finished pass. It now throws; the previous report is kept.
6. During a first index every pass would be a full scan every 30 s. Passes are now ≥ 5 min apart while the inventory is incomplete, and a busy slice is retried.
7. An Inspector recheck recomputed counts from the 500-item list. The counts now change only by the rechecked item. Tested.
8. A refused check made informational-sized items UNKNOWN. UNKNOWN is now reserved for review-sized items. Tested.
9. The cancellation comment overstated what is left untouched. Corrected: live-check observations stay cached; report, entries and journal position do not change.
10. Each candidate re-read its totals with an extra query. It now uses the hydrated node's values.

## Headless renders (`renders/`)

Made by `scripts/render-migration-readiness.sh` from a sparse-file fixture with real measured values. Process activation was prohibited, and every view was drawn by an `NSHostingView` in a borderless window that was never ordered in. These show layout, not interaction or acceptance.

- `overview-summary-{light,dark}.png`: the Storage header line.
- `overview-details-{light,dark}.png`: the Details popover content.
- `inspector-review-{docker-desktop,parallels-desktop,orbstack}.png`, `inspector-informational-diskImage.png`: Inspector sections.
- `explorer-migration-review-{light,dark}.png`: Structured Explorer with Migration Review on, Docker.raw selected, Inspector synchronized.
- `explorer-migration-review-hide-light.png`: Hide mode (only review paths).
- `explorer-filter-off-light.png`: the same view without the filter (sizes unchanged).
- `explorer-migration-review-small-light.png`: 1000 × 640 content area.

Fixture paths are under `/private/tmp`; no personal directory appears.

## Files changed

New:

- `SourcesShared/SparseStorage.swift`
- `SourcesShared/SparseStorageDetector.swift`
- `SourcesShared/SparseStorageGuidance.swift`
- `SourcesGUI/MigrationReadinessView.swift`
- `tests/SparseStorageTests.swift` (model tests and the APFS live probe)
- `tests/SparseStorageCatalogTests.swift` (real-catalog integration tests)
- `scripts/benchmark-migration-readiness.swift`, `scripts/benchmark-migration-readiness.sh`
- `scripts/render-migration-readiness.swift`, `scripts/render-migration-readiness.sh`
- `artifacts/storage-monitor/migration-readiness/*` (this folder)

Modified:

- `SourcesShared/InventoryModels.swift`: +97 lines, appended reader extension only.
- `SourcesShared/StructuredExplorerFiltering.swift`: `migrationReview` flag, `narrows`, `migrationTargets`, `reviewHighlights`, `migrationKeys`. Behavior is identical when the flag is off.
- `SourcesGUI/StructuredExplorerView.swift`: state holds targets (part of the visibility cache key), review ring in the painter, footer, banner and accessibility text.
- `SourcesGUI/StructuredExplorerFilterControls.swift`: the Migration Review toggle.
- `SourcesGUI/InventoryView.swift`: `migration` controller on the browser model, summary line in the header, refresh triggers.
- `SourcesGUI/InventoryNavigatorView.swift`: Inspector section.
- `tests/StructuredExplorerFilteringTests.swift`, `tests/GUIModelTests.swift`, `tests/InventoryIntegrationTests.swift`, `tests/InventoryModelTests.swift`: new cases and registration.
- `scripts/test-gui.sh`, `scripts/test-inventory.sh`, `scripts/test-inventory-model.sh`: compile the new test files.

Not modified: the inventory worker and its schema, monitor, LaunchAgents, packaging, cleanup rules, Cleanup Inspector, storage accounting, version files, release documents.

## Detection architecture (summary)

```
inventory worker (unchanged) ──writes──▶ catalog (logical, allocated, identity per file; change journal)
                                             │ read-only, short separate reads
SparseStorageDetector (actor, own InventoryReader)
   full pass: 50k-id primary-key slices, 2 ms apart ─┐
   incremental: change journal → changed folders ────┼─▶ candidates ─▶ hydrate (path, ancestry)
                                                     │
   live check: lstat (skip protected/cloud; bundles read Info.plist) ─▶ evaluate ─▶ report (≤ 500, exact counts, coverage)
MigrationReadinessController (main actor) ─▶ Overview line + popover │ Inspector section │ Structured Explorer targets
```

Details: DETECTION-MODEL.md. Accounting semantics: FILESYSTEM-ACCOUNTING.md. Wording and Phase 2 design: MIGRATION-GUIDANCE.md.

## What is detected, inferred, unknown

- **Detected (filesystem facts):** logical size, allocated size, gap, ratio, identity, whether the file is compressed or a cloud placeholder (when checked live), sparse bundle capacity from its own `Info.plist`.
- **Inferred:** format (from the name) and owning application (from the location). Always labelled as inferred.
- **Unknown, and shown as unknown:** virtual capacity of any format; whether a copy tool preserves holes; how Migration Assistant sizes or copies sparse files; anything in locations the inventory could not read; current state of items in protected locations (indexed values shown, "not checked on disk").

## Remaining limitations

See DETECTION-MODEL.md ("Known false positives / negatives") and PERFORMANCE-RESULTS.md. In short:

- Without Full Disk Access the worker does not index `~/Library/Containers`, so Docker Desktop's and UTM's images are absent from the report. The coverage note says so when the folder is in the catalog as protected.
- Items in protected locations are never checked live, to avoid permission prompts.
- The classic Living Tree renderer (a `defaults`-only QA fallback) has no Migration Review; the default Structured Explorer has it.
- An item inside the shown folder but grouped into its "Other items" with no shown ancestor below the centre gets no ring; the Overview and Inspector still list it.
- Native GUI behavior is NOT VERIFIED (see NATIVE-QA-PLAN.md).
- On this Mac the real catalog has no candidate at the 1 GiB floor, and the worker lacks Full Disk Access, so the feature's live-data result here is "No large sparse-storage discrepancies detected · coverage limited". The REVIEW paths are exercised only with fixtures.

## Verification matrix

| Area | Status | Evidence |
|---|---|---|
| Sparse files detected reliably | **VERIFIED (headless, APFS)** | Catalog and browser tests on real ftruncated files; 1 GiB floor; boundaries in model tests |
| Logical and allocated reported separately | **VERIFIED (headless)** | Model, catalog, browser; renders |
| Known virtualization/container storage identified | **VERIFIED (path classification)**; owner is inferred, never confirmed with the app | 15 classification tests; catalog Docker/OrbStack |
| Unsupported formats handled honestly | **VERIFIED (headless)** | `.xyz`, `.unknownformat` → sparse file, no format or capacity |
| Sparse bundles (capacity vs band data) | **VERIFIED (headless, APFS)** | Two catalog bundle tests |
| Migration warnings qualified | **VERIFIED (wording tests)** | Forbidden-phrase test; explanation test |
| Overview integration | **PARTIALLY VERIFIED** | Headless renders and controller tests; native interaction NOT VERIFIED |
| Inspector integration and selection sync | **PARTIALLY VERIFIED** | Browser-model reveal/selection test; renders; native interaction NOT VERIFIED |
| Structured Explorer Migration Review | **PARTIALLY VERIFIED** | 11 filter tests, real catalog tree test, renders; native interaction NOT VERIFIED |
| Classic Living Tree renderer | **NOT IMPLEMENTED** (QA-only fallback) | — |
| Existing storage totals unchanged | **VERIFIED (headless)** | Catalog bytes identical; root totals; browser allocated totals |
| No destructive operations | **VERIFIED (code and tests)** | Read-only connections; only `lstat`, `statfs` and a bounded `Info.plist` read; no new action exists |
| Performance | **VERIFIED (measured)** | PERFORMANCE-RESULTS.md; cold first pass 7.3 s on the real catalog, off the main thread |
| Indexing unaffected at shipped cadence | **VERIFIED within ±7 % (60 controlled runs)** | No detectable difference (p = 0.77); under 12× stress +5.8 % median (n.s., heavier tail) |
| Same-process SQLite lock failure | **ROOT-CAUSED; not reachable in shipped processes** | C reproduction: read-only reader in the writer's process → `SQLITE_IOERR_LOCK`/`EBADF`; invariant documented in code |
| Branch contains stabilized Structured Explorer | **VERIFIED** | Baseline provenance section above |
| Overview, Inspector and Living Tree agree on one APFS image | **VERIFIED (headless, Apple-tool fixture)** | 5 agreement checks against `/usr/bin/stat` |
| Docker/VM identification on a real installed application | **NOT VERIFIED** | No such app installed; `~/Library/Containers` not indexed without Full Disk Access |
| Existing suites | **VERIFIED** | All 7 pass (REGRESSION-RESULTS.md) |
| Native QA | **NOT TESTED** | NATIVE-QA-PLAN.md, awaiting permission |
| Release artifacts untouched | **VERIFIED** | Worktree diff touches no packaging, version, DMG or release file; no install/launchctl command was run |
| Phase 2 Destination Capacity Assessment | **DESIGN ONLY** | MIGRATION-GUIDANCE.md |
