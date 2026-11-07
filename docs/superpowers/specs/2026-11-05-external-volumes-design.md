# External-volume monitoring and indexing

Date: 2026-11-05
Status: Approved by the user on 2026-11-05; implementation authorized.

## Intent and agreed behavior

Extend Storage Monitor so external local drives, including SSDs, can use both the storage browser and capacity history.

The user chose **discover connected drives, enable chosen drives, then resume automatically on reconnect**. Merely connecting a drive must not start indexing it. A chosen drive keeps its last index and history when disconnected, and continues in the same dataset when its persistent identity is recognized again.

The remaining details in this document are implementation proposals, not additional user decisions.

## Current implementation and constraints

- `Sources/StorageMonitor.swift:65–78`: capacity collection measures the APFS container backing `/` and requires its physical stores to be internal.
- `Sources/StorageMonitor.swift:368–421`: checks record capacity before collecting startup-volume attribution; default folder evidence is specific to the Mac. External checks must not reuse that attribution indiscriminately.
- `Sources/Coverage.swift:57–77,133–154`: path normalization and inventory regions are tied to the startup Data volume. Adding `/Volumes` to the startup walk would cross the intended filesystem boundary.
- `Sources/InventoryCommands.swift:244–273`: one inventory uses `history.sqlite3` inside a data directory; `--root` requires an isolated directory and currently still requires the startup Data filesystem.
- `Sources/InventoryCommands.swift:15–21`: the canonical inventory worker has one request mailbox, a bounded work budget, and restart-on-failure behavior. A missing external drive must not become a repeated failure/relaunch loop.
- `Sources/Inventory.swift:866–881`: active-generation reuse requires matching device/inode/birth metadata before considering UUID. The reuse path updates operational metadata but does not establish a general mount-path rebase.
- `SourcesShared/InventoryModels.swift:23–39`: public object identity already supports volume UUIDs.
- `SourcesShared/InventoryRequests.swift:40–70`: viewer requests are files beside the selected database; the viewer does not write inventory SQL.
- `SourcesGUI/StorageMonitorApp.swift:5–22` and `SourcesGUI/InventoryView.swift:10–13`: the viewer and inventory model currently start with one database configuration.

The working tree contains existing cleanup-inspector changes. They must be preserved. Repository `scripts/version.env` says 2.2.0 (10), while the installed viewer identifies as 2.3.0 (17); no release number is assigned by this design.

## Approaches considered

| Approach | Behavior and tradeoff |
| --- | --- |
| Chosen drives with automatic resume — selected by user | Discover eligible drives, explicitly enable each, then maintain it when connected. Avoids unexpected scans while retaining background monitoring. |
| Automatically enable every external drive | Less setup, but starts work on unfamiliar, backup, borrowed, or very large drives. Not selected. |
| Manual scans only | Simpler lifecycle, but does not provide the background monitoring and automatic resume requested. Not selected. |

For persistence, use **isolated per-volume datasets**. A single migrated multi-volume inventory schema would require changing many queries, request boundaries, and generation assumptions. Existing data-directory isolation is a smaller integration boundary. This choice still requires changes to discovery, capacity measurement, dispatch, and viewer configuration; the existing `--root` option alone is insufficient.

## Drive discovery and identity

Enumerate mounted volumes and inspect their filesystem and device metadata. Initial supported targets are mounted, readable, local physical external APFS, HFS+, and exFAT volumes. Treat this as a tested support matrix, not a promise that every filesystem has identical capabilities.

Exclude network filesystems, app distribution disk images, synthetic/system helper volumes, and Time Machine destinations from automatic eligibility. Offer an explanatory unavailable/unsupported state where useful. Do not decide whether a USB SSD is eligible solely from the removable-media flag; that flag is not equivalent to an external bus.

Use `URLResourceValues.volumeUUIDString`, with `diskutil info -plist`'s `VolumeUUID` as a corroborating/fallback source. Accept only a valid UUID, canonicalized using `UUID(uuidString:)` and its canonical `uuidString`. Conflicting non-nil identifiers are an error. Dataset keys are the lowercase SHA-256 digest of the canonical UUID, with the original UUID stored and checked inside dataset metadata. Names, `/Volumes/...` paths, and BSD device numbers are current observations and display metadata. Resolve them again on each wake and before opening a scan root. A renamed drive or a mount-path suffix must not create a different dataset.

Missing persistent identity prevents enabling automatic monitoring in this iteration; report Unsupported identity rather than guessing. Multiple mounted volumes claiming the same identity must block unattended resume and display a specific explanation. Do not resolve ambiguity by name or mount path. A reformatted volume with a new identity is a new target.

Identity validation resolves the mounted source through `diskutil info`, verifies the expected filesystem UUID, local/physical/external backing, mount root and `st_dev`, and records the backing partition/store UUIDs when available. Use stable backing UUIDs, not the transient BSD device number, for compatibility checks against the saved enrollment fingerprint. A changed known fingerprint requires explicit re-enrollment. A missing fingerprint remains explicitly unknown, not proof that hardware matches; byte-identical clones carrying the same filesystem and backing identities cannot be distinguished by those identifiers alone. Tests must cover detectable collisions and not claim a universal hardware identity guarantee.

External APFS volumes can share container capacity. Define a capacity-scope key `apfs:<container UUID>`; for HFS+/exFAT use `filesystem:<volume UUID>`. Each selected volume has its own inventory dataset but resolves history to its capacity scope. Measure/store a shared APFS container once per check and keep one alert state for that scope; sibling volumes do not duplicate readings or notifications. Label the header and history as shared container capacity and show volume allocation separately. Never sum shared free space as if each volume owned it independently.

Apple references: [mounted volumes](https://developer.apple.com/documentation/foundation/filemanager/mountedvolumeurls(includingresourcevaluesforkeys:options:)), [persistent volume UUID](https://developer.apple.com/documentation/foundation/urlresourcevalues/volumeuuidstring), and [URL resource keys](https://developer.apple.com/documentation/foundation/urlresourcekey), including `volumeIsInternalKey`.

## Persistence and control

Keep the existing startup database and its paths unchanged. Store external datasets on the internal disk under a dedicated private directory:

```text
<application-data>/external-volumes/
  registry.json
  volumes/<volume-identity-derived-key>/
    history.sqlite3           # this volume's inventory tables
    inventory-requests/
    inventory.cancel
    catalogs/<snapshot-id>.sqlite3  # immutable published inventory snapshots
  capacity-scopes/<scope-identity-derived-key>/
    history.sqlite3           # this capacity scope's readings and alert state
```

Derive scope directory keys by hashing the validated canonical scope string, never raw drive names or arbitrary config path strings. Registry version 1 stores canonical volume UUID, enabled and indexing-paused flags, display name, enrollment fingerprint and a monotonic settings revision. Desired-settings updates use a dedicated `flock` lock, re-read/merge under the lock, atomic replacement and private file/directory permissions. Two updates to the same setting use lock order; unrelated target updates are merged. Unsupported versions or malformed registry data stop external work and surface a configuration error; they never enable all drives. Atomic replacement leaves either the prior complete registry or the new complete registry after a crash.

Workers never rewrite desired settings. Persist observed mount identity, last-seen time, status and publication metadata separately. Re-read the relevant settings revision before starting each slice and before publishing results or notifications. Disable stops this target's sampling and indexing; Pause indexing stops only its indexing and preserves capacity monitoring. Obsolete work cannot publish after the corresponding disable/pause. A shared APFS capacity scope continues while at least one enrolled member remains enabled. Startup mode continues using the same database for both inventory and history; external configuration carries inventory-work, inventory-read, and capacity database paths explicitly.

After persisting any external Refresh/Pause/Resume request in the target's work mailbox, atomically publish a uniquely named dispatcher-signal file in the canonical startup `inventory-requests` mailbox already watched by the inventory agent. The signal contains only validated target identity and settings revision; the dispatcher re-resolves registry authority before consuming target work. Do not add an arbitrary database/root path to a trusted signal. Registry and periodic reconciliation recover a missed signal, so signaling is a prompt wake mechanism rather than the only record of work.

The GUI enables/disables targets through the configuration/request layer, and continues opening history and inventory databases read-only. No database or hidden files are written onto the external drive. Disabling monitoring stops new work and retains existing history. Permanent history deletion is outside this update.

## Capacity monitoring and background dispatch

Generalize the measurement boundary to an explicit validated target. Preserve current internal APFS measurements. External APFS measurements retain container-level capacity and volume allocation metadata; other supported filesystems record filesystem capacity without inventing APFS roles or contributors.

Record history and alert state in the selected target's capacity-scope dataset. Baselines and deltas must stay within that scope's identity. A disconnected or locked drive has no fresh reading; never record zero capacity, a storage-loss event, or a successful scan to stand in for absence. Reconnect establishes a fresh observation and explicitly marks any gap in coverage. After an offline interval beyond the existing 75-minute chart gap, the first new reading is a new change baseline; do not issue change/rate alerts spanning that gap. Current low-space thresholds may still alert from a valid current reading. Existing internal history and alert semantics stay unchanged.

Keep the existing half-hour capacity cadence. In generated helper configuration, use `StartOnMount` on the canonical capacity-check job and watch the registry for enrollment/settings changes. Each permitted check discovers mounted targets, samples enabled capacity scopes, then wakes the canonical inventory dispatcher. This operates with the viewer closed. The running dispatcher also reconciles the mount catalog between slices, so a mount coalesced while it was active is not lost. GUI mount notifications refresh presentation but are not the background resume mechanism. Startup/login and wake checks reconcile current state rather than assuming every transient event was delivered.

Use one controlled dispatcher with a global inventory lock and at most one active inventory scan. Keep the current verified 1,200-second maximum slice budget and existing entry/retry limits; do not shorten them arbitrarily, because current scheduling comments document that short slices can prevent a directory reaching its retry boundary. Schedule one startup slice, then one enabled external volume in persistent round-robin order, then repeat. Drained/paused/offline targets do not consume a work slice. Capacity sampling runs independently of the inventory lock, preserving its schedule while a disk is slow. Coalesce repeated target refresh/mount requests but retain the latest pending settings revision. Respect existing launchd throttling. Do not add a dynamic production LaunchAgent per disk.

Extend helper/installer configuration in code, but do not apply it to installed production agents during development. An offline target is a normal idle outcome, not a failing process eligible for endless relaunch. Preserve explicit per-target Pause indexing state across reconnects; only previously enabled, unpaused indexes resume automatically, while enabled capacity monitoring continues when connected.

External history records actual capacity observations. It must not attribute changes to startup swap, startup app caches, or internal Data-volume activity. Reuse the existing low-space/change evaluation policy with independent **capacity-scope** alert state. For APFS this is one container baseline/acknowledgment/deduplication identity shared by enrolled sibling volumes; for HFS+/exFAT it is one volume. Notifications name the drive, or the sorted enrolled volume names followed by “shared APFS container” for a shared scope. Sample, evaluate, and notify once per scope per check. The helper's notification permission remains global. Disconnection is not a low-space alert, and reconnect must not compare readings from different scope identities.

## Index lifecycle and unplug safety

Add a general external filesystem region rather than weakening the existing startup-region checks. The region binds a verified volume identity, mounted root, filesystem boundary, and current device metadata. Never follow nested mounts or symlinks onto another filesystem. Preserve existing observational I/O, permission reporting, and resource budgets where supported.

Validate identity when work starts and at directory/commit boundaries. On unmount, permission loss, or a mismatched replacement at the same path, stop scheduling reads, cancel that target's work, and reject results that no longer belong to the verified target. Do not create a replacement mount directory, traverse the underlying startup filesystem, or mark disappeared content deleted merely because the drive went offline.

Dataset and history continuity are required; retaining a particular inventory generation across remounts is not. The first implementation retains the previous catalog as last-known data and starts a fresh working generation when device or root metadata changes. **A generation pointer alone is insufficient:** current `inventory_objects` and ownership are shared across generations (`Sources/Inventory.swift:265–280,883–890`), so a new build can change old-generation values.

Use an immutable database snapshot for each published external catalog, created with SQLite's backup API from a consistent committed work database. Do not copy a live SQLite file with plain filesystem copying. External publication metadata records a validated snapshot basename, volume UUID, source generation, measurement time, completeness, and settings revision. While a replacement builds in the mutable work database, normal browsing remains pinned to the previous snapshot and labelled stale; progress reads the work database separately. First-ever indexing may show clearly labelled partial committed work, and an offline partial catalog can be frozen without claiming completion.

When a replacement reaches its truthful terminal complete-or-partial state, close the writer for that publication step, create/validate a private staged backup, and revalidate volume identity and settings revision. Atomically replace the publication manifest only after the backup is complete and readable. Open published snapshots read-only and never mutate their objects/ownership. A crash or failed/disconnected rebuild leaves the old manifest and snapshot valid. Garbage collection may remove unreferenced snapshots only after the publication succeeds and readers have released them; keep at most the current and previous published snapshots plus the working/staging files. Check internal free-space/resource budgets before snapshot publication and pause on insufficient space without destroying the prior catalog.

Read paths and request paths are intentionally different: target controls always enqueue against the mutable work database/mailbox, including its current request boundary, never against a stale published snapshot. Reusing a working generation after device/path changes is allowed only after a separately verified rebase and reconciliation. Tests must establish snapshot isolation and publication recovery rather than assuming existing active-generation handling provides them.

FSEvents support is capability-dependent. Where reliable replay is available, maintain a cursor specific to that volume and reconcile after an actual coverage gap. Where unavailable, use explicitly bounded scheduled/manual reconciliation and say so; do not claim continuous change coverage.

## Viewer behavior

Add a native drive selector shared by Storage and History & Monitoring. Startup storage remains the default. List known chosen drives even while disconnected, and offer a compact connected-drive management flow with an explicit Enable action for new eligible drives.

Own a single `SelectedStorageTarget` state at the viewer root and pass its resolved inventory identity/read path/work path and capacity scope/path to both sections. Startup is the initial selection on launch; switching sections preserves the selected target. Changing targets increments a selection revision, clears target-specific selection/inspector state, and cancels old model tasks. Every asynchronous result must match both target identity and selection revision before reaching the UI. A disconnect keeps the chosen target selected and transitions it to offline browsing, rather than silently switching back to startup storage.

The selected drive scopes the storage overview, tree/Atlas, rankings, search, inspector, requests, capacity chart, and event history. Never combine an external catalog with the startup capacity header or history.

Show Connected, Indexing, Paused, Disconnected, Permission required, or Unsupported as appropriate. Offline browsing shows last measured time and stale data; disable actions requiring a live mount. Global background-helper installation and appearance settings remain global. Refresh, Pause, Resume, and indexing progress apply to the selected target.

Preserve the existing native design and accessibility labels in light and dark mode. Drive names must be treated as display strings, including long names, duplicate names, and non-ASCII characters.

External cleanup suggestions and cleanup plans are excluded from the initial release. Do not expose startup-specific cleanup assumptions on an external dataset. Storage inspection and Finder reveal are available only when the target is connected and the path is revalidated.

## Acceptance and verification

1. Enabling one eligible SSD creates only its isolated internal dataset. Other attached drives remain untouched.
2. The same selected target scopes both storage browsing and monitoring/history; rapid switching cannot display results from another dataset.
3. Unplugging during enumeration, replay, or a commit leaves readable retained data, no false deletions or zero-capacity events, and no restart loop.
4. Reconnect under a different BSD device, name, or mount path continues the same dataset/history and resumes only if enabled and unpaused.
5. Reformatting, duplicate UUIDs, or replacing a mount with another disk cannot reuse the wrong catalog.
6. APFS sibling volumes label shared capacity correctly. HFS+/exFAT tests do not claim APFS attribution or unsupported FSEvents guarantees.
7. Permission denial, read-only volumes, absent volumes at login, sleep/wake, and viewer-closed reconnects have truthful states.
8. Internal inventory/history, startup coverage exclusions, existing alert behavior, QA isolation, and cleanup-inspector changes remain intact.

Use deterministic discovery/measurement fixtures, isolated SQLite datasets, injected mount events, and bounded temporary filesystem fixtures. Extend monitor self-tests, inventory integration/reconciliation tests, GUI model tests, and packaging configuration checks. The phase plan must name tests for conflicting/duplicate UUIDs, identity-key collision rejection, registry crash/concurrent updates, shared-container notification deduplication, dispatcher round-robin order, reconnect/unmount at commit, retained publication after rebuild failure, and obsolete GUI-response rejection. Real filesystem mount tests use disposable images and `hdiutil attach -nobrowse` only where permissions permit. Do not scan an attached personal SSD or touch production/QA databases.

Native GUI flow verification remains required before release but must obey repository `AGENTS.md`: no application activation, keyboard/mouse input, window changes, or installed-app launch without specific authorization. If unavailable, list the drive selector, opt-in flow, live switching, offline view, and light/dark checks as **NOT VERIFIED**. Do not weaken this requirement.

## Delivery boundaries

Implement on an isolated feature branch/worktree so the existing dirty worktree is preserved. No commits, pushes, installation, production helper restarts, full personal-volume scans, or release/version changes are authorized by this design review. Confirm the current release baseline and bundled helper compatibility before assigning a version or packaging a distributable candidate.

After design approval, write the implementation plan with explicit phases for identity/discovery, isolated persistence and measurement, lifecycle/dispatch, viewer integration, and regression/fixture verification.
