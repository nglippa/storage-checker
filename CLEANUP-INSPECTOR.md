# Cleanup Inspector — evidence-based storage intelligence

<!-- rc-current:start -->
## User-directed single-item Trash — current milestone (2026-10-27)

Latest authoritative ledger: [RELEASE-CANDIDATE-VALIDATION.md](RELEASE-CANDIDATE-VALIDATION.md).

The ordinary Inspector again offers **Move to Trash…** for one explicitly selected eligible file/folder. Cleanup classification remains advisory: an unrecognized item need not be an artifact to be eligible, but protected/verified-active items and incomplete mandatory boundaries stay blocked. The native sheet binds the exact selected path/identity/type and displays classification/evidence, warnings, contents inclusion, Trash/APFS/storage uncertainty and the accepted residual pathname race. Ordinary, insufficient-evidence and partial scoped-observation cases require explicit acknowledgment. Cancel consumes authorization; no navigation shortcut or automatic action invokes Trash.

Fresh asynchronous preflight and exact displayed-token binding reject changed/foreign/expired confirmations. Duplicate/concurrent execution is guarded. Results show the actual destination or uncertainty/error; success and uncertain native outcomes request parent reconciliation without automatic retries. Completion preserves a newer Inspector selection. Native sheet interaction/layout/focus/VoiceOver/scrolling remain **UNVERIFIED**; [operator checks](build/release-candidate-validation/manual-qa/NATIVE-WINDOW-MANUAL-QA.md) are prepared. Preview wording now describes only the read-only preview rather than claiming the application never moves items.

**VERIFIED:** viewer **804 per alias**; pristine safety **131 per alias**; actual supported-API disposable moves **7/7 per alias**, identities/contents/original absence checked. Controller final H passed **67/67 per alias**, including confirmed ordinary/candidate moves through the retention adapter, real isolated-worker inventory/Queue reconciliation, preserved newer selection and uncertain-error refresh; zero compiler diagnostics. Finder Put Back is **UNVERIFIED** and no restoration guarantee is made. All 28 moved disposable fixtures across two rounds remain in Trash; none was permanently removed or restored.

On the retained legacy 1,966,231-entry catalog, headless selection-to-result median/P95 was 2.166/61.861 ms (10 samples), repeated controller creation 1.527/2.175 ms (10), and rapid 30-selection submission 2.776/3.177 ms (5). These exclude native input/rendering. Both pristine builds passed, but representative/native and monitor regression gaps keep packaging **BLOCKED**.

All earlier stabilization/disabled-execution sections below are preserved historical evidence. Their old availability policy and counts do not override the current policy or establish current validation.
<!-- rc-current:end -->

## Filesystem safety and native QA follow-up (2026-10-27)

The current record is [STORAGE-SAFETY-NATIVE-VALIDATION.md](STORAGE-SAFETY-NATIVE-VALIDATION.md). Path evidence now resolves both sides of existing-object ancestry comparisons; failed canonicalization becomes insufficient evidence, and a symlink into a protected location cannot inherit its innocuous display name as a safety decision. Inventory paths remain user-visible and filesystem identity remains device/inode/birth based. The development QA window showed the ordinary root Inspector and a selected Review Queue candidate Inspector, including freshness invalidation. The session stopped at an ambiguous focus/screenshot boundary, so evidence expansion, preview, Preserve/Protected detail, vanished-item state, long-path extremes, narrow/wide layout, keyboard and VoiceOver remain **UNVERIFIED** in a real window. Move to Trash remains disabled.

## Stabilization continuation — current source

The ordinary Inspector now reports **Move to Trash unavailable**. Production Trash is disabled at the visible control, preparation/controller boundary, token execution boundary, legacy policy entry point and raw system adapter. The examined public path-based macOS Trash API did not establish an atomic expected-identity-and-protection precondition. Final validation followed by that API therefore does not establish the required no-unintended-replacement guarantee. No replacement move mechanism is claimed; this is not a proof that every possible macOS API is incapable of it.

Classification, protection and ordinary-item advisory eligibility remain available. A review candidate or an accepted warning does not grant execution capability. The queue and multi-item plan remain read-only. Native scrolling/layout, keyboard/focus, VoiceOver, Finder Put Back and physical storage recovery remain **UNVERIFIED** in this continuation; no application window was activated and no historical Trash fixture was moved or restored.

Queue evidence now expires after 20 seconds of process-observation age even on an idle inventory. Invalidation closes an open preview and cancels an in-flight first preview; a cancelled estimate cannot republish stale recovery after invalidation. A refreshed candidate restarts a pending preview against its new evidence. The queue derives its assessment, candidate count, filters, read-only plan and reused Inspector from the same freshness decision; expired evidence becomes Insufficient evidence with unknown recovery. Its once-per-second presentation refresh does no evidence collection. Unknown indexed allocation remains Unknown, without a logical-size fallback. Current bounded representative benchmark evidence and limits are in `CLEANUP-REVIEW-QUEUE.md`.

Current regression/build results and release gates belong in `CLEANUP-STABILIZATION-REPORT.md`. All test results and real-Trash observations in the prior record below describe the earlier milestone; they do not establish current functionality.

## Prior milestone record

Historical status, 2026-10-26, prior milestone: source implementation is staged in the isolated workspace copy `storage-checker/`. The source checkout at `/Users/nicholaslippa/orca/projects/storage-checker` was read-only; its existing uncommitted work was preserved in the copy. Production catalogs, backups, retained scratch catalogs, installed apps and LaunchAgents were not used as write targets. No full-volume scan, installation, packaging, commit or push was performed.

The Cleanup Review Queue and its multi-item plan are read-only. The normal Inspector retains explicit, single-item Move to Trash, with fresh validation and a confirmation bound to the validated filesystem object. No bulk, automatic, scheduled or permanent deletion is implemented. Finder Put Back and native real-window behavior are **UNVERIFIED in this milestone**. Historical test counts and benchmarks below describe the prior Inspector pass; current evidence and exact milestone results belong in `CLEANUP-REVIEW-QUEUE.md`.

Verification labels: **VERIFIED** means exercised or directly inspected in this pass, **PARTIALLY VERIFIED** means bounded fixture/source evidence with stated production or rendering gaps, and **UNVERIFIED** means not exercised. Source implementation alone does not establish production safety.

## 1. Architecture

Three independent components in `SourcesShared` (no SwiftUI, no LLM):

| Component | Role |
|---|---|
| **Classification** (`CleanupDetectors.swift`) | Detectors (`ArtifactDetector`: cheap `applies`, bounded `classify`) say what an item appears to be: kind, tool, characteristics (active, historical, generated, reinstallable, unknown — not exclusive), structured confidence (Confirmed, Strong evidence, Tentative, Unknown), supporting and contradicting observations, unknowns, related items, dependencies, and **structured facts** (`ArtifactFacts`, where nil means "not established", never "no"). Unvalidated layouts return nil. |
| **Evidence** (`CleanupEvidence.swift`) | `ArtifactProbe`: metadata only (lstat, names, link targets, canonical paths, APFS private size) plus content reads limited to an allowlist (`package.json`, `pyvenv.cfg`, Git pointer files, `codex-package.json`, a ≤ 4 KB tool launcher, `.gitignore`, 4-byte executable headers); every read is recorded. Budget: 4,000 listed entries, 24 reads, 1.2 s. `ProcessObservation`: executables, working folders and (for Claude/Codex processes) open files from the kernel process table, with a count of processes it could not inspect. `GitInspector`: worktree state with Git. |
| **Assessment** (`CleanupAssessment.swift`) | `CleanupPolicy` reads only facts and the identity state — never names, sizes or dates — and returns Preserve, Review candidate, Insufficient evidence or Protected with reasons and risks. `ArtifactInspector` runs identity → protection → detectors → policy → storage. |

GUI: `CleanupInspectorController` (async, cancellable, newest selection wins) and `CleanupInspectorSection` / `CleanupPreviewView` in `SourcesGUI/CleanupInspectorView.swift`; `CleanupInspectorPresentation` (shared, testable) holds the wording.

## 2. Files

| File | Change |
|---|---|
| `SourcesShared/CleanupModel.swift` (new) | Types: kinds, tools, characteristics, confidence, observations, relations, facts, classification, status, assessment, identity state, storage quantities, inspection |
| `SourcesShared/CleanupEvidence.swift` (new) | Paths, probe and read allowlist, process observation, Git inspector, environment |
| `SourcesShared/CleanupDetectors.swift` (new) | Claude Code, Codex, agent sessions, Git worktrees, Python, Node detectors; protected scopes |
| `SourcesShared/CleanupAssessment.swift` (new) | Policy, inspector, recovery estimate, preview model |
| `SourcesShared/CleanupPresentation.swift` (new) | Inspector section wording |
| `SourcesGUI/CleanupInspectorView.swift` (new) | Controller, section, preview |
| `SourcesGUI/InventoryNavigatorView.swift`, `SourcesGUI/InventoryView.swift` | Section appended to the existing Inspector; evidence follows the subject, its inventory row and inventory changes |
| `tests/CleanupInspectorTests.swift` (new), `tests/GUIModelTests.swift`, `scripts/test-gui.sh` | Detector, safety, policy, presentation and preview tests |
| `tests/InventoryModelTests.swift` | Headless controller tests |
| `scripts/benchmark-cleanup-inspector.sh`, `scripts/cleanup-inspector-benchmark.swift` (new) | Benchmark and offscreen renders on a catalog clone |
| `DATABASE-LIFECYCLE.md` (new) | Internal storage audit |

## 3. Detectors and recognized layouts

Layouts were taken from this Mac (names and metadata only) and are the only ones recognized.

| Detector | Layout | Notes |
|---|---|---|
| Claude Code | `~/.local/share/claude/versions/<semver>` (one executable per version) and the folder itself | Resolution from the `claude` command on PATH: a symlink into the folder, or a launcher script of ≤ 4 KB from which only `claude/versions/<v>` references are extracted. Running versions from the process table. Executables are identified by their 4-byte header and never run. Non-version names stay tentative. |
| Codex | `<.codex or .codex-*>/packages/<channel>/releases/<version>-<platform>/{bin/, codex-package.json}`, `<channel>/current` → active release; the releases folder | Per account (default, `-account-N`): each account's `current` is judged within that account. A `bin/codex` symlink to a shared location is reported, not followed. Releases without `bin/` and metadata stay unclassified. |
| Node | `node_modules`, `dist`, `build`, `.next`, `storybook-static`, `out`; npm, Yarn, pnpm and Bun caches | Requires the enclosing `package.json`; lockfiles and install records (`.package-lock.json`, `.modules.yaml`, …); output needs positive evidence (`.gitignore` entry, Next.js or Storybook dependency); a folder that contains its own `package.json`/`.git` contradicts; nested `node_modules` are not judged. Scripts are never run. |
| Python | Folders with `pyvenv.cfg` (project venvs and uv/pipx tool venvs), `__pycache__`, pip and uv caches | Project manifest and lockfile next to a venv; tool venvs are active when PATH commands link into them; bytecode folders must contain only `.pyc`/`.pyo`. Use of a venv by a running interpreter cannot be observed (said explicitly). |
| Git worktrees | A folder whose `.git` file points to `<repo>/.git/worktrees/<id>` with a `gitdir` file pointing back | Registration, repository, branch or detached HEAD, uncommitted changes, untracked files, commits in no other branch or remote, `locked`, processes working inside. Submodule `.git` files are excluded. |
| Agent sessions | Claude `<.claude*>/projects/<project>[/<id>.jsonl]`; Codex `<.codex*>/sessions/YYYY/MM/DD/rollout-*`, `archived_sessions/`; tool `*.sqlite` databases | Names, structure and timestamps only; conversation content is never read. Open files of Claude/Codex processes and writes in the last 15 minutes mark sessions active. Databases are always preserved. |
| Protected | macOS-managed paths (`/System` without the Data volume, `/usr` except `/usr/local`, `/bin`, `/sbin`, `/private/var/{db,vm,folders}`, …), credential names (`auth.json`, `.env*`, keys, `.netrc`, …), `~/.ssh`, `~/.gnupg`, `~/.aws`, Keychains, the Claude/Codex data folders and their settings files, Storage Monitor's own data | Never read; no recovery estimate. |

## 4. Evidence collection

- Bounded (entries, reads, time) and asynchronous; a newer selection cancels and supersedes an older inspection (results carry a token).
- Read-only: no write API exists. Content reads only through the allowlist, with `O_NOFOLLOW`, a size cap per purpose and an audit log. Symlinks are never followed during walks; link targets are resolved as paths only.
- Process table: `proc_listallpids`/`proc_pidpath`/`proc_pidinfo` (no process is run). Processes of other users usually cannot be read; their count is reported and absence is always worded as "not observed … not proof".
- Git (worktrees only): a real Git (`/Library/Developer/CommandLineTools`, Xcode, Homebrew; never the `/usr/bin` shim), `--no-optional-locks` and `GIT_OPTIONAL_LOCKS=0` (no index refresh written), `core.fsmonitor=false`, every configured content filter neutralized for the status run, no pager, no prompts, 2-second limit. Inspected executables are never run.
- Identity: device, inode and creation time are compared with the indexed identity at inspection time. A missing indexed identity cannot establish identity; a replaced or missing item voids earlier evidence. Trash validation additionally snapshots target and ancestor metadata and bounded descendant identities.
- Nothing is cached beyond the current subject's result.

## 5. Assessment policy

- **Protected** — protected scope.
- **Preserve** — any positive evidence of use or unique work: resolved or current executable, running executable, contains the active installation, open by a process, a process working inside it or its project, PATH commands installed from it, a live database, a locked worktree, uncommitted changes, untracked files, commits in no other branch or remote, session records written in the last 15 minutes.
- **Insufficient evidence** — identity changed or missing; confidence below Strong; or any fact a kind needs is not established (no other version active, process table unreadable, no project or lockfile, no positive generated evidence, Git state unknown, worktree registration unconfirmed, …).
- **Review candidate** — only when the kind's facts are established (for example: another version is resolved or current and the process table was read; a lockfile reproduces dependencies; Git confirms no unique work). The UI says: "It may not be needed. This is not a recommendation to delete it: review the evidence and risks first."
- No status says "safe". Age and size are not inputs to the policy.

## 6. Inspector integration

The existing Inspector (identity, sizes, share, measurement, Open / Reveal in Finder / Copy Path) is unchanged. Below it, for every selection and above Open / Reveal / Copy Path, a CLEANUP REVIEW section (always visible; it used to appear only for recognized items, which made it hard to find). For recognized and protected items it shows: title, kind · tool, characteristics · confidence; the status (small symbol, restrained color) with summary and reasons; the first four observations with "Show all evidence (n)" (supporting, "Against", "Unknown", incomplete collection); storage impact; risks and dependencies; related items with their roles; the evidence time and a refresh button. Ordinary items do no inspection and show "Not a recognized artifact" with the kinds the review does recognize.

**Scrolling (fixed 2026-10-26):** a background refresh used to close an open preview, so the Inspector shrank and jumped back to the top while it was being read. Now a refresh of the same item keeps its evidence and preview on screen and updates them in place, and inventory change notices re-collect evidence at most every 20 s. A new selection starts at the top, with no cross-fade (the fade overlapped the old and new layouts). `scripts/probe-inspector-scroll.sh <catalog clone>` checks this offscreen: the scroll offset holds through revision changes, re-inspection, explorer reloads, a remeasured row and 25 s idle, and resets to 0 for a new selection.

## 6a. Historical single-item Trash policy — superseded by disabled execution

Cleanup classification is advisory for ordinary file management. Ordinary files, ordinary directories, unknown artifacts and insufficient-evidence artifacts may be moved after explicit warning acknowledgment when every required hard-block check completes. The warning states that Storage Monitor has not established whether the item is safe to remove. A Review candidate still requires a confirmation; it is never labeled “Safe to delete.”

**Hard blocks dominate every assessment and acknowledgment:** system/protected paths and their ancestors; credentials and authentication stores; Storage Monitor's own data and active catalog; the home directory and critical home roots; verified active executable/process/database references; dirty, untracked or potentially unmerged Git work; blocked descendants; unverifiable identity or incomplete required protection/active-use checks. Hard-link aliases and ambiguous links/mount boundaries are conservatively refused when their impact cannot be established. A Preserve assessment with unresolved historical references may be warnable, but verified hard-block facts cannot be overridden.

Implementation: `CleanupTrashPolicy` (`CleanupTrash.swift`) separates the advisory decision from `prepare` and execution (`CleanupTrashSafety.swift`). Preparation revalidates identity, canonical boundaries, ancestors, protected descendants, active process/file references and applicable Git state within a bounded no-follow walk. The immutable `CleanupTrashConfirmationToken` holds the exact indexed node, fresh inspection, decision and validation snapshot. It expires after 60 seconds, is consumed once, and is invalidated on cancellation. The native sheet is prepared asynchronously before presentation. It shows an exact escaped path, filesystem identity, classification, supporting facts, risks, indexed size and recovery uncertainty. A changed selection discards its token.

Execution accepts that exact token, repeats required checks immediately before the supported macOS `FileManager.trashItem(at:resultingItemURL:)` operation, and refuses if the target or relevant evidence differs. No public path-based Trash API provides an atomic “move only if inode still equals expected” primitive: the remaining interval between final validation and the system API is a documented **residual TOCTOU limitation**, not a zero-race guarantee. Directory safety that exceeds its entry/time/permission budget fails closed rather than implying safety.

Successful moves enqueue a refresh of the enclosing folder. Refresh-request errors are shown separately; a successful Trash response does not establish completed inventory reconciliation, Finder restoration or physical recovery. QA builds with catalog copies keep Trash disabled, since paths may still reference real files. Current fixture results are recorded in `CLEANUP-REVIEW-QUEUE.md`; only disposable validation fixtures may be moved during testing.

The queue itself hides all Trash controls, including in the reused Inspector. Its plan has no execution API.

## 7. Read-only preview

For review candidates, "Show cleanup preview" opens inline: exact target path; volume and file ID; tool; classification and confidence; indexed size and measurement state; the 12 largest entries from the inventory with "Largest n of m items (not an exhaustive listing)" when partial; items that must be preserved; known references; unresolved risks; unknowns; the recovery estimate or "Recovery amount unknown" with the reason; storage accounting limitations; evidence freshness. It offers no action and states: "Preview only. Storage Monitor does not delete, move or change anything."

## 8. Storage accounting

Logical size, indexed allocated size, the measurement state and time are shown separately. Physical allocation is not derived from the index. A recovery estimate is shown only when defensible:
- a single file with one link: its APFS private size (bytes not shared with clones);
- a folder (preview only): the sum of private sizes over a complete bounded walk (≤ 20,000 entries, 1.5 s) where hard-linked files are excluded and files sharing all data with clones count as zero;
- otherwise "Recovery amount unknown" with the reason (incomplete walk, hard link, protected, identity changed). Never zero by default.

Every estimate notes that local snapshots may still keep the data. "About these sizes" explains that indexed allocation can exceed what deletion frees (clones, hard links, snapshots).

## 9. Inventory freshness

Evidence is keyed to the subject's inventory row (identity, path, status, coverage, size, measurement time, generation, listing state): any change collects it again; inventory change notifications re-collect a recognized item's evidence. The identity check at inspection time catches changes the inventory has not reconciled yet. A subject that leaves the inventory is reported ("… is no longer present; the selection moved to its folder") and keeps no recommendation or preview. Old sizes appear with their measurement state ("Previously measured", "Waiting to be rechecked"). No filesystem watcher was added.

## 10. Historical Inspector tests (prior pass; not current milestone results)

| Suite | Before | After |
|---|---|---|
| Viewer model (`scripts/test-gui.sh`) | 505 | 581 (+64 cleanup, +7 Move to Trash policy, +5 other) |
| Headless inventory model (`scripts/test-inventory-model.sh`) | 31 | 42 (+9 cleanup controller incl. preview kept through refresh, throttled refresh, Trash with a stand-in) |
| Inventory (`scripts/test-inventory.sh`) | 345 | 345 |
| Monitor self-test | 233 | 233 |
| Viewer and monitor builds | — | no errors or warnings |

Detector coverage (synthetic fixtures, real Git repository): active, historical, running, launcher-script-resolved and unnamed Claude versions; no active version; current, historical, per-account, running, shared-binary and unrecognized Codex releases; Node dependencies with lockfile, in an active project, nested; generated `dist`/`.next`; `build` folders without evidence (false positives); a `dist` that is a project; npm cache; project, unexplained, tool-linked and orphaned tool venvs; bytecode caches (pure and mixed); pip cache; clean, dirty, untracked, unmerged, locked, process-referenced, orphaned worktrees and a submodule; Claude and Codex session records (historical, recent, open by a process, archived) and a state database; credentials, system paths, Storage Monitor's data, a tool's data folder; an ordinary old file.

Safety: no fixture executable or package script ran (marker file absent); the fixture is unchanged (size, time, mode and inode of every entry; the Git repository byte-for-byte); only allowlisted files were read, never credentials, session records or databases; no secret or conversation sentinel appears in any output; no read outside the inspected layouts (symlinks escaping the fixture and a symlink loop do not extend walks); an unreadable folder is reported as incomplete; old dates never create review candidates; an unreadable or partly readable process table never yields one; a replaced or missing path voids earlier evidence. Policy: positive use preserves, review needs established facts, identity changes void, no status says "safe". Presentation and preview: review wording, ordinary items show nothing, folders show "Recovery amount unknown" (never zero), clones and hard links are excluded from estimates, incomplete listings and walks are labelled. Controller: evidence published off the main thread, ordinary items skipped, a slower earlier result discarded, unchanged rows reuse evidence and remeasured rows re-collect, the preview estimates from a complete walk, a vanished subject keeps nothing.

## 11. Historical Inspector performance (prior pass)

`scripts/benchmark-cleanup-inspector.sh` on a clone of the 2.07M-node catalog; inspections read the real filesystem (read-only). Shared machine; indicative. Not measured on the 8 GB MacBook Air: the figures below are small enough that it is expected to be fine there, but that is an assumption.

| Measure | Result |
|---|---|
| SQLite node read | p50 1.45 ms, p95 2.94 ms |
| Preview children (12 largest) | p50 0.81 ms, p95 1.65 ms |
| Quick check every selection pays (2,000 random nodes) | p50 22 µs, p95 41 µs; 112 of 2,000 could be artifacts |
| Full inspection | node_modules 7.1 ms · build output 7.4 ms · `__pycache__` 0.07 ms · venv 7.1 ms · releases 0.02–6.7 ms · worktrees 67 ms (Git) · sessions 0.3–73 ms; all: p50 6.9 ms, p95 67 ms |
| Outcomes over 230 real items | Insufficient evidence 117 · Review candidate 52 · Preserve 16 · unrecognized after validation 45 |
| Selection → published evidence (controller) | p50 9.1 ms, p95 9.3 ms |
| 1,200 rapid selection changes | 39 µs each on the main thread; final evidence for the last selection; 234 stale results discarded |
| Memory | +2.3 MB over those changes; one inspection retained |

Most of a typical inspection is the process-table read (about 6 ms for ~540 processes); worktrees add Git (about 60 ms).

Offscreen renders (`build/cleanup-inspector/evidence/`, borderless window never ordered in): `cleanup-inspector-reviewCandidate.png` (a `__pycache__`, preview open), `cleanup-inspector-preserve.png` (a uv tool environment linked from PATH), `cleanup-inspector-insufficientEvidence.png` (a node_modules without the facts for review).

## 12. Inspector limitations and historical validation

1. **Historical prior-pass claim, not revalidated in the current milestone — real window, partly checked (2026-10-26, QA copy on a catalog clone, ~5 min, ended early when the user's terminal came to the front):** verified Claude 2.1.310 → Preserve (running), 2.1.306 → Review candidate with evidence, ordinary folder → "Not a recognized artifact", freshness line, QA Trash block. Found and fixed the cross-fade overlap. Not checked in a window: the preview open and scrolled by hand, the Trash sheet, Codex releases, narrow/wide layout, keyboard focus, VoiceOver. The Trash tests use a stand-in, never the real Trash.
2. Detectors know only the layouts listed; anything else is unclassified (deliberately).
3. The Claude launcher on this Mac chooses a version at run time; the resolved version is then unknown and only running processes establish use.
4. Active-use observations are scoped to current-user executables, working directories and observable file descriptors. Other UIDs, libraries/memory-mapped files after descriptor closure, shared memory and future process starts are not completely observed. Required observation failures block Trash, but a completed scoped snapshot is never proof of global non-use.
5. Python environment use by a running interpreter is not observable.
6. Git inspection runs Git (the one external program), with repository-configured commands disabled; worktrees in very large repositories may exceed the 2-second limit (then: Insufficient evidence).
7. Snapshots are not enumerated; every estimate says they may keep data.
8. The preview's folder estimate stops at 20,000 entries / 1.5 s (then: unknown).
9. Session activity uses open files of Claude/Codex processes and a 15-minute write window; a session resumed later cannot be predicted.

## 13. Historical follow-up

1. Real-window review of the section and preview (with permission).
2. The read-only review list and plan are implemented in this milestone; see `CLEANUP-REVIEW-QUEUE.md`. Per-item “why kept” history remains a follow-up.
3. Done early at the user's request: single-item Move to Trash (section 6a).
4. More layouts (Xcode DerivedData, simulators, Homebrew caches, Docker) through the same detector interface.
5. Database lifecycle items from `DATABASE-LIFECYCLE.md`.


## 14. Historical Cleanup Review Queue milestone — superseded verification

**VERIFIED:** final viewer model/read-only suite **724 passed** (including **73** Trash safety and **70** queue checks); inventory integration **345 passed**; headless inventory/controller **50 passed, 0 failed**; monitor self-test **233 passed**. Both application targets built with SDK 26.5 for arm64/macOS 14, with **zero final compiler warnings or errors**. Final logs are under `build/cleanup-review-validation/`; the exact ledger is in `CLEANUP-REVIEW-QUEUE.md`. The targeted counts are included in 724, not an additional total.

**VERIFIED on disposable fixtures:** the final system Trash API passed four real cases (ordinary file, ordinary folder, recognized dependency candidate and symlink), with original absence and returned device/inode confirmed and the symlink referent preserved. A real kernel-observed disposable executable was hard-blocked. Across the milestone's successful runs, 12 disposable items remain in Trash; none of those real-Trash fixtures was restored or permanently removed. The headless controller suite additionally verifies a confirmed indexed item moves through a stand-in, its parent refresh is consumed by the real fixture worker, and the vanished row disappears from the read-only catalog.

**PARTIALLY VERIFIED:** bounded fail-closed protection, fresh active-use/Git checks and one-use exact-target confirmation are implemented and fixture-tested. The public path-based macOS Trash API retains a final non-atomic replacement interval. Scoped process observations do not establish global non-use. The queue, its reused Inspector context and multi-selection plan are read-only; sorting/filtering cover the retained bounded page.

**UNVERIFIED:** Finder Put Back, physical recovery after Trash, native queue/Inspector/confirmation layout and interaction, VoiceOver/focus, representative multi-million-node performance and native application idle/memory behavior. Notification launchd/AX/DMG harnesses were not run because their actions exceed the permitted scope. The synthetic 100,000-row benchmark has verified M2 MacBook Air/8 GB host context; it is not a native or production-scale performance claim.

The original checkout's 138 source/artwork hashes, dirty git status and tracked diff match their initial records. Source edits are staged only in this isolated workspace copy. No production catalog, backup, retained scratch catalog, installed app or production LaunchAgent was modified, and no full-volume scan, installation, packaging, commit or push was performed. See `SOURCE-PROVENANCE.md`, `CLEANUP-TRASH-SAFETY-AUDIT.md` and `DATABASE-LIFECYCLE-FOLLOWUP.md`.
