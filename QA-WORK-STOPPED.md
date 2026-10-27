# Native QA runtime work stopped — 2026-10-27

**INCOMPLETE — DO NOT LAUNCH THE QA APPLICATION.** Work stopped on the operator's request to switch to a local 2.1.0 test DMG. This record supersedes previous QA launch-readiness guidance. No native window, Finder action, installation or packaging was performed during this QA task. Existing native/Finder/performance release gates remain unverified/partial; no gate is upgraded.

## Completed

- Added explicit strict QA profile/anchored root loader, private canonical path/identity checks, small-catalog bound, helper hash pin, profile expiry, hardlink/symlink/device checks, owned session lock and request/persisted-work scope validation.
- Strict opt-in QA identity `local.macbook.storage-monitor.viewer.native-qa`; normal production identifiers and legacy read-only database QA preserved. Bootstrap precedes SwiftUI construction, includes headless-only verification path, QA-domain preferences, disabled application URL cache, actual AppKit restoration controls, explicit logs and QA Settings without production monitoring access.
- Fixture-only immutable Trash scope is enforced centrally at preparation/execution and bound to the confirmation token; normal safety/active/protected checks retained. Git worktree cleanup is conservatively unsupported in strict QA. Residual pathname replacement race is not eliminated.
- Added a nonpersistent, bounded, owned fixture-worker path, parent-death deadline and stop/restart generation guard. This implementation is not yet end-to-end verified.
- Prepared 15 exact fixture registrations, manifest, tiny empty QA catalog/profile and generated manual launcher under `build/native-acceptance/runtime/`. **These are incomplete runtime artifacts, not a ready operator environment.**
- `scripts/verify-native-qa.py` exists but was **NOT RUN**. No new QA jobs will run after this stop.

## Exact completed checks

| Check on latest frozen source | Result |
|---|---|
| Monitor build | PASS; exit 0; 82.294 s; zero compiler diagnostics |
| Strict QA viewer build | PASS; exit 0; 83.485 s; zero compiler diagnostics |
| Focused runtime/scope tests | 42 assertions passed |
| Existing Trash safety tests | 131 assertions passed |
| Combined focused executable | **173 passed, 0 failed**; 47.057 s |
| Final build/test source hashes | Match stopped source snapshot |

These are builds/headless tests, not native-window evidence. No representative benchmark or broad regression campaign was repeated. A normal viewer build passed earlier, but predates final hardening and is **not** the final-source normal-viewer build. Controller regression on the final implementation has not run.

## Observed failures retained

1. Initial test harness placed existing Trash alias fixtures under the repository; an existing assertion assumes `/tmp`/`/private/tmp` aliases and failed. Restoring that suite's disposable fixture parent to `/private/tmp` corrected the harness; final 173 assertions pass. Failed log retained as `test-native-qa-before-fixture-fix.log`.
2. First real isolated helper bootstrap refused safely: macOS Foundation `temporaryDirectory` ignored TMPDIR and returned `/var/folders/.../T`. No indexing followed. Evidence: `worker-initialization.json`. Source now requires explicit SQLite TMPDIR and actual VFS tempfilename proof, with unredirectable Foundation OS temp documented as an OS-managed exception, but the **corrected actual bootstrap has not yet run**.

## Remaining before QA can be called ready

1. Refresh the copied pinned helper/profile consistently from the final build. The runtime currently pins an earlier copied helper; do not use its generated launcher.
2. Run the actual QA executable's headless `--qa-verify-only` from an unrelated working directory. Verify QA CFPreferences write/readback, production-domain preservation, SQLite VFS temporary filename, real transaction sidecars/mailbox and refusal before NSApplication for invalid identity/flags/root/environment/concurrent session.
3. Run actual bounded helper lifecycle checks: initialize only fixtures, reject outside-root requests/persisted catalog work, cancellation, owner death, no orphan, contained reconciliation. Existing scripted integration checks are unexecuted.
4. Build the final-source normal viewer; run relevant final-source controller/runtime checks and inspect all diagnostics. No blanket rerun or benchmark is necessary.
5. Complete `QA-RUNTIME-ISOLATION.md` and regenerate `QA-HANDOFF.md` only after the runtime proof succeeds. Exact OS-managed exceptions (QA preference/cache domain, real Foundation system temporary path and authorized system Trash) must be reported honestly; do not claim TMPDIR redirects Foundation.
6. Native operator acceptance, Finder Put Back, first-run usability and native resource/performance measurements still require actual operator testing. No window or restoration result is inferred from model tests.

## Packaging transition

The user separately authorized a **local test DMG 2.1.0**, not release readiness, installation, notarization, publication, commits or pushes. The ordinary packaging build uses production identifiers and does not opt into QA. Before packaging, handle the new development-only baked `#filePath` anchor: `verify-dmg.sh` rejects embedded build-machine home/repository paths. A packaging-only compile branch can exclude that anchor/strict development activation while preserving normal behavior; the separately authorized packaging step now uses `STORAGE_MONITOR_DISTRIBUTION` for both packaged binaries and compiles the anchored development root out. The strict QA profile is unavailable in the normal DMG, with production identifiers unchanged. This is a packaging portability fix, not a resumed QA implementation campaign. Preserve prior DMGs and existing `build/dist/work` before the packaging script's cleanup.

## Evidence and preservation

Everything is under `build/native-acceptance/runtime-implementation-evidence/`: original baseline/original files, retained failed/intermediate logs, final build/test JSON+logs, `stopped-source-hashes.json` and `stopped-preservation.json`. All existing user modifications were retained; only the focused files listed below changed during implementation. HEAD and index hash remain unchanged. Protected production database/config/LaunchAgent metadata were checked read-only; no production writer, LaunchAgent or active QA-worker command was issued. No source changes or QA jobs should be resumed without a new task instruction.

Task-modified existing paths:

- `Sources/Inventory.swift`
- `Sources/InventoryCommands.swift`
- `Sources/StorageMonitor.swift`
- `SourcesGUI/CleanupInspectorView.swift`
- `SourcesGUI/InventoryView.swift`
- `SourcesGUI/StorageMonitorApp.swift`
- `SourcesShared/CleanupEvidence.swift`
- `SourcesShared/CleanupTrashSafety.swift`
- `SourcesShared/InventoryRequests.swift`
- `scripts/build-gui.sh`

New source/scripts/tests: `SourcesShared/NativeQARuntime.swift`, `SourcesGUI/NativeQABootstrap.swift`, `Sources/NativeQAWorker.swift`, `tests/NativeQARuntimeTests.swift`, `scripts/prepare-native-qa.py`, `scripts/test-native-qa.sh`, `scripts/verify-native-qa.py`.


### Protected-state observation

Production `history.sqlite3` metadata changed during the long preparation interval: size **1,371,430,912 → 1,373,089,792 bytes**; mtime/ctime **1793115068212145404 → 1793117004395342639 ns**. Device/inode/mode match. No production writer, SQLite connection, application or service command was issued by this task; the cause is unknown and no production process was investigated or stopped. Whole-database preservation cannot be certified from this observation. All other sampled protected metadata match. Exact before/after values remain in `stopped-preservation.json`.


## Separate packaging result

The authorized local **2.1.0 (build 1)** universal test DMG completed successfully after QA work stopped: [STORAGE-MONITOR-2.1.0-LOCAL-TEST.md](STORAGE-MONITOR-2.1.0-LOCAL-TEST.md). Both final **normal distribution** binaries compiled for arm64 and x86_64 with zero diagnostics; 25 packaging checks and the bundled monitor self-test passed. This closes the distribution build step, not the pending normal-development/controller QA proof. No native window, Finder restoration or resource/performance gate was verified. The strict development QA profile is unavailable in this normal-runtime DMG.
