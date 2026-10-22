# File-growth attribution: audit, design, and limits

This document covers how Storage Monitor connects a storage change to folders, file activity, and processes, and where that evidence stops.

## 1. Architecture audit (before this change)

| Area | What exists |
|---|---|
| Scheduling | A per-user LaunchAgent runs `StorageMonitor check` at login and at :00/:30. Each run is a short-lived process. Missed runs during sleep are coalesced by launchd. A `flock` prevents overlapping runs. Nothing stays resident between checks. |
| Readings | `readings` table: container UUID, free/used bytes, and the complete APFS volume list (from an untruncated `diskutil apfs list -plist`). One row per check. |
| Diagnostic snapshots | `diagnostics` table, JSON. Schema 2: swap and VM via sysctl/Mach, APFS reused from the reading, and bounded walks of eight fixed folders. These are collected **only when a new growth alert starts**, so most intervals have none and two snapshots rarely bracket one interval. |
| Directory measurement | `measureDirectory` walks one tree in-process, without following symlinks or crossing volumes, with time and entry caps. It records logical and allocated bytes, and permission refusals as counts. |
| Event association | The viewer attaches alerts and diagnostics to a reading by exact timestamp. Volume changes compare a reading with the previous reading of the same container. |
| Process observation | None. |
| Permissions | Runs as the user, unsandboxed, without Full Disk Access. Reads under `~/Library/Caches` and `~/Library/Application Support` partly fail by design (TCC). App containers and browser profiles are not read. |

### Limitations of that design

- Folder sizes were measured only at alert time, so there was almost never a matching measurement at the start of a loss interval. The existing snapshot can only say what a folder's size is, not that it grew during the event.
- Nothing recorded which files changed.
- Nothing linked processes to storage.

## 2. Folder growth

**Roots.** Defaults, used only when present and not symlinks: `~/.cache`, `~/.codex`, `~/.local/share`, `~/Library/Caches`, `~/Library/Application Support/{Claude,Code,Cursor}`, `~/.npm`, and `~/Library/Developer/Xcode/DerivedData`. Project build or temporary folders can be added in `<data dir>/monitored-roots.json`:

```json
{ "roots": [ { "path": "/Users/me/projects/app/build", "label": "app build" } ] }
```

Extra roots must be absolute paths inside the home folder. A root nested inside another root, or containing one, is rejected so nothing is counted twice. There are at most 16 extra roots. Nothing discovers projects by scanning.

**Granularity.** Each root's immediate entries (its "children") are the unit of measurement. Children of one root are disjoint, and roots are disjoint, so no byte is counted twice.

**Matching intervals.** Every check stores a baseline: each child's logical and allocated size, file count, completeness, and the last reading it is known to be valid for. A change is reported only when the child's baseline is valid **at the immediately previous reading** and both measurements are complete. A first measurement is only a baseline; growth is never inferred from a single snapshot.

**Incremental cost.** Walking all default roots takes about 15 s (about 480,000 entries on this Mac). To stay lightweight, a check re-measures only children with file activity since the previous reading (see §3), new or removed children, children still pending, and a few children per check whose measurement is over 6 hours old (drift protection). The rest carry forward. Carrying forward is allowed only when file-event history covered the whole interval without a gap. If there is a gap, the affected roots are re-measured in full, up to a 25-second budget. Children not reached stay pending and are marked not comparable instead of being guessed.

**Units.** Logical size (`fileSize`) and allocated size (`totalFileAllocatedSize`) are both stored. Neither is APFS physical allocation: clones share blocks, compression and sparse files shrink allocation, and snapshots retain freed blocks. Folder growth is never added into, or subtracted from, the APFS totals as if it were the same quantity. The inspector's "unattributed remainder" is labelled as an estimate.

## 3. File-change evidence (FSEvents)

A resident watcher is **not** used. Instead, each check records the FSEvents event ID at the moment of the reading, and the next check replays FSEvents history between the two IDs for the monitored roots. This uses `FSEventStreamCreate` with `sinceWhen` and file-level events, stops at `HistoryDone`, and ignores events after the second ID. fseventsd keeps this history across process exits and reboots, so a one-shot LaunchAgent gets complete coverage of each reading interval without running between checks.

Recorded per interval, with no file contents read:

- Counts per child: created, modified, removed, renamed, cloned, and total events.
- The number of distinct paths (counting stops at 50,000).
- Up to 5 sample paths per child, and 15 in total.
- The first and last event IDs, and the volume's FSEvents database UUID.

**Gap detection.** The interval is marked as having a gap, and nothing is carried forward for the affected roots, when:

- there is no event marker from the previous reading;
- the previous marker belongs to a different FSEvents database (volume UUID changed);
- events carry `MustScanSubDirs`, `UserDropped`, `KernelDropped`, `EventIdsWrapped`, or `RootChanged`;
- `HistoryDone` does not arrive within 10 s;
- more than 200,000 events arrive (the cap).

**Limits.** fseventsd may purge old history, especially when the disk is nearly full. There is no reliable way to detect that a purged span was skipped other than the flags above. Events are coalesced by fseventsd, so counts are lower bounds on activity and are not byte amounts. FSEvents never identifies which process wrote a file.

## 4. Process attribution

| Level | Meaning | Available here |
|---|---|---|
| Confirmed process attribution | A specific process is proven to have allocated the bytes. | **No.** This needs Endpoint Security (entitlement and root) or `fs_usage`/DTrace (root). It is not used, and nothing in the UI uses this label. |
| Process correlation | At the end of the interval, a same-user process had files **open for writing** inside a folder that grew. Its total disk-write bytes during the interval (`proc_pid_rusage`, all destinations) are shown alongside when it was alive at both readings. | Yes (`proc_pidinfo` and `proc_pidfdinfo` on same-user processes, read-only). |
| Folder growth without process attribution | A folder grew and no process is linked to it. | Yes. |
| Unknown | No folder or process evidence. | Yes. |

A process is never named because it is present, because of its executable name, or because it wrote a lot during the interval. It is named only if it held a writable file inside a grown folder. Even then the inspector says the link is to the folder, not to the APFS allocation. Processes that wrote and closed files before the check, short-lived tools, and other users' processes are not seen.

## 5. Bounds and safety

- **Budgets.** 25 s for folders, 10 s for event replay, 3 s and 50,000 file-descriptor queries for processes. All work runs after the reading, alerts and notification are committed. Any failure is recorded and never fails the check.
- **Storage.** One `interval_evidence` row per reading. Rows are capped at about 24 KB (typically 2–6 KB), follow the 30-day and 10,000-reading retention, and are deleted with their reading. Baselines live in the existing `state` table, overwritten on each check. The schema change is additive: `CREATE TABLE IF NOT EXISTS interval_evidence`.
- **Never done.** Reading file contents, writing anywhere except the monitor's own database, following symlinks, crossing volumes, sending signals to other processes, network access, requesting privileges, or uploading anything.

## 6. Baseline initialization (audit, 2026-10-21)

**What the code did.** The baseline lived in one `state` row (`attribution_baseline`). Each subfolder stored its sizes, `complete`, `status`, `measuredAt`, `validThrough` (the reading it describes) and `pending`, under a single FSEvents marker taken at the last reading. Only the scheduled check wrote it, within a 25-second budget. Carrying a folder forward needed that one marker, so a value measured between readings could never be trusted. Pending, timed-out and permission-refused folders were retried at every check, indefinitely.

**What production showed** (readings #18–#26, read-only copy):

| Reading | Measured | Carried forward | Pending | Not comparable |
|---|---|---|---|---|
| #18 | 115 | — | 231 | — |
| #19 | 242 | 106 | — | 233 |
| #20 onward | 33 → 1 | 313 → 334 | — | 9 → 1 |

- At #18 the 25-second budget ran out after 115 of 346 subfolders.
- Of the 233 not comparable at #19, 213 were first measurements labelled "Not measured at the previous reading".
- From #20 on, the remaining work was the same 9 permission-protected Caches folders and one large cache, retried every check.
- Readings #23–#26 reported 7–17-minute durations. These were DarkWake runs on battery during which the Mac went back to sleep about two seconds in. Durations are wall-clock time; budgets are wall-clock deadlines, so sleep ends a run early (which is safe).

**Design.**

- **Per-folder validity.** Each folder stores the FSEvents ID and wall time taken immediately before its own walk (`validEvent`, `validAt`). A later check trusts the value only if FSEvents history shows no activity in that folder after `validEvent`. The replay window reaches back to the oldest trusted folder, and markers older than 6 hours are never trusted. Interval statistics still count only events after the previous reading. Folders measured at different times therefore form one baseline without a fabricated shared timestamp. A change is still reported only against a value valid at the immediately previous reading. Initializer values use an unmatched sentinel, so they are never compared as if they described a reading.
- **Initializer.** The LaunchAgent `local.macbook.storage-monitor.baseline` runs `StorageMonitor initialize-baseline`. Its settings: `RunAtLoad`, `KeepAlive` only on failure, `ThrottleInterval` 300, background process type, low-priority I/O, nice 15.
  - **Workers and locking.** One worker at a time (`initializer.lock`). It measures in 8-second slices under `attribution.lock`, checkpointing the baseline after every slice, and pauses between slices. In Low Power Mode it uses 4-second slices and 5-second pauses.
  - **Changes during initialization.** Folders with file activity after their walk are re-measured, in up to 3 reconciliation rounds. Anything still changing afterwards keeps a marker that predates the change, so the next scheduled check sees the activity and re-measures it rather than trusting it.
  - **Exit behavior.** It exits 0 at a terminal state. It exits 75 at its 30-minute cap or if the lock stays busy, so launchd resumes it later. The scheduled check wakes it (`launchctl kickstart`) while coverage is not initialized.
  - **What it never touches.** Readings, alerts, interval evidence and notifications.
- **Bounded retries.** A folder macOS refuses to open is *unavailable* and retried daily. A folder that stops at its time limit three times is *incomplete* and retried every 6 hours. Neither is ever counted as baselined or unchanged.
- **Coverage.** Stored as `state.attribution_lifecycle` with counts for discovered, baselined, pending, incomplete, unavailable and comparable-for-the-next-interval. States: `not_initialized`, `initializing`, `ready`, `partial`, `degraded` (a file-history gap after the baseline existed). The viewer shows it on one overview line. Each event keeps showing its own interval's evidence, with first measurements reported separately from folders that could not be compared.
- **Scheduled check.** The 25-second budget and APFS path are unchanged. It waits at most 45 s for the baseline lock and otherwise records "folder evidence skipped" for that reading.

**Measured on this Mac** (scratch databases; the real monitored folders; launched from Terminal, so macOS-protected Caches folders were readable — under launchd they would be reported as unavailable):

| Run | Result | Time | Walks | Peak memory |
|---|---|---|---|---|
| Fresh | 348 discovered, 348 baselined, ready | 85.4 s (Low Power Mode pacing) | 355 (7 reconciliations) | 15 MB |
| Killed with SIGKILL after 15 s, then resumed | 103 checkpointed; resume measured only the remaining 245 | 29.8 s at background priority | 246 | 17 MB |
| Upgrade from a production copy | 9 measurements to ready; readings, alerts, diagnostics and evidence byte-identical | 5.9 s | 9 | 14 MB |
| First scheduled-style check after initialization | 344 trusted without re-walking, 4 re-measured, 0 false growth | 3.3 s | 4 | — |
| Next check | complete: 346 carried, 2 measured | 3.1 s | 2 | — |

## 7. Comprehensive filesystem coverage (Phase 1, 2026-10-21)

The predefined folders in §2 covered about 350 subfolders of the home folder. Coverage now extends to the whole startup Data volume (`Sources/Coverage.swift`). The predefined-folder engine remains in place. It produces evidence until comprehensive coverage is established, and again whenever `<data dir>/coverage.json` contains `{"mode":"folders"}`.

### What is covered

| Region | How it is covered |
|---|---|
| Data volume (`/System/Volumes/Data`): `/Users`, `/Applications`, `/Library`, `/private` (`var`, `tmp`, `etc`), `/opt`, `/usr/local`, Homebrew, hidden folders, caches, VM images, model stores, everything else on it | Walked and tracked with file events |
| Sealed system volume (`/System`, `/bin`, `/usr`) | Not walked. It is read-only and sealed, changes only through macOS updates, and its size is the APFS *System* volume figure. |
| VM, Preboot, Update, Recovery volumes | Not walked. They keep no file-event history. Swap is measured through `vm.swapusage`, and every volume through APFS `CapacityInUse`. |
| Other filesystems mounted inside the Data volume (`/Volumes/*`, autofs `/home`, disk images) | Never entered. Recorded as *excluded*, with the filesystem type. |

**Path identity.** Every path is keyed relative to the Data volume. Firmlinks (`/usr/share/firmlinks`) map `/Users/x` and `/System/Volumes/Data/Users/x` to the same key `Users/x`. File events come from one device-relative FSEvents stream, which reports those same keys. Symlinks are never followed (`fts` with `FTS_PHYSICAL`), and walks never cross a device boundary (`FTS_XDEV` plus an `st_dev` check).

### Partition

The volume is divided into **units**: directories measured as one aggregate. The first walk of a unit stops after 20,000 entries. A unit that large becomes a *split* unit: its own files are measured directly, and each subdirectory becomes a unit of its own. The partition therefore follows where files are.

On this Mac it produced 11,900 units, at most 12 levels deep. That is 11,694 measured units, 188 inaccessible and 21 excluded.

- **Limits.** At most 60,000 units and 32 levels. Beyond that, a unit is walked whole, up to 2 million entries.
- **Units are disjoint.** A unit's own measurement skips every unit nested inside it, so no byte is counted twice. An ancestor's total (`agg_*` columns) is its own files plus its child units.
- **Holes.** Directories that cannot be measured are units too, and they never disappear from the model:
  - *inaccessible*: `permissions` (POSIX), `privacy` (TCC or SIP), or `consent` (deliberately not opened);
  - *excluded*: another filesystem, or a cloud placeholder (`SF_DATALESS`).
- **Bounded state.** The `coverage_units` table holds about 12,000 rows (3.7 MB here). The full table is loaded into memory per run (bounded by the unit cap); there is never a per-file in-memory graph.

### What a measurement means

Each unit records:

- **Logical size:** `st_size` of its regular files.
- **Allocation:** `st_blocks × 512`, which covers the data fork only.
- **Counts:** files and entries.

Hard-linked files are counted once per walk. None of these figures is APFS physical allocation:

- APFS clones and shared extents are counted once per file.
- Compressed and sparse files report their allocated blocks.
- Snapshots, purgeable space and open-but-deleted files are invisible to a walk.

On this Mac the sum over all files was 484 GB, while the Data volume reported 418 GB in use.

The evidence therefore keeps five separate quantities and never forces them to agree:

1. container free space;
2. APFS volume allocation;
3. measured unit growth or reduction;
4. file-event activity;
5. process correlation.

### Initialization

The existing background job (`local.macbook.storage-monitor.baseline`, which runs `initialize-baseline`) now builds comprehensive coverage. It works in 8-second slices under `attribution.lock`, with throttled I/O, no access-time updates (`IOPOL_ATIME_UPDATES_OFF`), and no downloading of cloud placeholders (`IOPOL_MATERIALIZE_DATALESS_FILES_OFF`).

- **Checkpoints.** Each slice saves changed units in transactions of at most 1,000 rows, so the job resumes where it stopped.
- **Changes during initialization.** Units that changed while it ran are re-measured, in up to 3 rounds.
- **Exit behavior.** It exits at a terminal state: *ready*, or *partial* when anything is inaccessible or deferred. At its 30-minute cap it exits 75, and launchd resumes it.
- **Retries.** Protected units are retried daily. Consent-gated units are retried as soon as Full Disk Access is granted. Units that time out three times become *deferred* and are retried every 6 hours.

### Scheduled checks

1. **Replay.** FSEvents history is replayed from the oldest trusted unit marker. The durable cursor is the `coverage_cursor` state key, plus each unit's own `valid_event`.
2. **Trust.** A unit is trusted, and carried forward, only when all of these hold:
   - history is continuous;
   - its marker is less than 6 hours old;
   - it has no events after its own measurement;
   - no `MustScanSubDirs` event covers it.
3. **Re-measure.** Changed units are re-measured within the existing 25-second budget, those with the most events first. A single unit walk is capped at 80,000 entries. A unit that outgrows the cap is flagged for the background job to split.
4. **Defer.** Work not reached within the budget is marked *pending* and kicks the background job.
5. **Gaps.** Dropped events, ID wrap, `RootChanged`, an unfinished replay or a different FSEvents database UUID count as a gap. After a gap nothing is carried forward. Units are re-measured within the budget, or marked *reconcile* for the background job, and coverage is reported as *degraded* until that reconciliation finishes.

### Interval evidence

`folders.status` and `coverage.level` describe one interval:

- `baseline_only`: the first comprehensive reading;
- `comprehensive`: every accessible unit was compared;
- `partial`: some units could not be compared, and they are listed.

A change is reported only against a value valid at the immediately previous reading.

- **Not growth:**
  - first measurements, including folders that just became readable;
  - units re-measured between readings;
  - re-partitioned units.
- **New:** a directory created during the interval under a listing that was current at the previous reading.
- **Directory renames:** matched by directory inode. The unit keeps its identity and is reported as `moved`.
- **File moves between units:** paired as `moved_out` / `moved_in`. This needs the same file name in both units' rename events and sizes within 1%. Similar sizes alone are not evidence.
- **Concentration:** the deepest directory holding at least 75% of measured growth or reduction. It is never the volume root, and it excludes moves. This produces statements like "Approximately 1.8 GB of measured growth occurred under ~/Library/Caches." When nothing comparable changed, the viewer says the filesystem evidence does not explain the change.
- **Inaccessible activity:** events inside holes are counted, so they can explain why a change was not measured.
- **Open-but-deleted files:** for same-user processes, `proc_pidfdinfo` reports files with `nlink == 0` on the Data volume, with their allocated bytes.

### Permissions

The background monitor runs as the user. It never requests privileges and never bypasses TCC or SIP.

Full Disk Access is detected by opening, never reading, `~/Library/Mail`, `~/Library/Safari` or `/Library/Application Support/com.apple.TCC`.

**Without Full Disk Access**, the folders below are recorded as inaccessible (`consent`) and **never opened**:

- Desktop, Documents, Downloads, Pictures, Music, Movies;
- iCloud Drive and CloudStorage;
- app containers and group containers;
- every `~/Library` folder except Caches, Developer, Logs and Application Support;
- inside Application Support, everything except folders this monitor's own predefined-folder baseline shows it already reads completely. Without such evidence, Application Support is not even listed.

The reason, measured on macOS 27 with launchd test jobs:

1. Opening Chrome's Application Support produced a user-visible "App Data" notification, and a media-library consent prompt followed. The walk blocked until the prompt was answered.
2. A second run stalled inside Application Support with no new prompt logged.

Prompts happen inside `open()` and cannot be checked in advance.

**Stall watchdog.** If a unit's walk does not return within its time limit plus 60 seconds, a watchdog thread updates that unit through a separate database connection and ends the process with exit code 75:

- a recursive unit is divided, so its subfolders are tried one by one on the next run and repeated stalls converge on the folder that blocks;
- a unit whose own listing blocks becomes `blocked` (inaccessible, retried daily).

In a launchd test, `~/Library` stalled once and was divided. The reading is committed before evidence collection, launchd resumes the background job, and the next run skips that unit. A blocked `open()` therefore cannot hold the locks and silently stop monitoring.

**With Full Disk Access**, nothing is gated. Root-only and SIP-protected folders (`/private/var/db/*`, `.Spotlight-V100`, `.fseventsd` and similar) stay inaccessible either way.

`bin/storage-monitor coverage-status [--units [state]]` lists every unit, with its state and reason.

### History

- **Schema.** The schema change is additive: `CREATE TABLE IF NOT EXISTS coverage_units`, `coverage_epochs`. Existing readings, alerts, diagnostics, interval evidence and folder baselines are not rewritten. A copy of production history was migrated, and all five existing tables were byte-identical afterwards.
- **Epochs.** `coverage_epochs` records the reading at which comprehensive coverage began, and later scope changes.
- **Older rows.** Rows without a `coverage` block are predefined-folder intervals, and the viewer labels them that way.

### Measured on this Mac (Mac mini M4 Pro, 24 GB; Data volume 418 GB in use, 3.06 M entries)

| Run | Result | Time | Peak memory |
|---|---|---|---|
| Full initialization (terminal, Full Disk Access present) | 11,903 units: 11,694 measured, 188 inaccessible, 21 excluded; 11,771 walks, 60 reconciliations | 155 s | 56 MB footprint |
| First comprehensive check | Baseline only; 11,658 carried, 36 re-measured | 1.3 s | 39 MB |
| Check about 15 minutes later | Comprehensive; 2,402 events, 76 re-measured, 11,618 carried, 10 changes; 18 KB evidence row | 4.0 s | 42 MB |

The table above was measured with Full Disk Access (launched from Terminal). As a launchd background job without Full Disk Access, initialization measured 8,828 areas in 291 s (39 MB peak), and checks took 2.2 s and 3.4 s. See VERIFICATION.md.

### Limits

- **Not seen:**
  - files written and deleted within one interval;
  - snapshot-retained blocks;
  - purgeable space;
  - the sealed system volume;
  - other users' and root processes' open files.
- **Without Full Disk Access**, most of `~/Library` and the media and document folders are not measured.
- **Interpretation.** Measured growth is file data, not physical allocation; the unattributed remainder is an estimate. FSEvents coalesces events and never names the writing process.
- **Long gaps.** A marker older than 6 hours, for example after a long sleep, forces a background re-walk before units are trusted again (about 2.5 minutes here).
