# Filesystem safety and native-window validation

<!-- final-rc-followup:start -->
## Final RC follow-up — 2026-10-27

Authoritative evidence: [FINAL-RC-VALIDATION.md](FINAL-RC-VALIDATION.md). **PARTIALLY VERIFIED; packaging BLOCKED.** Fresh automated results in both `/tmp` and `/private/tmp`: Viewer 804, inventory 349, controller 67, full monitor 235 (retention on/off), supplemental 148, standalone safety 131 and real disposable Trash **7/7** per alias. Fixture lifecycle 16 overall. Both development app builds pass with **zero compiler warnings/errors**, strict signatures and valid plists; version 1.0.0(1), arm64/ad-hoc. Counts overlap and are not summed.

The monitor failure was reproduced after 70 passes at removed-entry/rename activity. Old global rename retention changed required unlink events; the repair retains only top-level diagnostic trees while preserving real in-test unlink/assertions. First supplemental rerun passed 145 then failed an omitted install inventory-worker dispatch; exact generated-fixture dispatch was corrected and both final 148 runs pass. All failures and source preservation/command/log evidence remain in the final ledger. No production monitoring logic or Trash architecture was weakened.

Fresh representative evidence reuses the unchanged **1,966,231-entry /1,018,322,944-byte legacy APFS clone**, mechanically read-only on actual M2/8GB hardware. Five bounded discovery rounds and per-sort/filter, pagination, evidence, headless controller/plan-exclusion, read/read contention and resources are measured; pre/post hashes/metadata/sidecars match. Zero eligible legacy entries means first useful candidate, fresh usable/overlap plans and current-journal updates remain unverified. Headless memory/CPU is not native application evidence. No synthetic benchmark substitutes or large new catalogs were generated.

Actual Finder Put Back and the complete current native 3A–3E matrix remain **UNVERIFIED**, with exact manual checklists and preserved six target types/checksums. No app launch/focus/desktop input occurred. The `--database-path` QA viewer deliberately blocks Trash; no guard was bypassed or production database used for native testing. The current user requires **every mandatory gate to PASS**; documented Finder limitations are not a waiver. Final gates 1/2/6/7/8/9 PASS, 3/4 UNVERIFIED, 5/10 PARTIAL. **No RC app/DMG was packaged, installed, launched, published or uploaded; no commit/push or production DB/LaunchAgent/configuration change.** The residual pathname replacement race remains accepted and not eliminated.

Earlier records below are historical evidence, including their old disabled-atomic-Trash policy, counts and superseded release criteria. They do not override this final validation ledger. Recommended next action is actual safe operator Finder/native evidence and the missing representative current-journal/eligible workflow measurements, followed by reassessment of all gates; no feature cycle or Trash redesign.
<!-- final-rc-followup:end -->

## Earlier validation record — historical, preserved

<!-- rc-current:start -->
## Release-candidate validation — current milestone (2026-10-27)

Latest authoritative ledger: [RELEASE-CANDIDATE-VALIDATION.md](RELEASE-CANDIDATE-VALIDATION.md).

**PARTIALLY VERIFIED; RC packaging BLOCKED.** The user explicitly permits standard macOS single-item Move to Trash after mandatory preflight and explicit confirmation, accepting the remaining pathname replacement race. The action is restored in the ordinary Inspector. Protected and verified-active items, detected identity changes and incomplete required checks still fail closed. This is not an atomic expected-object guarantee.

Final pristine safety validation passed **131 assertions and 7 supported-API disposable moves per alias** (`/tmp`, `/private/tmp`). Returned identities, original absence, content/checksum and symlink referent preservation were checked. Fourteen final moved fixtures and fourteen earlier successful fixtures remain in system Trash; no Put Back, emptying or permanent removal occurred. Viewer models passed **804 per alias** and inventory **349 per alias**. Both pristine final development applications built with zero compiler diagnostics. Controller final H validation passed **67/67 per alias**, zero compiler diagnostics. The unchanged full monitor self-test stops after 70 passes at one unlink-specific FSEvents assertion under reversible retention; this is a partial result, not a full pass. The incomplete supplemental attempt is UNVERIFIED and does not replace the failed full suite.

The representative benchmark is **PARTIALLY VERIFIED** on the unchanged 1,966,231-entry legacy APFS clone, M2/8 GB/256 GB class. Initial work median/P95 62.561/91.930 ms; bounded discovery reached 512 artifacts after 74,240 rows in 19.108/20.816 s, not complete catalog coverage. Headless peak RSS 76,562,432 bytes; native resources, first eligible candidate and representative journal/write contention remain unverified.

Finder Put Back and the complete native matrix are **UNVERIFIED/BLOCKED** under AGENTS.md's specific session authorization requirement. No window was launched, focused or manipulated in this milestone. Disposable Finder fixtures and [native manual checklist](build/release-candidate-validation/manual-qa/NATIVE-WINDOW-MANUAL-QA.md) are ready; earlier ambiguous screenshots/clicks do not validate this restored action. No package, installation, publication, commit or push occurred.

All earlier stabilization/disabled-execution sections below are preserved historical evidence. Their old availability policy and counts do not override the current policy or establish current validation.
<!-- rc-current:end -->

Date: 2026-10-27. Checkout: `/Users/nicholaslippa/orca/projects/storage-checker` (`master`, HEAD `e3da2ebe3fa5416e78bf6775de2ae3bf8590dc00`). This pass changes development source and documentation only. It does not establish release readiness.

## Source baseline and isolation — VERIFIED

The primary checkout was already dirty when this pass began: 14 tracked modifications, an empty index, and existing untracked Cleanup, Living Tree, database and documentation work. `AGENTS.md` and the five required Cleanup/Inventory documents were read before edits. The changes in this pass are confined to Cleanup path/evidence, detector, assessment, Trash-safety, queue-view and their tests, plus the requested documentation. The [final preservation proof](/private/tmp/storage-native-qa.3Wbn8U/preservation-final.json) found all 122 original files outside the earlier 29-path integration scope byte-identical to their pre-integration hashes, and all 17 reviewed candidate files untouched by this pass still matched their candidate hashes. The historical count of 125 unrelated files used a different earlier integration comparison set; 122 is the exact count under this stricter original-outside-candidate set. The complete 208,898-byte tracked diff matched the saved post-integration diff byte for byte; HEAD and the empty index were unchanged. `git diff --check` passed. No reset, clean, stash, commit, push, installation, production database, LaunchAgent or full-volume scan was used.

Filesystem mutation was limited to disposable fixtures under `/private/tmp`. Native QA used an APFS clone of the existing 684 KB test tree at `/private/tmp/storage-native-qa.3Wbn8U/tree`; the monitor CLI indexed only that root into `/private/tmp/storage-native-qa.3Wbn8U/data/history.sqlite3` (273 entries, 124 directories, completed). The development viewer opened that isolated catalog with `--database-path`. The sandbox's false low-space result stopped the first fixture indexing attempt; the identical scoped command completed outside the sandbox. No production catalog was read or written by the QA viewer.

## `/tmp` alias root cause and path fix — VERIFIED for tested layouts

The previous inverse failures came from mixing pathname representations. `realpath` of an existing `/tmp` object yields its `/private/tmp` location, while `NSString.standardizingPath` can express the same target as `/tmp`. Claude's current-version detector compared a canonical PATH link with a raw versions directory; Python's PATH-tool detector compared a standardized link target with a raw environment path. A third mismatch appeared in the Git worktree registry back-pointer, and a fourth in a test's lexical read-containment assertion. A `/tmp` safety run exposed the same issue in SQLite WAL companion checks: the validated item was reached through the canonical parent, while the observed open-file path retained the alias.

`ArtifactPaths.canonicalRelativeComponents` now resolves both existing operands with `realpath`, compares whole path components with case preserved, and returns `nil` when resolution or ancestry fails. Claude, Codex, Python and Git evidence comparisons use it; a relative Git worktree registry back-pointer is resolved from its registry directory before comparison, rather than from the process working directory. Process path relationships resolve aliases before the existing lexical positive fallback. The Inspector treats an unresolvable selected path as insufficient evidence and checks a symlink's resolved target against protected scopes. Configured protection roots that are not yet created use `canonicalProtectionLocation`: it resolves the nearest existing ancestor and appends only missing trailing names; broken links, loops, non-directory ancestors and permission failures remain unknown. Trash advisory validation refuses when a protected root or database companion path cannot be resolved. Existing inventory/display paths, device/inode/birth identity checks and the disabled mutation boundary remain separate.

The canonical comparison is component-aware and does not lower-case names. It is not a durable object handle, does not eliminate races, and does not make a later pathname operation safe. The filesystem's own case behavior decides whether an existing spelling resolves; no general case-folded comparison was introduced.

Added disposable assertions cover `/tmp` and `/private/tmp` in both fixture spellings, redundant components, relative and absolute names, Unicode, symlinked parents and final components, broken links, loops, same-prefix siblings, credential links, missing protected descendants and queue alias deduplication. Existing identity-replacement, symlink substitution, protected descendant, permission, concurrent confirmation and injected device-mismatch tests remain in the suite. A bounded real-filesystem probe observed that this case-insensitive APFS volume resolves `tree` and `TREE` to the same canonical spelling. A separately mounted 32 MB case-sensitive HFS+ image distinguished `CaseRoot` from `caseroot` and case variants of a Unicode filename; its symlink resolved to the same canonical target, including the volume's Unicode normalization. The image's device ID differed from its `/private/tmp` parent, and it was detached immediately after the probe. This is **PARTIALLY VERIFIED** volume evidence, not a full safety-suite run across both filesystems. Live mount transitions, alternate-user permission-denial, and other volume behaviors remain **UNVERIFIED**. These limits must not be interpreted as proof about every filesystem.

The final viewer-model suite also includes a disposable Git worktree whose registry points back through a relative path. It verifies that the pointer is interpreted from the registry directory, avoiding a process-working-directory-dependent registration result.

## Identity-bound Trash — BLOCKED

Production Move to Trash remains disabled at the Inspector, confirmation executor, legacy executor and direct `systemTrash` entry points. The deterministic adapter spies continue to receive zero calls. User confirmation tokens bind the indexed identity for validation, expire and are single-use; they do not bind the later mutation to that object.

Apple's [`FileManager.trashItem(at:resultingItemURL:)`](https://developer.apple.com/documentation/foundation/filemanager/trashitem(at:resultingitemurl:)) accepts a URL but documents no atomic expected-inode precondition. Apple's [`rename(2)` manual](https://developer.apple.com/library/archive/documentation/System/Conceptual/ManPages_iPhoneOS/man2/rename.2.html) says it renames the link named by `old`; descriptor-relative `renameat` anchors a directory but still names the final component. Apple's [race-condition guidance](https://developer.apple.com/library/archive/documentation/Security/Conceptual/SecureCodingGuide/Articles/RaceConditions.html) explains why a second pathname check narrows, but does not close, the interleaving window. Holding a descriptor to the approved object cannot prove that a subsequent pathname-based Trash call moves that same object. A file-reference URL and a post-move identity check are not a documented atomic guarantee, and the latter could discover an unintended move only after it occurred. A staged rename has the same final-name substitution problem and does not establish Finder Put Back metadata. No candidate mutation implementation was added; there was no real Trash or Finder exercise.

The required outcome remains either the exact approved object moves or no other object moves. The examined public APIs do not establish that property for this implementation against an uncooperative same-user writer, so the defensible result is continued refusal. This is a bounded conclusion about supported, demonstrated semantics, not a claim about every possible future API.

## Controlled native-window session — PARTIALLY VERIFIED

The user explicitly authorized one roughly 10-minute development QA session and said the desktop was idle. An existing Storage Monitor window was closed before launch. The development viewer appeared with the QA catalog; read-only process/window checks identified the development process and a QA-titled window. Actual macOS window previews showed the ordinary root Inspector, Living Tree 2D with the fixture tree, a populated Review Queue, a selected review-candidate Inspector, and a two-item review-plan sheet. The Queue showed 128 indexed entries checked, 11 verified artifacts, 10 review candidates, and explicit partial-discovery wording. Selecting a candidate updated the Inspector with its exact fixture path, evidence, indexed allocation and qualified recovery. Command-selection produced a count of two. The plan listed both exact target paths, marked total recovery unknown with APFS-sharing uncertainty, and offered no bulk deletion action. The selected Inspector visibly changed to insufficient evidence after process-observation freshness expired.

One reproducible copy defect was observed: after active-use evidence expired, the default Review Candidate filter had no rows but the empty state said “No matching review candidates,” and it used the same text under the Preserve and Protected filters. The scoped source fix now says “Review evidence needs refreshing” when retained verified artifacts are stale, otherwise “No artifacts match the current filters.” The new wording was **not revalidated in a native window** after the safety stop.

The native session stopped when screenshot/focus evidence became inconsistent. `mac-use` region previews showed the QA window, but a separate `screencapture` region file captured an unrelated Orca conversation; two window-ID captures were only 306×350 thumbnails. One QA-intended click occurred after that ambiguous capture and before the discrepancy was recognized, so its recipient cannot be proven. No keyboard input occurred after the discrepancy; no further GUI action was taken. Only the development viewer process was terminated. All four unreliable agent-created screenshot files were deleted. **No persisted screenshot is cited as native proof, and zero unrelated-app interaction is not claimed.** The observed QA previews establish only the interactions explicitly listed above.

The actual-window matrix is deliberately narrow:

| Area | VERIFIED in the actual window | UNVERIFIED in the actual window |
|---|---|---|
| Cleanup Inspector | Ordinary fixture root, selected review candidate, expiry transition to insufficient evidence | Ordinary unrecognized file and folder detail; Preserve and Protected detail; evidence expansion; cleanup preview; long paths and filenames; measurement freshness beyond observed expiry; APFS recovery detail beyond plan warning; scroll stability during refresh; rapid selection changes; vanished-item messaging |
| Review Queue | Opens; partial discovery label and progress counts; populated candidate rows; candidate selection updates Inspector; stale empty-state defect observed | Complete discovery; sort changes; positive filtering and filtered results; reveal in Navigator, Atlas or Living Tree; refresh without scroll jump; loading and truly empty states |
| Multi-item plan | Two candidate selections, count, exact paths, unknown total recovery, APFS-sharing warning, no bulk deletion action | Removal; overlapping directory selection; freshness update after plan changes; plan recomputation after file changes |
| Window and accessibility | Standard 1240×820 QA window and a visible Living Tree 2D fixture | Narrow/wide resizing; long text and large Inspector content; sustained Queue scroll; keyboard navigation; focus behavior; VoiceOver; Atlas, Living Tree 3D and Navigator interaction |
| Visual quality | Native controls and a split layout were visible in the transient QA preview | Detailed typography, spacing, status clarity across states, information hierarchy, scroll behavior, panel resizing, and consistency with Atlas and Living Tree 3D |

There was no native Trash action, production scan or Finder Put Back test. The QA viewer's local test catalog was read-only to the viewer; the separate bounded indexer wrote only the disposable QA catalog. No persisted native screenshot is available for ordinary Inspector, candidate Inspector, Preserve Inspector, populated/filtered Queue, plan, or narrow/wide layouts. The `mac-use` previews were transient observations and are not exportable evidence.

## Adversarial fixture ledger — VERIFIED refusal, execution BLOCKED

The 103 Trash-safety assertions in the GUI suite exercise advisory validation and the disabled mutation boundary. Deterministic fixture barriers cover replacement before and after confirmation, replacement during final checks, directory/parent substitutions, symlink substitutions, protected substitution, disappearance, concurrent use of one token, changed permissions, cancellation, failed/absent adapter results and injected device mismatch. They assert that mutation adapters receive zero calls and fixture identities remain in place. These are **pre-execution refusal tests**. A real move after the validation barrier, partial native Trash failure/recovery, Finder Put Back, and a real mount transition were **not run**: no identity-bound execution candidate exists, and production execution stays disabled. Timing stress tests would not close that proof gap.

## Regression and build ledger

Final primary run, 2026-10-27:

| Gate | Exact result |
|---|---|
| Viewer-model, `/private/tmp` fixture | 776 passed; 103 Trash-safety assertions; zero failed |
| Viewer-model, `/tmp` alias fixture | 776 passed; 103 Trash-safety assertions; zero failed |
| Inventory | 345 passed, zero failed |
| Inventory-model/controller | 56 passed, zero failed |
| Monitor self-test | 233 passed, zero failed |
| Monitor application build | Passed; zero compiler warnings/errors |
| Viewer application build | Passed; zero compiler warnings/errors |

The earlier raw-path GUI failures were genuine alias and test-assumption defects; the final runs cover both alias spellings after the fix. Static checks also confirm no Trash execution route became enabled and Atlas, Living Tree 2D/3D, Navigator, Inspector, Queue, monitoring and inventory journal source remains included. Headless checks do not establish every native interaction.

Two post-fix `/private/tmp` attempts aborted while adding the relative Git-pointer assertion. The first test used branch name `clean` where Git created registry basename `wt-clean`, causing file-not-found before classification. The second rewrote and restored an existing pointer during the test, changing fixture metadata and correctly failing the immutable-fixture assertion. The final fixture creates a separate `wt-relative` worktree and its relative back-pointer before the snapshot; both final alias runs passed. These two fixture-test failures are recorded explicitly and do not count as passing runs.

## Safety and release assessment

| Requirement | Status | Evidence and limit |
|---|---|---|
| `/tmp` alias correctness | VERIFIED | Both alias spellings pass 776 checks; bounded case-sensitive and case-insensitive realpath probes support the comparison; broader volume matrices unverified. |
| Filesystem identity validation | VERIFIED | Device/inode/birth and replacement fixtures validate advisory identity; no atomic mutation binding. |
| Identity-bound Trash execution | BLOCKED | No demonstrated supported atomic expected-object Trash operation; disabled. |
| Protected-path enforcement | PARTIALLY VERIFIED | Canonical protected aliases and fail-closed roots tested; bounded HFS+ case/mount probe, but safety-suite execution on alternate volumes/users unverified. |
| Native-window usability | PARTIALLY VERIFIED | Bounded QA observations above; safety stop and many untested flows. |
| Inspector behavior | PARTIALLY VERIFIED | Headless models and selected native states; full matrix unverified. |
| Review Queue behavior | PARTIALLY VERIFIED | Model coverage and selected native states; complete sorting/reveal/filter flows unverified. |
| Multi-selection accounting | PARTIALLY VERIFIED | Two-item native sheet and model overlap/unknown recovery; no native overlap exercise. |
| Regression coverage | VERIFIED | Both alias layouts and all requested suites/builds pass; broader filesystem and native matrices remain partial. |
| Production-data isolation | VERIFIED | Separate bounded fixture catalog; no production indexing/DB/LaunchAgent/Trash operation. |

Finder Put Back and representative multi-million-node performance remain separate future work. Release readiness is **BLOCKED** by identity-bound Trash and incomplete native validation; no release, installation, packaging, commit or push occurred.

## Recommended next milestone

First establish a documented macOS operation with an atomic expected-object guarantee or retain disabled Trash. Then repeat the unfinished native Inspector/Queue matrix in a controlled QA window with reliable window-ID capture and focus verification, including the corrected stale-evidence empty-state copy. Validate Finder Put Back only with disposable Trash fixtures if execution can be made safe, and benchmark a representative current-schema multi-million-node catalog. Do not infer release readiness from this pass.
