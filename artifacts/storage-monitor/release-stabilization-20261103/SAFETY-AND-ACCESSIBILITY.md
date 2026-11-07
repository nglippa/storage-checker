# Safety and accessibility stabilization

## Current same-Mac lifecycle continuation

Branch `migration-readiness`, HEAD `6981c2da5ef1c4a1c528332eb0b1be1948721c39`, with uncommitted stabilization changes. Content fingerprint `a8eced9f62d5c3a3c54e3bb9840970eb8733a66be77e5ed77d054019652eaa77` binds 160 source, script, fixture and instruction files. Version remains **2.2.0 (10)**. This 160-file manifest covers the named compiler/test/tooling inputs, fixtures and root instructions/notices; historical151-file manifests had a narrower selection and are preserved separately. It is not a universal artifact checksum.

Current authority: [LOCAL-LIFECYCLE-RESULTS.md](LOCAL-LIFECYCLE-RESULTS.md), [REGRESSION-RESULTS.md](REGRESSION-RESULTS.md), [REMAINING-ISSUES.md](REMAINING-ISSUES.md) and [CHANGED-FILES.md](CHANGED-FILES.md). Same-Mac real setup/update/rollback are now supported and observed under bounded test identities. Historical blanket external-system requirements below no longer apply to those scoped transactions. Login persistence, permissions/notifications, physical Intel/macOS 14 remain separately pending; current waiting-state native confirmation is complete below.

The final continuation repairs disabled queued-work reporting: retains prior measurements/queue and coverage, reports waiting, stops progress claims, and offers Settings. Reliable disabled overrides are distinct from unknown; currently running indexers remain active. Errors, low-space pauses and unavailable event history take precedence. Twenty waiting/lifecycle regressions and two neutral freshness-caption assertions are included in the final viewer total. The subsidiary outline/Atlas notes now qualify prior measurements without claiming that a recheck is running. It adds no timer/process/write and uses existing status evidence, which can lag by about 30 seconds.

The selected source remains migration-readiness at `6981c2d`; Structured Explorer and Migration Readiness are preserved. Exact dirty source is bound by [the 160-file manifest](evidence/local-lifecycle/final-neutral-freshness/source-manifest.json), [tracked patch](evidence/local-lifecycle/final-neutral-freshness/source-diff.patch) and [new source copies](evidence/local-lifecycle/final-neutral-freshness/source-added/). Version remains 2.2.0 (10); 2.4.0 (12) is an owner recommendation, not a selection. No production install, release package/security changes or commit/push occurred.

## Historical detailed records

The material below retains its original source hashes and observation scope. Claims labelled current/final there refer to those earlier snapshots, not this continuation. Do not use them to override the current matrix linked above.


## Completed app-only native follow-up — 2026-11-04

Session3 used source `0b25faee39036550383783d115ba171953d94bdbe934759ed8e46257c0858229`, approved06:14:23–06:24:23UTC. Testing ended by06:19:07UTC; teardown verified06:20:12UTC, before the06:20:23new-case cutoff. No system settings actions or further desktop input. [Exact cases/evidence](evidence/remaining-closure/native-session-3/session-results.json), [teardown](evidence/remaining-closure/native-session-3/teardown.json).

- Actual product popover warning is readable on native light material, with orange decorative triangle and17.18GBlogical/ZeroKBallocated/17.18GBgap preserved. Representative core title/background contrast8.318:1 (spatially varying material; light only).
- Learn More expanded considerations/Hide Details; Reveal in Inspector selected the sparse image and showed readable warning/Review badge after scrolling. Finder was not invoked.
- Explicit simulated missing-database component showed Inventory has not started and Background monitoring is not configured. Open Settings opened its own QA Settings window. Sparse summary was unavailable(cannotopenmissingdatabase); no clean check or false completed result. Existing-database/no-generation waiting remains unverified.
- Explicit simulated exit0+fresh112GBcapacity+failedinventory showed inventory needs attention; selecting later inventory progress changed it to Recent background reading received. This is component-host evidence, not real service execution.
- Independent guard had an absent baseline and exact batch-owned PID identities. Both QA apps/workers were gone and lease available before the guard was stopped early; its finally/exit journal was confirmed. The scheduled deadline did not fire. Five effective flags and all eight preference values/presence match fresh originals. Existing user/production state was untouched.

Still NOT VERIFIED: existing-database/no-generation waiting, native stale-action/Trash confirmation/cancel, VoiceOver, Reduce Motion, actual system increased-contrast propagation, full-app dark/minimum/larger-text geometry, physical feel/energy/peakRSS, external real setup/lifecycle and actual Intel/macOS14 runtime. This is selected native acceptance, not complete release acceptance. Earlier statuses below retain their historical scope; this completed-session record supersedes their pending claims only for the cases above.


> Current source `0b25faee39036550383783d115ba171953d94bdbe934759ed8e46257c0858229`. The bounded Migration warning contrast correction is headlessly verified; session2 observed selected native workflows, followed by documented interrupted-session recovery at05:52UTC on2026-11-04. Both desktop approvals are expired. [Current results](REGRESSION-RESULTS.md), [remaining checks](REMAINING-ISSUES.md), and [continuation](HEADLESS-CONTINUATION.md) supersede historical status text below.

Historical record follows; exact earlier hashes and limits are preserved.

> Current continuation: [HEADLESS-CONTINUATION.md](HEADLESS-CONTINUATION.md) records the later native session, corrected helper/readiness/contrast changes and fresh verification receipts. The earlier fingerprint/results below remain historical evidence for their stated inputs; they are not current-source acceptance. Desktop authorization expired at 16:37:09 UTC on 2026-11-03.

Status: **PARTIALLY VERIFIED**. Policy/model/retained-adapter proof and native compilation are distinct from the **NOT VERIFIED** real Trash, keyboard, VoiceOver and rendered accessibility acceptance. Final exact commands/counts are in [REGRESSION-RESULTS.md](REGRESSION-RESULTS.md).

## P1: conventional Python environment false refusal

Original issue: preflight followed a descendant interpreter symlink into `/usr/bin/python3`, classified the shared interpreter as moved/protected/possibly active, and refused a conventional disposable .venv even though moving the containing directory moves the link object.

Reviewed path: Inspector preparation and immutable confirmation → bounded complete validation → one-use token and warning acceptance → full revalidation and snapshot equality → exactly one supplied lexical source URL passed to the Trash adapter → destination identity/original absence verification. The native API race qualification remains. No permanent-delete, staging or retry fallback was introduced.

Changes in `SourcesShared/CleanupTrashSafety.swift` and `CleanupDetectors.swift`:

- Recognize a narrow descendant role: real virtual-environment marker/config, real direct `bin`, conventional Python interpreter name, bounded stable alias chain ending at the regular executable `/usr/bin/python3`. Relative aliases within that bin work; ambiguous `..`, broken/looping/over-budget resolution fail closed.
- Skip only the system-managed-base-interpreter protection for that recognized role. Selected links, candidate/ancestor protection, credentials, own data, Git, ordinary external-target links, protected directory targets and all other roles keep their existing protection.
- Continue traversing lexical directory entries without following links. The external interpreter never enters the moved-object inode set or mutation URL. Shared interpreter activity by itself does not prove candidate use; candidate-local raw paths and intermediate external process/PATH aliases remain positive dependencies and refuse.
- Capture link text, intermediate link identities/stamps, target metadata/flags and parent identities in the confirmation snapshot, then re-read at final validation and perform. Only external evidence skips moved-object immutable/restricted flag refusal; source objects retain it. External flags remain fingerprinted rather than discarded.
- Recollect current/final process evidence, preserve entry/read/time budgets, confirmation age/one-use/selection/identity guards and mandatory program-use uncertainty acknowledgment. PATH dependency scanning occurs once initially and again at final validation, not separately for every accepted interpreter alias.

Tests: `tests/CleanupTrashSafetyTests.swift` adds 21 venv/link checks. They exercise conventional classification/confirmation, mandatory warning, retained rename of exactly the candidate and link text, unchanged `/usr/bin/python3` bytes/identity/flags/timestamps, relative aliases, unrelated shared-interpreter use, local/external-alias/PATH dependencies, broken/protected-directory/loop/forged-marker/noninterpreter links, direct selected links, retarget/replacement/new protected child after confirmation and untouched external-directory sentinel. Existing Trash tests continue to cover cancellation, token expiry, process/ancestor/descendant races and adapter outcome uncertainty.

Focused retained-adapter gate passed **190** safety checks before the final full regression. No native Trash was invoked: the injected adapter renames disposable fixtures under `/private/tmp` to retained siblings. This proves the validated operation and no-follow behavior for that adapter; actual FileManager Trash and Finder restore remain NOT VERIFIED. More protected interpreter layouts can still be conservatively refused; this is deliberately not a global symlink-policy relaxation.

## P1: visible keyboard focus and motion

`StructuredExplorerView.swift` no longer disables the native focus effect on its existing focusable/FocusState canvas. Selection and keyboard target remain separate native states; key handlers, zoom, selection and Inspector synchronization are retained. Native platform focus rendering supplies appearance/contrast adaptation instead of a custom modality state machine.

`InventoryNavigatorView.swift` honors accessibilityReduceMotion for selection scroll and disclosure expansion. Independent review caught the alternate technical outline in `InventoryExplorerView.swift`; its two unconditional animations now honor the same setting. Structured Explorer's existing reduced-motion spatial-navigation guard and restrained fade remain.

Native Tab/Full Keyboard Access, light/dark/Increased Contrast focus visibility, mouse-only behavior, real Reduce Motion, VoiceOver order/labels and minimum-window and larger-text layout remain NOT VERIFIED. Source audit and model/host tests do not establish complete accessibility compliance.

## P1: stable cleanup review context

Original issue: the existing 20-second process-evidence TTL correctly invalidated authorization but default filtering removed a candidate while it was being read.

`SourcesShared/CleanupReviewQueue.swift` now separates retained display context from assessment eligibility. Expired former candidates remain Needs recheck in the default candidate view. A separate display-only provenance flag survives uncertain journal/evidence rechecks for the same identity, including when the Inspector must replace its assessment with insufficient evidence. It never restores a review assessment, estimate or plan eligibility. Fresh Preserve/Protected, changed/missing identity or a vanished catalog entry clears that context appropriately. Queue size remains bounded by its existing memory budget.

`CleanupReviewQueueView.swift` displays Needs recheck and offers Recheck Candidate; `CleanupInspectorView.swift` exposes the same action. Stable row IDs retain selection and Inspector context on time-only expiry. Sorting can still change when stale recovery estimates disappear. Explicit tool/type/assessment filters remain effective.

Tests: `tests/CleanupReviewQueueTests.swift` covers TTL 20/20.001 boundaries, retained row/default filter, no plan/estimate eligibility, idle snapshots without process polling, failed journal recheck, fresh recovery, Preserve/Protected clearing (including later TTL), identity change and catalog deletion. The default queue filter change does not extend evidence validity. All Trash preparation still collects and revalidates fresh process/filesystem evidence; queue retention cannot authorize Trash.

## Independent review and limits

A read-only reviewer checked the broad diff and the final safety path. Its confirmed alternate-outline motion and uncertain-recheck retention findings were corrected; the Protected-context follow-up was corrected before source freeze. No concrete new unsafe-delete gap was established by that bounded review. That is not a security certification or proof of absence.

The manual fixture/native matrix is [MANUAL-NATIVE-QA.md](MANUAL-NATIVE-QA.md). No production service, database, real cleanup data, permissions, installed app, protected QA worker or release artifact was modified.

## Current continuation acceptance

See [HEADLESS-CONTINUATION.md](HEADLESS-CONTINUATION.md) for the final94eac source and truthful intermediate failures. Confirmed fixes now include trusted worker-image identity, exact fixture-region spelling, actual persisted-generation bootstrap gate, no-inventory readiness, semantic capacity warning text and inventory-failure monitoring health. Focused correctness64PASS and real product bootstrap22PASS. Default FileManager Trash backend fixture/RENAME_EXCL restoration is VERIFIED; native confirmation-panel interaction is not. Original Settings/capacity/health native observations are qualified historical evidence. Final matching QA bundles/data are ready (`FINAL-READY-FOR-NATIVE.json`), without a desktop launch. Final broad/ABI receipts remain pending until their runners complete.

Desktop approval expired16:37:09UTC; no new native launch/input/system-setting action occurred. Native populated Explorer/navigation/TTL/Migration, current contrast/readiness, Reduce Motion, VoiceOver, larger text/minimum size/dark remain NOT VERIFIED. Production setup/permissions/login require an isolated account. Actual Intel/macOS14 requires another host. Version remains2.2.0(10), with no chosen release package.

## Final headless source and acceptance

Final source `4e55114b25c77818dbcc01a2dbe40ba9b764b6dae67c8c2b86777a0fc699a560`;151files,31modified tracked files and one new test source, all uncommitted. Final affected tests/builds and unchanged-input retained receipts PASS; exact results/limits are consolidated in [REGRESSION-RESULTS.md](REGRESSION-RESULTS.md) and [REMAINING-ISSUES.md](REMAINING-ISSUES.md). Physical log order now uses optional file identity/byte-offset evidence to reject ambiguous same-second recovery while accepting proven later same-stream progress. Matching QA assets are headlessly verified only. The prior desktop approval expired; current native checks and real external-system setup/compatibility requirements remain explicit, not silently passed. Historical reports/logs remain preserved.

## Current native confirmation — VERIFIED, 2026-11-04

The final source `a8eced9f62d5c3a3c54e3bb9840970eb8733a66be77e5ed77d054019652eaa77` and pinned viewer were exercised under the approved app-only grant. Actual Enable registered all three fixture jobs and committed a capacity reading plus a five-node fixture generation. Actual Disable removed all three jobs while retaining the reading and **one naturally pending job**. No synthetic queue or catalog edit was used. The main window showed **Folder updates are waiting**, preserved the browseable tree, exposed Open Settings and showed no first-pass/manual activity indicator. That link opened its own Settings; actual re-enable registered the jobs, advanced recorded readings from one to two, and the main summary became **Inventory is up to date**. Final Disable and independent guard teardown completed by **09:16:17 UTC**, before the 09:17:30 input cutoff / 09:20 hard end. Guard 6502 exited; exact apps/workers and all three jobs are absent, protected files match and no system settings changed.

[Session results](evidence/local-lifecycle/final-neutral-freshness/native-final-confirmation/session-results.json) · [waiting capture](evidence/local-lifecycle/final-neutral-freshness/native-final-confirmation/waiting-main.png) · [recovered capture](evidence/local-lifecycle/final-neutral-freshness/native-final-confirmation/re-enabled-main.png) · [teardown](evidence/local-lifecycle/final-neutral-freshness/native-final-confirmation/teardown.json). Current missing-database setup also reached actual Enable. Empty-catalog/no-generation and disabled-before-root variants, accessibility/system/Trash/hardware limits remain separate.

The initial artifact launch recipe omitted scope-specific temporary directories and was correctly refused before a window. The corrected direct-executable recipe sets only process-local `TMPDIR=<root>/Temporary/` and `SQLITE_TMPDIR=<root>/Temporary`; no admission rule or source changed. Refused-attempt logs are preserved. [Corrected readiness](evidence/local-lifecycle/final-neutral-freshness/NATIVE-FINAL-READY.json) records the recipe and the now-consumed single-use guard.
