# Next work: Time Machine local snapshots (tmutil) in Storage Monitor

Status at `60ac812` (2026-11-12). Decision already made by the operator: **"tmutil is the way."** Do not reopen the
route choice; the native `fs_snapshot_create` route stays blocked (root-only probe returned `EPERM`, see
`APFS-LOCAL-CAPABILITY-INVESTIGATION.md`).

## Already done (in `60ac812`)

- `SourcesShared/TimeMachineSnapshots.swift`
  - `SystemTimeMachineSnapshotCommand`: fixed `/usr/bin/tmutil localsnapshot`, fixed env (`PATH`, `LC_ALL=C`), null stdin,
    merged stdout/stderr, 64 KiB output cap, 120 s timeout (TERM, then KILL). Synchronous: **callers must run it off the
    main actor**.
  - `TimeMachineSnapshotHistory(directory:runner:)`: private per-user journal (`history.json` + `create.lock`, dir 0700,
    files 0600, `O_NOFOLLOW`, owner/nlink checks, atomic temp-write + fsync + rename + dir fsync, 200-entry cap).
    - `load()` returns activities and converts any stale `started` entry to `interrupted`.
    - `create(acknowledgeUncertain:)` writes the intent **before** launching tmutil, then records the outcome:
      `reportedCreated` (exit 0 and exactly one valid `Created local snapshot with date: YYYY-MM-DD-HHMMSS` line),
      `failed` (non-zero exit), `uncertain` (timeout, truncated output, or exit 0 without a parsable token),
      `interrupted` (recovered `started`).
    - Throws `commandInProgress` (lock held), `acknowledgementRequired` (a prior `uncertain`/`interrupted` exists and
      `acknowledgeUncertain` is false), `unsafeStorage`, `corruptHistory`, `persistenceFailed`. No automatic retry.
  - Records OS-reported creation only. It never adopts a snapshot, never stores a UUID, and contains no deletion code.
- `tests/TimeMachineSnapshotTests.swift` + `scripts/test-time-machine-snapshots.sh` (fake runner; passes).
- Docs: root-only probe result (`EPERM`, UID 0, disposable image detached) in the capability investigation, the 3.0.1
  release record and the readiness review.

**Nothing calls the backend yet.** `scripts/build-gui.sh` compiles `SourcesShared/*.swift`, so it is in the viewer binary
but unreachable.

## To do

### 1. Model wiring (`SourcesGUI/SnapshotManagementModel.swift`)

Add Time Machine state to `SnapshotManagementModel` (or a small sibling `@MainActor` model it owns):

- `tmActivities: [TimeMachineSnapshotActivity]`, `tmBusy: Bool`, `tmError: String?`.
- History directory: `MonitoringSetup.dataDirectory(home:)` + `time-machine-snapshots` (the parent is the app's
  existing `~/Library/Application Support/MacBook Storage Monitor`; `prepareDirectory()` requires the parent to be
  owned by the user and not group/world-writable).
- `loadTimeMachineHistory()` and `requestTimeMachineSnapshot(acknowledgeUncertain:)` run `load()` / `create(...)` in a
  detached background task and publish the result on the main actor. Map each `TimeMachineSnapshotHistoryError` to its
  `errorDescription`.
- **QA sessions (`isQA`) must never run tmutil.** Load history read-only at most; the request action is disabled. Add a
  QA fixture path if the existing `--snapshot-management-fixture` pattern makes that natural.
- Keep it independent of the privileged helper: the tmutil route must not require `available`/`canMutate`, and must
  not be gated by `volume?.compatibilityIssue` (it is not per-volume).

### 2. UI (`SourcesGUI/SnapshotManagementView.swift`)

Follow the existing view's patterns (toolbar `Button`s, `.confirmationDialog`, sheets); no new visual language.

- A **"Request Time Machine Snapshot…"** action, separate from the existing per-volume "Create Snapshot…" (which stays
  as is for the native/helper route). Disabled while `tmBusy` or in QA.
- **Confirmation dialog** that states the scope plainly:
  - macOS creates a Time Machine local snapshot of **every APFS volume included in Time Machine**, not just the selected
    volume;
  - **macOS chooses the names**; Storage Monitor only records the date token tmutil reports;
  - **Time Machine controls retention and deletion**; Storage Monitor will not delete or manage these snapshots;
  - it may take up to two minutes.
- If `create` throws `acknowledgementRequired`, show the previous uncertain/interrupted entry and offer a second
  confirmation that calls `create(acknowledgeUncertain: true)`. Never retry automatically.
- A **history list** (newest first): started/finished time, outcome, returned date token, exit code, and the bounded
  output on demand. Wording: "reported created" (not "created/owned"), "uncertain", "interrupted".
- Time Machine snapshots that appear in the existing APFS inventory must **not** become selectable for "Preview
  Deletion…"/retention as Storage Monitor-owned. Check how the inventory/ownership code (`SnapshotLifecycleEngine`,
  ownership quarantine) treats `com.apple.TimeMachine.*` snapshots and confirm they stay foreign/observation-only.

### 3. Tests

- Extend `tests/TimeMachineSnapshotTests.swift` only if the backend changes.
- Add model tests (fake `TimeMachineSnapshotCreating` runner, temp directory) to the snapshot model suite
  (`scripts/test-snapshot-model.sh` / `test-snapshot-management.sh`): QA never invokes the runner; busy flag;
  acknowledgement flow; error mapping; history reload after `interrupted` recovery.
- Check `scripts/test-gui.sh` invariants: it already asserts the viewer does not link UserNotifications and that
  `LiveCapacity.swift` launches no processes. The tmutil `Process` lives in `SourcesShared`, so the viewer now contains
  a process launch. Confirm no other guard forbids that; if one does, decide deliberately (and document) rather than
  weakening the guard.
- All tests must use fake runners. **No test may run the real `tmutil localsnapshot`.**

### 4. Docs (now contradict the code)

- `APFS-SNAPSHOT-MANAGEMENT.md:25` says "`tmutil localsnapshot` is not used". Rewrite: tmutil is the supported creation
  route for Time Machine local snapshots, with the scope/naming/retention limits above; the native helper route remains
  blocked pending an entitlement.
- `APFS-LOCAL-CAPABILITY-INVESTIGATION.md:82` lists tmutil only as a rejected alternative. Add that it was adopted, and
  why (works without a restricted entitlement; the trade-off is no ownership/naming/retention control).
- Release notes for the version that ships it.

### 5. Verification

- `scripts/test-time-machine-snapshots.sh`, the snapshot model/management suites and `scripts/test-gui.sh` pass.
- `scripts/build-gui.sh`, then exercise the real app: open Snapshot Management, check the dialog text, cancel path,
  QA mode (`isQA`) shows the action disabled, and the history list renders an empty state.
- **A real `tmutil localsnapshot` creates real snapshots on the user's volumes.** Run it once only with the user's
  explicit go-ahead, then confirm the history shows `reported created` with the token and that
  `tmutil listlocalsnapshots /` lists the same date. Do not delete it from Storage Monitor.

## Out of scope

- Deleting, thinning or mounting Time Machine snapshots; changing Time Machine settings.
- Any change to the native `fs_snapshot_*` helper route, entitlements or the privileged helper.
- Scheduling tmutil snapshots (no automatic lifecycle).
