# Single-item Trash safety audit

<!-- ux-milestone:start -->
## UX milestone follow-up — 2026-10-27

User-directed: partial process observation no longer hard-blocks folders containing programs or databases; it requires explicit acknowledgment of `programUseWarning`. Observed use still blocks. The Trash preflight now has its own budget (`trashPreflight`), a target-scoped process index, and a database open-file check that fails closed only beside the database. Diagnosis, fixtures and results: [UX-REFINEMENT-MILESTONE.md](UX-REFINEMENT-MILESTONE.md). 2026-10-28: the program/database warning now always applies to items containing programs or databases (observation covers only the current user); native sheet component behaviour and Finder Put Back of a disposable folder **VERIFIED** (same inode restored). Full-app native sheet remains unreachable by design in QA builds.
<!-- ux-milestone:end -->

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
## User-directed Trash policy — current milestone (2026-10-27)

Latest authoritative ledger: [RELEASE-CANDIDATE-VALIDATION.md](RELEASE-CANDIDATE-VALIDATION.md).

The user explicitly accepts a residual pathname replacement race for ordinary single-item Move to Trash after layered preflight and explicit confirmation. This supersedes the old atomic-guarantee disablement policy. The restored route calls supported `FileManager.trashItem`; preflight and returned-identity checks **do not eliminate TOCTOU** or guarantee storage recovery. Every operation is user initiated; there is no permanent fallback, privileged service, bulk, scheduled or automatic action.

Only the current displayed immutable token can execute. It expires, is one-use, is cancelled on selection changes, is revalidated against filesystem/ancestor/descendant/evidence snapshots, and is serialized across controllers. Raw/legacy APIs cannot create consent. Required checks fail closed; protected roots/credentials/app data/descendants, known active executables/dependencies/databases, dirty/untracked/unmerged Git work and changed identities cannot be overridden. Ordinary unknown dependencies remain warnings after required checks pass; fresh nonzero partial scoped observations require acknowledgment even for Review candidates and never establish global non-use.

The final audit found and reproduced an active database companion hole (0/3 blocked before correction, no mutation). Recognizable `-wal`/`-shm`/`-journal` selections now require complete database-use observations and check active base/companion paths at initial/final validation, including path aliases. Twelve regression assertions cover the three suffixes with active, partial, alias and newly active base evidence. Unobserved extensionless databases/scripts/mapped libraries remain a stated process-scope limitation, not a proof of inactivity.

**VERIFIED:** final pristine safety **131 per alias**, real system Trash **7/7 per alias** with returned identity, content/checksum, source absence and non-target preservation; real running-executable hard block in each layout. All 28 disposable moved fixtures across both successful rounds remain in Trash. Viewer **804 per alias**, inventory **349 per alias**, both pristine builds passed. Controller final H passed **67/67 per alias**, zero compiler diagnostics; full monitor unlink-specific assertion remains a validation gap under no-permanent-deletion policy. Native confirmation interaction, keyboard/focus/accessibility, Finder appearance and Put Back remain **UNVERIFIED**. Packaging is **BLOCKED**.

All earlier stabilization/disabled-execution sections below are preserved historical evidence. Their old availability policy and counts do not override the current policy or establish current validation.
<!-- rc-current:end -->

## Filesystem safety follow-up (2026-10-27)

The latest bounded investigation is [STORAGE-SAFETY-NATIVE-VALIDATION.md](STORAGE-SAFETY-NATIVE-VALIDATION.md). Canonical alias comparisons and fail-closed protected-root/WAL checks strengthen advisory validation, but they do not make any later pathname-based mutation identity-bound. Apple's public [`FileManager.trashItem`](https://developer.apple.com/documentation/foundation/filemanager/trashitem(at:resultingitemurl:)) supplies no atomic expected-object identity precondition; Apple's [`rename(2)` manual](https://developer.apple.com/library/archive/documentation/System/Conceptual/ManPages_iPhoneOS/man2/rename.2.html) describes a named link, and its [race-condition guidance](https://developer.apple.com/library/archive/documentation/Security/Conceptual/SecureCodingGuide/Articles/RaceConditions.html) warns that rechecks do not close the swap window. No safe candidate execution was demonstrated. **All production Move to Trash routes remain disabled; Finder Put Back remains unverified.** The refusal tests below are not a successful mutation proof.

The final primary viewer-model suite passed 103 Trash-safety assertions in each `/private/tmp` and `/tmp` fixture layout. These validate refusal and advisory checks; no mutation adapter executed.

## Current stabilization: application-controlled Trash is unavailable

The reviewed object and the object resolved by a later pathname operation can differ. Validation, confirmation tokens and post-move identity comparisons cannot prevent another writer replacing the leaf or an ancestor between the last check and the mutation. A protected descendant can also appear after directory validation. A post-move mismatch detects an unintended move after it has happened.

The mitigation disables all application-controlled Trash execution. It does not claim to implement an atomic macOS Trash primitive. Ordinary and unrecognized items retain advisory eligibility and explicit uncertainty warnings. Preserve and insufficient-evidence assessments retain warning acceptance. Positive protection, active-use, Git, ownership, permissions, inventory identity, process freshness and bounded-evidence failures still block advisory preparation independently.

The immutable operation reason is: “Move to Trash is unavailable: Storage Monitor cannot guarantee that the reviewed item is the item moved if its path changes. Nothing was moved.”

## Complete execution boundary

1. The Inspector asks `CleanupTrashPolicy.decide` for an advisory decision. Effective controller/UI availability is blocked; the queue remains read-only.
2. `prepare` performs bounded live validation and constructs an immutable token containing the selected inventory node, inspection, advisory decision, preparation time and filesystem/evidence snapshot. Its initializer is private to the safety file. Cancellation consumes the token under a lock.
3. Token `perform` consumes once, checks its 60-second lifetime, requires applicable explicit warning acceptance, repeats validation and compares the snapshot. Even an unchanged, accepted item returns `.refused(unavailableReason)`. It never invokes its supplied mutation adapter.
4. Legacy `perform(node:decision:overrideAccepted:environment:trash:)` preserves supplied blocked/consent reasons, distrusts a forged allowed decision, prepares independently and reaches the same token refusal. It has no separate mutation implementation.
5. Public `systemTrash` throws `CleanupTrashUnavailableError.identityBoundOperationUnavailable` immediately, before reading or resolving its URL. It contains no Foundation Trash, rename, unlink or staging call. This closes direct callers that bypass Inspector and token APIs.
6. The validation script's historical `--real-trash` option now asserts refusal and unchanged identities, reporting `BLOCKED_BY_SAFETY_POLICY`. It cannot reenable production mutation. This continuation does not run that option or create anything in Trash.

There is no runtime preference, environment variable or production test flag that enables path mutation. `.moved` remains in the outcome type for compatibility; current policy execution cannot produce it. The controller does not enqueue successful-move reconciliation for refusal.

## API evidence and bounded conclusion

Apple's [FileManager Trash API](https://developer.apple.com/documentation/foundation/filemanager/trashitem(at:resultingitemurl:)) accepts a URL and returns the resulting location. Its public signature supplies no expected device/inode/birth identity or protection-manifest precondition. Apple's [XNU rename manual source](https://raw.githubusercontent.com/apple-oss-distributions/xnu/main/bsd/man/man2/rename.2) documents directory-relative names for `renameat` and flags such as swap/exclusive/no-follow/beneath; these supply no expected source-inode condition.

The safety inference is limited: no examined API establishes the required atomic reviewed-object-and-protection guarantee under an uncooperative same-user writer. This is not proof that every possible macOS API is incapable of it. File-reference URLs, bookmarks, legacy FSRef APIs, descriptor-to-path resolution and cooperative locks were investigated in the read-only identity report at `/private/tmp/storage-stabilization-trash-identity.md`; none supplied a demonstrated complete guarantee for this implementation. Moving an item to staging and comparing afterward would already risk moving the replacement, so it is not an acceptable substitute.

## Deterministic regression evidence

Current targeted safety fixtures are uniquely named disposable trees under `/private/tmp`, retained for inspection. Replacement fixtures rename the reviewed object to a retained sibling before introducing a substitute. No test calls real Trash or permanently deletes a fixture. A missing selected path is simulated by retaining the original elsewhere; actual unlink/deletion and real mount changes are deliberately not performed.

| Adversarial category | Deterministic check |
|---|---|
| Replacement before confirmation | Preparation rejects the original inventory identity after a retained replacement. |
| Replacement after confirmation | Execution refuses; reviewed and substitute identities remain; adapter count is zero. |
| Replacement during pre-execution checks | An acknowledged background worker replaces the target during injected process observation; evidence fails independently of the unavailable reason. |
| Former final mutation boundary | An armed adapter spy is never called even for unchanged, accepted evidence. |
| Directory substitution | An alternate directory occupies the selected name; both directory identities remain. |
| File replaced by symlink | Link and unrelated referent remain; adapter count is zero. |
| Symlink replaced by file | Retained link, replacement file and referent remain. |
| Parent and ancestor substitution | Ordinary replacements and a symbolic-link parent are refused without moving either subtree. |
| Moved target | Original remains in a retained sibling; selected path stays absent. |
| Missing/deleted-path state | Missing-path state is exercised without unlinking the retained original. |
| Protected substitution or inserted descendant | A disposable `.env` remains; fresh advisory validation independently reports protection. |
| Permission changes | Parent permissions invalidate/refuse execution; fixture permissions are restored. |
| Mount/device identity changes | Synthetic indexed-device mismatch independently blocks preparation. Real mount changes are NOT VERIFIED. |
| Concurrent requests | Two requests sharing a token produce exactly one unavailable and one consumed-token refusal, zero adapters and unchanged identity. |
| Cancellation | Acknowledged background cancellation consumes the token; an already-cancelled validation task independently blocks. |
| Inventory/confirmation binding | Old indexed identity is rejected; separate immutable tokens retain their own node ID, path and identity. |

Additional checks retain uncertainty acceptance, candidate assessment, one-use behavior, in-place edits, child insertion, hard-link active aliases, active executables/PATH references, open database/WAL use, incomplete process observations, budget limits, protected home/custom data/credentials, Git worktree/metadata/lock/registry preservation and delayed Git output handling. Evidence-specific execution tests reject the global unavailable reason, preventing disabled execution from masking broken advisory checks.

Recovery retained the early targeted run at `/private/tmp/storage-stabilization-safety-targeted.log`: **99 passed, 1 failed**. That failure was an assertion defect in the forged legacy-decision check: independent preparation correctly required warning acceptance, while the test expected the global unavailable reason. The corrected assertion checks the stronger warning refusal, zero adapter calls and unchanged identity. The early log is not a final pass; exact current test totals and final build/integration evidence are recorded in `CLEANUP-STABILIZATION-REPORT.md`. Passing these tests establishes refusal and zero adapter calls, not successful Trash, Foundation atomicity, Finder restoration or physical storage recovery.

## Historical observations: superseded implementation only

Before stabilization, the path-based implementation revalidated a token and called `FileManager.trashItem`, then compared returned identity and source absence. The earlier milestone recorded 73 safety checks and four successful disposable real-Trash fixtures in `build/cleanup-review-evidence/real-trash-validation-final-reviewed.log` and `real-trash-results-final-reviewed.json`. Those observations apply only to the historical implementation. They do not establish that replacements were impossible, and are not current successful-mutation evidence. Earlier retained Trash fixtures and reports were not modified or restored.

## Verification limits

Native Inspector layout, confirmation interaction, keyboard/focus behavior, Finder Put Back and physical recovery remain **NOT VERIFIED**. Repository `AGENTS.md` prohibits native window activation and input without specific permission; no such interaction is part of this continuation. Real mount changes and permission checks under alternate-user/root privileges are also NOT VERIFIED. No production database, LaunchAgent, installed app or preserved catalog is changed by safety verification. No unrestricted scan, packaging, installation, commit or push is performed.
