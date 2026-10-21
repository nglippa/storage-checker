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
