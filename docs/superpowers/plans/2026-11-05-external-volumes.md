# External Volumes Implementation Plan

> **For agentic workers:** Execute task-by-task under the repository's bounded delegation policy. Use executing-plans with serialized writes; no commits are authorized.

**Goal:** Enable selected external SSDs/volumes to maintain separate indexes and capacity history, safely resuming across reconnects.

**Architecture:** A UUID registry resolves each selected volume to a mutable inventory dataset, immutable published catalog, and capacity-scope history database. Startup paths remain unchanged. A single dispatcher validates mounts and fairly alternates startup/external indexing; a native shared drive selection scopes both viewer sections.

**Tech Stack:** Swift 5/macOS 14+, Foundation/Darwin, SQLite, SwiftUI/AppKit, native disk metadata, existing shell build/test scripts.

**Spec:** `docs/superpowers/specs/2026-11-05-external-volumes-design.md`

## Global constraints

- No installed app, production/QA database, preserved QA snapshot, or production LaunchAgent changes.
- No desktop activation/input or full personal-volume scans. Native GUI checks require specific permission and remain NOT VERIFIED until exercised.
- No commits, pushes, installation, or release/version changes.
- External supported formats: APFS, HFS+, exFAT; chosen drives only; missing/conflicting UUIDs, network/images/system/backup targets are not eligible.
- Retain startup behavior and current 1,200-second inventory slice/retry budgets.
- SDK for viewer builds: `/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk`.
- Preserve existing cleanup-inspector edits in the original worktree; this branch starts at `c843fe0`.

## Review focus

- A path reused by a different mount cannot receive old scan commits or false deletions (Task 1/3 fixtures).
- Shared APFS volumes cannot duplicate history, thresholds or notifications (Task 4 fixtures).
- A failed publication or crash cannot mutate the offline catalog (Task 3 SQLite fixtures).
- A late response from a previously selected drive cannot populate either current viewer section (Task 5 model tests).
- A missed filesystem wake cannot strand durable settings/requests or create a relaunch loop (Task 4 queue tests).

## Task 1: Inventory root-validation barriers

**Files:** `Sources/Inventory.swift`; `tests/ExternalInventoryBoundaryTests.swift`; `scripts/test-external-inventory.sh`.
**Interface:** `InventoryRootValidationBoundary` (runStart, beforeRequestService, beforeListing/afterListing(relative:), beforeCommit(relative:), beforeFinalize); `InventoryRootValidationError` with disconnected/identityChanged/disabled reasons; `InventoryRootValidator`; optional `rootValidator` on `runInventory(..., rootValidator: InventoryRootValidator? = nil)`.

- [x] Add fixture tests that inject root loss at start, after a listing, before batch/group commits and finalization; assert retained committed nodes/job/token/prune state and a normal interrupted/offline result.
- [x] Run the dedicated test command and observe missing safeguards fail.
- [x] Add validation before root mutation, request consumption, reads, all destructive listing/flush transactions, final status, and watchdog blocked-state writes. Root loss must not enter per-directory unavailable/retry handling.
- [x] Run dedicated tests and the existing inventory suite. Expected: all pass with nil-validator startup behavior unchanged.

## Task 2: Identity, discovery and registry

**Files:** create focused `SourcesShared/ExternalVolume*.swift` model/registry/discovery files; `tests/ExternalVolumeTests.swift`; `scripts/test-external-volumes.sh`.
**Interfaces:** `ExternalVolumeDescriptor` describes canonical UUID/name/mount/device/filesystem/backing eligibility and capacity scope. `ExternalVolumeRegistry` serializes version-1 desired settings with revision and separate observations. `ExternalVolumePaths` derives validated UUID/scope-hash storage locations. `ExternalVolumeDiscovery` enumerates metadata without walking user files; backend verification may use bounded diskutil metadata but the GUI live-capacity path must remain in-process/read-only.

- [x] Test valid/invalid/conflicting/missing UUIDs, same-name/different-drive isolation, duplicate UUID rejection, hardware-fingerprint mismatch, shared APFS scope identity, non-ASCII display names and eligibility exclusions with injected metadata.
- [x] Test opt-in defaults, concurrent registry updates, corruption/unsupported versions, atomic replacement, per-target pause/disable revisions and dataset-key collision rejection on temporary files.
- [x] Implement only after observing missing behavior fail. Use CryptoKit SHA-256 and file locking/atomic JSON replacement; no arbitrary root/database paths in registry authority.
- [x] Run `scripts/test-external-volumes.sh`; expected all fixture tests pass and no real drive gets indexed.

## Task 3: External roots and immutable catalog publication

**Files:** `Sources/ExternalVolumeInventory.swift`, `Sources/ExternalCatalogPublication.swift`, `Sources/Coverage.swift` only for explicit generic-region support; external inventory tests.
**Interfaces:** `ExternalVolumeMountLease` validates a resolved UUID/mount/source/device/settings revision cheaply at Task 1 barriers. `ExternalCatalogPublisher` backs up committed SQLite into staged immutable snapshots and atomically publishes validated metadata. Reader and operational/request database paths remain distinct.

- [x] Test reconnect under a renamed path/device, root replacement, permission loss and absent mount without creating a fallback directory; nil startup validation remains unchanged.
- [x] Test actual SQLite backup isolation while a replacement work generation changes globally shared object/ownership rows. Verify old catalog byte values remain stable.
- [x] Test backup failure, low-space refusal, failed manifest replacement, stale revision, offline publication and crash recovery retain the old readable catalog.
- [x] Implement explicit external region creation with a verified filesystem boundary, private internal datasets, mount lease, publication and bounded snapshot retention.
- [x] Run Task 1–3 fixture tests and inventory tests; expected real-reader catalog totals survive injected failure/reconnect.

## Task 4: Capacity history, controls and fair dispatch

**Files:** `Sources/ExternalVolumeMonitoring.swift`, `Sources/ExternalVolumeDispatcher.swift`, `Sources/StorageMonitor.swift`, `Sources/InventoryCommands.swift`, shared request helpers, monitor fixture tests.
**Interfaces:** explicit target measurement returns existing `Reading` representation with a capacity-scope identity; dispatcher resolves registry authority before any work; `ExternalVolumeControl` writes target work requests plus a validated central dispatcher signal.

- [x] Test one APFS scope reading/notification for sibling volumes, independent non-APFS scopes, missing scope/invalid capacity rejection, and no startup swap/app attribution on external events.
- [x] Test reconnect after >75-minute gap establishes a change baseline while valid low-space alerts still work; disconnected targets never produce zero/free-loss readings.
- [x] Test startup/external round-robin with paused/offline/drained targets skipped, pending requests across wakes, revision cancellation and normal idle exit for an absent target.
- [x] Add external check/dispatch/control CLI routes and integrate the canonical check/worker entry points. Generate StartOnMount/registry watch settings without installing them. Keep target requests durable and signal the canonical mailbox.
- [x] Run fixture tests, monitor self-tests and inventory regression. Assert worktree build artifacts/temporary fixture paths are the only write destinations.

## Task 5: Drive selector and coherent viewer datasets

**Files:** `SourcesGUI/ExternalVolumeSelection.swift`, `SourcesGUI/ExternalVolumePicker.swift`, `StorageMonitorApp.swift`, `InventoryView.swift`, `LiveCapacity.swift`, `OverviewView.swift`, `HistoryView.swift`, relevant inspector/control views, GUI model tests.
**Interfaces:** root-owned `SelectedStorageTarget` resolves inventory-read/work paths, capacity database, mount status, identity and selection revision. Both sections consume this same context. Published catalogs are read-only; controls use work requests. Global helper/appearance settings stay global.

- [x] Add model tests for enable/disable/pause/reconnect, retained offline selection, shared history scope, async result rejection on rapid target switching and disabled live-mount actions.
- [x] Implement native selector/management controls, status copy and target-scoped overview/chart/history/inventory/search/inspector/refresh requests. Hide external cleanup plans and avoid internal attribution on external views.
- [x] Keep live probing in-process and validate mount UUID before/after statfs. An offline failure retains stale target data, never startup capacity.
- [x] Build with the specified SDK; run GUI and inventory-model suites. Native selector/opt-in/switching/offline/light/dark checks remain explicitly NOT VERIFIED until authorized and exercised.

## Task 6: Acceptance, review and delivery

**Files:** README/verification notes; new fixture harnesses; all changed implementation files.

- [x] Run external fixtures, inventory integration, monitor self-tests, GUI models, inventory models, native-QA isolation tests and build/configuration checks appropriate to changed paths. Save commands/outcomes in the progress ledger.
- [x] Review the complete working-tree diff independently using the middle role or a read-only cross-model reviewer; root verifies and fixes material findings with regression tests.
- [x] Confirm generated helper plist contains the new wake configuration but no installed runtime state was altered. Confirm original worktree edits remain intact.
- [x] Deliver source worktree, built development app and verification results; list native and physical external-drive checks still unverified. Do not install, commit, push or assign a release version.

## Execution record

Progress and rulings live in `docs/superpowers/plans/2026-11-05-external-volumes-progress.md`. Approval already authorizes execution; there is no second plan-approval checkpoint. Serialized middle/grunt delegation follows the user's policy, which supersedes generic fresh-agent/model instructions in imported skills.
