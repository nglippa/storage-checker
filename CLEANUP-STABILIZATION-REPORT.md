# Cleanup stabilization and release readiness

<!-- rc-current:start -->
## Release-candidate milestone — current ledger (2026-10-27)

Latest authoritative ledger: [RELEASE-CANDIDATE-VALIDATION.md](RELEASE-CANDIDATE-VALIDATION.md).

**PARTIALLY VERIFIED; RC packaging BLOCKED.** Source is the primary repository `/Users/nicholaslippa/orca/projects/storage-checker`, HEAD `e3da2ebe3fa5416e78bf6775de2ae3bf8590dc00` plus preserved existing edits. Standard user-directed single-item Trash is restored with explicit sheet-bound, one-use confirmation and retained hard protections. Residual pathname TOCTOU is accepted by product policy and remains unsolved.

Current verified results: viewer **804 per alias**; inventory **349 per alias**; pristine Trash safety **131 per alias**; real supported-API moves **7/7 per alias**, with identities/contents/original absence checked. Final H controller passed **67/67 per alias**, zero compiler diagnostics. Both final pristine applications built with zero compiler diagnostics and existing ad-hoc signing; they are validation builds, not RC packages. Full monitor runs each passed 70 then failed the unchanged unlink-event assertion because tests retain fixtures by rename; the supplemental runner was stopped incomplete and supplies no completed count. No full monitor pass is claimed.

The retained representative catalog contains **1,966,231 legacy entries**, 1,018,322,944 logical bytes, on M2/8 GB/256 GB class hardware; five repeated bounded runs leave its catalog/sidecar manifests unchanged. Initial work median/P95 62.561/91.930 ms; discovery to 512 retained artifacts 19.108/20.816 s with explicit incomplete coverage. Legacy freshness prevents representative eligible-candidate, journal/write-contention and native resource verification. Synthetic fixture results remain separately labelled.

Narrow findings fixed: stale/foreign confirmations, active descendants hidden by overlapping classifiers, absent process observations, final expiry, partial-observation acknowledgment, active SQLite companion dependency direction, and stable `/tmp`/`/var` invalidation/navigation aliases. Native layout/focus/accessibility and Finder Put Back remain unperformed, with manual checklists prepared. Packaging is blocked by incomplete representative/native gates and the monitor validation gap; no installation, publication, commit, push or production state change occurred.

All earlier stabilization/disabled-execution sections below are preserved historical evidence. Their old availability policy and counts do not override the current policy or establish current validation.
<!-- rc-current:end -->

## Filesystem safety and native QA follow-up (2026-10-27)

The current milestone record is [STORAGE-SAFETY-NATIVE-VALIDATION.md](STORAGE-SAFETY-NATIVE-VALIDATION.md). Canonical, component-aware comparison resolves the `/tmp` versus `/private/tmp` detector and safety-fixture failures in both tested layouts: 776 viewer-model checks passed with each spelling, including 103 Trash-safety assertions. Inventory passed 345, inventory-model/controller 56 and monitor self-tests 233; both applications built with zero compiler warnings or errors. Identity-bound Move to Trash remains **BLOCKED** and disabled. A controlled QA window showed bounded Queue, Inspector and two-item plan states, then stopped when independent screenshot/focus evidence became inconsistent. Many native interactions remain **UNVERIFIED**; the observed empty-state copy fix has not been rechecked in a window. No release readiness is claimed. The integration ledger below is historical evidence from before this follow-up, including its then-unresolved alias finding.

## Historical selective-integration record

Primary integration verified on 2026-10-27T04:56:19.355725+00:00. **PARTIALLY VERIFIED; release BLOCKED.** The approved selective source integration and primary builds/headless regression runs are complete. The raw `/private/tmp` GUI fixture variant failed an existing advisory path-alias assertion; both raw `/private/tmp` and normalized `/tmp` variants failed and are recorded separately from the normal `/Users` fixture run. This defect remains unresolved. Trash mutation remains disabled; native interaction, Finder Put Back and complete representative current-schema performance remain unverified. No physical bytes recovered are claimed. The isolated reviewed report and patch remain unchanged; this primary report is the sole separately authorized documentation update after applying that patch.

## 1. Source checkout comparison — VERIFIED

The requested `/Users/nicholaslippa/storage-checker` does not exist. The actual primary is `/Users/nicholaslippa/orca/projects/storage-checker`, branch `master`, HEAD `e3da2ebe3fa5416e78bf6775de2ae3bf8590dc00`. This isolated implementation is `/Users/nicholaslippa/orca/workspaces/storage monitor check/catshark/storage-checker`, a source copy with no `.git`. Git identity inherited from the parent workspace is not application provenance.

The original primary has 10 tracked modifications and 23 untracked paths, including unrelated Inspector and Living Tree work. The immediate integration preflight verified its exact original status and binary tracked diff, HEAD, all 138 original file hashes, and every added target's absence. The previously absent shorthand `~/storage-checker` remained absent and nonsymlink; approval applied to the already established actual primary above. No reset, stash, directory copy, commit or push was used. See `build/cleanup-review-evidence/source-original-*`, `/private/tmp/storage-stabilization-source-authority.md`, and the final integration manifest.

## 2. Files changed — VERIFIED candidate scope

The 29 integrated paths (16 modified existing files and 13 new files) are relative to the initial dirty primary snapshot, preserving its pre-existing work. The primary stabilization report was then updated under separate explicit authorization; all other 28 candidate file hashes still match the immutable manifest exactly. The final per-file base and candidate hashes are in `build/cleanup-stabilization-integration/candidate-manifest.json`; builds, catalogs and fixtures are excluded.

- `CLEANUP-INSPECTOR.md` — modified
- `CLEANUP-REVIEW-QUEUE.md` — added
- `CLEANUP-STABILIZATION-REPORT.md` — added
- `CLEANUP-TRASH-SAFETY-AUDIT.md` — added
- `DATABASE-LIFECYCLE-FOLLOWUP.md` — added
- `SOURCE-PROVENANCE.md` — added
- `SourcesGUI/CleanupInspectorView.swift` — modified
- `SourcesGUI/CleanupReviewQueueView.swift` — added
- `SourcesGUI/InventoryNavigatorView.swift` — modified
- `SourcesGUI/InventoryView.swift` — modified
- `SourcesShared/CleanupAssessment.swift` — modified
- `SourcesShared/CleanupDetectors.swift` — modified
- `SourcesShared/CleanupEvidence.swift` — modified
- `SourcesShared/CleanupReviewQueue.swift` — added
- `SourcesShared/CleanupTrash.swift` — modified
- `SourcesShared/CleanupTrashSafety.swift` — added
- `SourcesShared/InventoryModels.swift` — modified
- `SourcesShared/InventoryRequests.swift` — modified
- `scripts/benchmark-cleanup-review-queue.sh` — added
- `scripts/cleanup-review-queue-benchmark.swift` — added
- `scripts/cleanup-trash-validation.swift` — added
- `scripts/test-gui.sh` — modified
- `scripts/test-inventory-model.sh` — modified
- `tests/CleanupInspectorTests.swift` — modified
- `tests/CleanupReviewQueueTests.swift` — added
- `tests/CleanupTrashSafetyTests.swift` — added
- `tests/GUIModelTests.swift` — modified
- `tests/InventoryModelTests.swift` — modified
- `tests/InventoryProgressiveTests.swift` — modified

## 3. Path-race root cause — VERIFIED source finding

Checking a pathname's identity and then calling a later path-based Trash API leaves a replacement interval. A leaf, ancestor or mount mapping can change after validation; the later API can resolve a different object. More `stat` calls, snapshots, or path canonicalization cannot bind that operation to the reviewed filesystem object. Historical successful disposable Trash moves did not prove race freedom.

## 4. Implemented safety solution — VERIFIED refusal; functionality BLOCKED

The production capability reports unavailable, the Inspector disables execution, the confirmation executor refuses before calling any mutation adapter, and raw `systemTrash` throws before URL resolution. Legacy advisory decisions are independently re-prepared; they cannot bypass stronger consent or protection checks. Immutable tokens bind the indexed node/path/identity, are single-use and expire, but are not claimed to make a path-based Trash API safe. There is no fallback rename, permanent deletion, custom Trash location or weakened eligibility policy.

This records the present implementation boundary, not a claim that no suitable macOS API can ever exist. Protected-path, ownership, active-use, process observation, descendant and evidence checks remain useful advisory barriers. Ordinary items still require their independently prepared warning, but no accepted confirmation can execute Trash in this build. See `CLEANUP-TRASH-SAFETY-AUDIT.md` for exact scope and refusal evidence.

## 5. Adversarial test results — VERIFIED refusal boundary

The current final GUI suite contains **100/100 safety assertions** (73 advisory safety and 27 disabled-boundary assertions), including leaf/symlink replacement, missing target, parent/ancestor substitution, added descendants/protected children, edits/permission changes, device mismatch, immutable selection tokens and concurrent single-use confirmation. Mutation spies receive zero calls; reviewed/substituted/unrelated identities are preserved. These are deterministic refusal tests, not successful native Trash or Finder tests. Device/mount identity mismatch is injected; real Trash mount transitions remain UNVERIFIED. Any independent inventory HFS fixture check does not establish Trash mount safety.

An early targeted run was 99 passed / 1 failed because its forged legacy test incorrectly required the terminal unavailable message despite earlier correct refusal for an unaccepted ordinary warning. The corrected test requires that exact stronger warning refusal, zero adapter calls, and unchanged original identity. The freeze manifest records its old/new hash. Final suite evidence below supersedes the early failure without erasing it.

## 6. Finder Put Back findings — UNVERIFIED

No current item was sent to real Trash and no Finder interaction occurred. The four successful fixture moves and 12 retained Trash items mentioned in prior records are historical, remain untouched, and do not prove this build's Put Back behavior. Establishing a supported identity-bound Trash operation is required before any fresh disposal/Put Back exercise can be meaningful. No recovery amount or reclaimed physical space was measured.

## 7. Native-window observations — UNVERIFIED

No app was launched, focused or activated; no desktop keyboard, mouse or accessibility input was sent. Permission/window-list checks supply no app interaction evidence. [AGENTS.md](AGENTS.md) requires: “If a check needs a focused GUI, stop and ask the user for permission.” It also says launching this project’s apps counts as activation and requires the same explicit permission. This is the exact source of the native gate; a future request must name the QA window and session duration.

NOT VERIFIED: Inspector and Queue scrolling; desktop/narrow resizing; native sorting/filter interaction; selection and stale-row presentation; loading/empty/error states; warning/confirmation sheets; keyboard and focus behavior; rendered accounting/long paths; Preview invalidation as seen in a window; Finder Put Back. Headless controller assertions and source inspection do not establish these observations. No screenshots were taken in this pass.

## 8. Representative catalog benchmarks — PARTIALLY VERIFIED

Evidence: `/private/tmp/stabilization-benchmark-633f8e21-84de-49b0-bac8-b784d46a8207/{provenance.json,catalog-validation.json,bounded-benchmark.json,bounded-benchmark.log}`. A Darwin `clonefile` APFS clone of the dated retained backup was used, with no full-copy fallback; source metadata was unchanged. The 1,018,322,944-byte clone contains **1,966,231 nodes** (249,623 directories, 1,658,481 files, 58,083 symlinks, 44 other). It was opened query-only, with no migration, writer or change journal. Its generation says building/initial-complete. This is slightly below the requested 2–3 million-node range and does not establish a current-schema end-to-end candidate workflow.

| Bounded measurement | Current result |
|---|---|
| Metadata pages, 32 × 128 rows (4,096 rows) | p50 1.094 ms; p95 4.198 ms; max 9.667 ms; 0 errors |
| Actual evidence/process classification, 16 nodes | p50 5.709 ms; p95 7.511 ms; max 9.216 ms |
| Queue actor, eight steps | 50.580 ms; 512 rows scanned; 11 retained; 0 eligible |
| First classified evidence | 7.260 ms; **not** first eligible candidate |
| Model five sorts/filter | p50 0.213 ms; p95 0.228 ms; max 0.279 ms |
| Model multi-selection plan | p50 0.024 ms; p95 0.028 ms; max 0.066 ms |
| Model Inspector refresh | single 6.868 ms sample |
| Model idle expiry | p50 0.0039 ms; p95 0.0041 ms; max 0.0050 ms |
| Four concurrent read-only readers | p50 0.669 ms; p95 0.694 ms; max 0.735 ms per batch |
| Cancellation | 0.044 ms; cancellation observed |
| Headless idle | 0.106 ms process CPU over 1,064.714 ms wall |
| Peak headless RSS | 16,285,696 bytes (about 16.29 MB), entire process including preceding 83 regressions |

Shared M2/8 GB host; uncontrolled cache state; bounded sample, not a full walk. Real paths can change after the catalog snapshot. First eligible candidate latency, current-schema incremental journal under representative size, writer contention, native interaction/idle resources and GUI memory remain UNVERIFIED. APFS exclusive allocation/sharing was not measured. No synthetic model measurement is labeled native latency.

## 9. Review Queue correctness findings — PARTIALLY VERIFIED

The current queue model tests cover freshness expiry (including idle), journal/generation invalidation, conservative missing journal/unknown evidence, bounded listing replay for existing or lower-ID rediscovery, cancellation and read errors, and canonical/identity overlap handling with qualified allocation estimates. Current targeted evidence is **83/83** at the preserved benchmark log; full-suite counts appear below. All estimates remain qualified for APFS sharing, snapshots and allocation uncertainty; no guaranteed reclaimed bytes are shown.

Final independent review also identified and corrected an Inspector pending-preview publication race: a noncandidate queue result must cancel the task even before any Preview has published. The minimal fix cancels unconditionally for that state and refreshes a pending preview when replacement evidence remains a candidate. Two deterministic headless controller checks suspend the estimate through process expiry and journal invalidation, release it, join that exact task and verify stale recovery cannot publish. Native rendered behavior remains unverified.


Primary validation exposed an unresolved advisory path-alias defect in the reviewed source. `CleanupEvidence.swift:153–156` normalizes a symlink target with `NSString.standardizingPath`, which turns `/private/tmp/.../ruff/bin/ruff` into `/tmp/.../ruff/bin/ruff`. `CleanupDetectors.swift:465` compares this target with raw `c.subject.path` through `ArtifactPaths.isWithin`; `CleanupEvidence.swift:19–35` only strips the Data-volume prefix and compares lexical scopes. The alias mismatch misses the PATH link: the synthetic Ruff tool environment loses Preserve and becomes Insufficient evidence. No detector, safety policy or test assertion was changed. The normalized `/tmp` fixture variant also failed, now at the earlier Claude resolved-version Preserve assertion. Claude canonicalizes its PATH symlink through kernel `realpath` to `/private/tmp`, then compares it with raw `/tmp` `versionsDir` at `CleanupDetectors.swift:129–130`; this is the inverse mismatch. These failures show inconsistent alias handling across detectors. A final normal `/Users` fixture run matches the standard script layout and the earlier isolated invocation; it does **not** resolve or conceal either alias defect. It remains a release blocker requiring a separately reviewed path-comparison fix and explicit alias regression. Evidence: `/private/tmp/storage-primary-integration-pwlq1oqu/path-alias-diagnosis.json` and the retained raw-failure fixture/log.

## 10. Integration status — VERIFIED selective application

User authorization covered the reviewed selective integration and primary headless checks. Applied only the immutable patch with SHA-256 `7fe50b7581a1bfa399bb72716fd38b752022c530bcdf0980dc265fb0e890949b` to `/Users/nicholaslippa/orca/projects/storage-checker` after an immediate repeated `git apply --check` and full hash/status checks. The named `~/storage-checker` stayed absent; both execution and independent read-only review confirmed the actual primary's resolved path and repository ownership. No directory copying, reset, stash, cleanup, forced checkout, staging, commit or push was used.

All 29 applied file hashes initially matched the reviewed candidate: 16 existing files changed and 13 files were added. The fresh preflight recorded 141 original nonignored files (118 tracked plus 23 untracked): all **125 original noncandidate files** retained identical bytes and modes, and unrelated tracked diff, Git HEAD and index remained unchanged. For the 16 intended overlapping files, exact candidate bytes verify preservation of the reviewed changes built on the original dirty base. Git status matched exactly the expected selective changes. No unreviewed source file was integrated. Git-ignored build/catalog/cache artifacts were excluded from source hashing; no nonignored source file was excluded.

Evidence: `/private/tmp/storage-primary-integration-pwlq1oqu/{preflight.json,preflight-status.txt,preflight-tracked.diff,preflight-index.diff,post-apply-verification.json,post-apply-status.txt,post-apply-tracked.diff,final-primary-verification.json}`. The original isolated `candidate.patch`, `candidate-manifest.json` and report retain their preflight hashes. This primary report is the sole extra authorized documentation delta; it records its own before/after hash in the final verification artifact. Application source and tests remain identical to the reviewed isolated implementation, including Atlas, Living Tree 2D/3D/camera/color, Navigator, Inspector, Queue and monitor build inputs.

No installed app, production database, production LaunchAgent, active QA worker, preserved backup/catalog or historical Trash fixture was modified by this integration. No native application launch/activation, distribution packaging or production scan was performed. Existing test harnesses cleaned only their owned synthetic fixtures.

## 11. Exact regression test results — primary execution

These are fresh executions from `/Users/nicholaslippa/orca/projects/storage-checker`, after selective integration. Both builds and the original standard suites ran sequentially with SDK `/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk`. Exact commands, cwd, diagnostics and durations are in `/private/tmp/storage-primary-integration-pwlq1oqu/primary-regression-run.json`; stage logs are adjacent. GUI fixtures and the explicit monitor `--data-dir` use this unique `/private/tmp` evidence root; inventory/controller harnesses use their own bounded synthetic fixtures. No native GUI entry point was launched.

**Three GUI invocations must be distinguished.** The unchanged script first used raw `/private/tmp/storage-primary-integration-pwlq1oqu/gui-fixtures` and aborted after 127.376 s with exit 133 at the Python PATH-tool assertion. Its retained log contains 527 complete PASS lines and one observed assertion failure; the abort lost a buffered stdout tail, so the total passing assertion count before the failure is not established. Compilation had zero warnings/errors; the original runner’s one error-marker match was a runtime `Fatal error`, not a compiler diagnostic. The failed fixture and `test-gui-raw-private-tmp-failure.{log,json}` remain retained. The normalized `/tmp/storage-primary-integration-pwlq1oqu/gui-normalized/gui-fixtures` variant also aborted (126.872 s, exit 133), at the earlier Claude active-version Preserve assertion, retaining 490 complete PASS lines and one observed assertion failure; its passing total is likewise not established after the buffered abort. Both failures compiled without warnings/errors. The final normal-layout GUI row below uses the unchanged script and assertions with `/Users/nicholaslippa/orca/projects/storage-checker/build/cleanup-primary-integration-pwlq1oqu/gui-fixtures`, matching the script’s usual `/Users` build-fixture layout and the earlier successful isolated invocation. **Both temporary-path variants remain failing. A normal-layout pass is not a source fix or an unqualified all-regressions-pass claim.**

| Stage | Exit | Warnings / errors | Duration | Exact primary log result |
|---|---:|---:|---:|---|
| `build-monitor` | 0 | 0 / 0 | 76.186 s | Built /Users/nicholaslippa/orca/projects/storage-checker/build/MacBook Storage Monitor.app |
| `build-viewer` | 0 | 0 / 0 | 73.633 s | Built /Users/nicholaslippa/orca/projects/storage-checker/build/Storage Monitor.app |
| `test-inventory` | 0 | 0 / 0 | 358.141 s | 345 inventory tests passed |
| `test-inventory-model` | 0 | 0 / 0 | 88.876 s | 56 inventory model tests passed, 0 failed |
| `test-monitor` | 0 | 0 / 0 | 83.886 s | 233 tests passed |
| `test-gui` | 0 | 0 / 0 | 129.834 s | 764 GUI model/read-only tests passed; isolated fixtures: /Users/nicholaslippa/orca/projects/storage-checker/build/cleanup-primary-integration-pwlq1oqu/gui-fixtures |

The primary GUI log contains **100/100 Trash safety assertions** (73 advisory safety plus 27 disabled-boundary checks), including unchanged original identities and zero mutation-adapter calls. The 83 queue regressions are included in the GUI total. Headless controller tests include both deterministic suspended-preview expiry/journal invalidation checks. All 71 application/test freeze hashes remain identical to the reviewed isolated implementation after execution. The normal build scripts include all reviewed feature sources; local signature/plist checks and executable hashes are recorded in `primary-built-app-integrity.json`.

The earlier isolated pass was 764 GUI, 345 inventory, 56 controller and 233 monitor, also warning/error-free; its immutable ledger remains at `/Users/nicholaslippa/orca/workspaces/storage monitor check/catshark/storage-checker/build/cleanup-stabilization-validation/regression-run.json`. It is historical comparison, not a substitute for the primary executions above.

All primary stages used scoped sandbox escalation because the already diagnosed sandbox important-usage capacity API returned zero despite adequate real capacity. No test assertion, production low-space policy, deadline or space hook was weakened. The preserved isolated diagnosis is retained for transparency:

The first inventory attempt stopped at its first assertion (expected 11 checkpointed entries, observed 0) because the sandbox returned **0 important-usage available bytes**. A fresh disposable CLI fixture independently reported `paused: low disk space`. The same Foundation metadata API outside the sandbox returned **26,151,956,480 available bytes** for the 245,107,195,904-byte volume, above its 2,451,071,959-byte low-space threshold. The exact unchanged isolated stages were rerun with scoped sandbox escalation; no production policy, deadline, assertion or test-space hook was weakened. Evidence: `sandbox-capacity-diagnosis.json`, `sandbox-failure-result.json` and `test-inventory-sandbox-failure.log` in the validation directory. Final current results above retain the original test conditions.

Both current primary local bundles passed signature/plist integrity checks. App builds used only their normal local signing; no extra QA application bundle, distribution image, installation or deployment was created.

## 12. Release-readiness matrix

`PASS` applies only to the stated verified scope. `PARTIAL` records bounded/model evidence with outstanding real workflow checks. `BLOCKED` cannot meet a release requirement currently. `UNVERIFIED` was not exercised.

| Requirement | Status | Evidence or limit |
|---|---|---|
| Trash identity safety | PASS | Operation disabled; tested entry points cannot invoke a mutation adapter. This is not successful race-safe Trash. |
| Trash functionality | BLOCKED | Identity-bound native mutation capability absent. |
| Protected-path enforcement | PASS | Current deterministic advisory/refusal regressions; no native mutation safety claim. |
| Ordinary-file confirmation | PARTIAL | Stronger warning and token policy verified; accepted execution unavailable. |
| Finder Put Back | UNVERIFIED | No fresh Trash move or Finder interaction. |
| Physical recovery | UNVERIFIED | No disposal or exclusive allocation/recovery measurement. |
| Review Queue correctness | PARTIAL | Current queue/controller regressions; representative journal/native workflow still missing. |
| Multi-selection accounting | PARTIAL | Overlap and qualified model estimates; native rendering and exclusive APFS allocation unverified. |
| Inspector usability | PARTIAL | Controller tests and Preview cancellation; native scrolling/confirmation unverified. |
| Native-window validation | UNVERIFIED | No desktop activation/input authorization. |
| Representative catalog performance | PARTIAL | Read-only legacy 1.966M-node bounded samples; no first eligible/current-journal proof. |
| Source integration | PASS | Authorized selective patch applied; exact scope, primary preservation and fresh primary checks verified. |
| Build integrity | PASS | Final monitor/viewer local builds, zero warnings/errors; no release package. |
| Regression coverage | PARTIAL | Normal-layout GUI and other standard primary suites pass; both temporary-path advisory alias variants remain known failing regressions. |
| Production-data isolation | PASS | No production DB/service/installed app mutation, scan or Trash operation; primary preserved. |

## 13. Remaining blockers

1. No demonstrated identity-bound native Trash API; all production Trash routes deliberately disabled.
2. Native Queue/Inspector and Finder Put Back requirements lack current consent and execution evidence.
3. Representative current-schema, journal-enabled end-to-end candidate and contention performance is unverified; the retained legacy clone must not be migrated silently.
4. The raw/private/tmp Python tool PATH/symlink alias defect remains unresolved. A separately reviewed canonical scope comparison and explicit alias regression are required; this integration did not authorize source changes beyond the original reviewed patch.

The database lifecycle follow-up remains documentation only: preserve the existing backup/retained scratch catalogs; evaluate bounded retention and qualified exclusive allocation separately, benchmark the potentially redundant index before any removal, and avoid unsupported compaction. No production or retained backup/catalog was deleted, no production index was removed, and no storage savings were remeasured.

## 14. Recommended next action

Review this candidate as a read-only, nonmutating cleanup-review build. Decide whether to accept a review-only scope while Trash remains disabled or separately investigate a supported identity-bound native operation. Prepare a separately reviewed canonical path/scope comparison fix and regression covering both /private/tmp and /tmp aliases without weakening protected-path or identity checks. Keep the integrated source scoped to read-only review; obtain specific native-window consent for a named QA window and bounded session before any native checks. Do not release or package this as completed Trash functionality.

Tooling note: Graft freshness was queried first; no deep graph was available, though the wiring graph was synchronized. Targeted source/artifact fallback was used; no graph-derived token saving is claimed. The benchmark clone/evidence, validation logs and historical Trash fixtures are retained. Standard inventory/monitor harnesses clean only their owned synthetic fixture trees/catalogs; no user files or historical Trash fixtures were deleted.
