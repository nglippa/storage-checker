> **License:** Storage Monitor's original code is proprietary; all rights reserved. Public repository access does not grant a general reuse or commercial distribution license. See [LICENSE](LICENSE), [commercial licensing](COMMERCIAL-LICENSING.md), and [third-party notices](THIRD-PARTY-NOTICES.md). The [EULA draft](EULA-DRAFT.md) is not operative customer terms.

# MacBook Storage Monitor

A local, native universal macOS utility that checks the internal APFS container and chosen external drives at login and every half hour (`:00` and `:30`). No Terminal window needs to stay open. launchd coalesces calendar checks missed during sleep into a check after waking. Monitoring starts after the user logs in; a logged-out user does not have an active LaunchAgent.

## Version 3.0.0

[Download Storage Monitor 3.0.0](https://github.com/nglippa/storage-checker/releases/tag/v3.0.0) · [Release record](STORAGE-MONITOR-3.0.0-RELEASE.md)

This release adds read-only APFS snapshot inventories and historical comparisons,
Snapshot Changes filtering/search, clearer physical-free versus macOS-availability
reporting, and stronger isolation of optional evidence from capacity recording.
The new **Snapshots** section contains lifecycle-management controls and a
persistent ownership/retention engine. **Privileged creation, deletion, snapshot
mounting and automatic policies are unavailable in this ad-hoc build.** An
Apple-accepted entitlement and separately validated signed helper are still
required. This release does not modify Time Machine settings or existing recovery
points, and does not calculate exact per-snapshot reclaimable sizes.

See [snapshot intelligence](APFS-SNAPSHOT-INTELLIGENCE.md),
[management implementation and limits](APFS-SNAPSHOT-MANAGEMENT.md), and the
[readiness record](artifacts/apfs-snapshot-management/READINESS-REVIEW.md).

## Desktop app

Open **Storage Monitor.app** in `/Applications` to browse your real monitoring history. It is a regular, resizable macOS app with a Dock icon and light/dark appearance. The separate **MacBook Storage Monitor.app** remains the background worker and notification identity. Quitting or closing the desktop app does not stop that LaunchAgent.

The desktop window includes physical free/used/total capacity, pressure, the last recorded scan, and hourly/daily changes only when a suitable same-container baseline exists. Baselines must be at or before the target time and within 35 minutes of it; their actual interval is shown. A short history or a long gap displays “Not enough history.” Refresh (⌘R) reads existing records; it does not run a scan.

Event history is a native sortable table. Select a row to inspect it; Escape dismisses the inspector and ⌥⌘I toggles it. ⌘F focuses search. The File menu can reopen the main window with ⌘0. Window placement and filter preferences persist. For history, select a row and press ⌘C, or right-click and choose Copy Event.

The inspector reads top to bottom in four sections:

1. **Likely causes**: up to three measured contributors, ranked by size. A cause is an APFS volume whose allocation moved in the same direction as the free-space change (for example "Virtual memory growth +1.07 GB"). Each cause carries an evidence class (Confirmed, Likely, Possible, or Unknown) and, separately, "Responsible application: Unknown". The viewer never names an application without application-level evidence. When nothing supports a cause it says "Likely cause unavailable" and gives the reason. It never pads the list to three.
2. **Storage breakdown**: previous and current physical free capacity, the free-space change, the interval, and allocation change by volume with a thin proportional bar. A reconciliation line appears only when it is valid: "Measured volume changes account for the recorded loss" or "Some capacity change remains unaccounted for". Volume changes in the opposite direction are listed as offsetting.
3. **Supporting evidence**: swap (allocated and used), temporary files, and application data, but only measurements that changed. Each row shows its own measurement interval. Evidence measured over a different interval than the event is labelled that way and is never treated as the event's cause. A collection line summarises incomplete measurements in plain language ("Some protected directories could not be inspected (78 locations)").
4. **Technical details**: collapsed native disclosure groups for APFS, Virtual memory, Temporary files, Application data, Collector status, Raw command output and Provenance. Reading IDs, UUIDs, exact bytes, exit codes and epoch timestamps live here. **Copy Details** copies the whole analysis with provenance; **Copy Raw Output** copies the stored diagnostic output unabridged. Text in the technical sections is selectable.

Filters combine rather than replace each other: event type, time range (hour/day/week/30 days/custom), absolute change threshold, severity, and text search. Size filters use strict “greater than” decimal MB/GB comparisons and exclude unknown deltas. Custom sizes reject negative, nonfinite, or invalid values. Date controls use local time, minute precision (:00 seconds), and inclusive endpoints. Clear Filters restores the default last-24-hour view. The five sort menu choices persist; using a native column header temporarily displays “Table Column Order.” Search includes categories, alert reasons, volume names, and stored diagnostic output.

There is one primary event per recorded capacity measurement. Same-time alert attempts and diagnostics are attached to that event; unmatched stored records remain visible as independent records. “Recorded Scans” is used because the database does not record whether a scan was scheduled or manual. Physical movement is derived from adjacent same-container readings. Severity combines capacity pressure with recognized recorded alert severity; the viewer does not replay the notification engine. Unknown recorded severity is preserved and called out in details, with Information used only as a display/filter fallback.

APFS volume differences are matched by UUID between the displayed readings, so every recorded loss or recovery with an earlier reading gets a breakdown, with or without a diagnostic snapshot. Diagnostic swap and directory changes compare the same metric, measured the same way and complete at both ends, with the nearest earlier snapshot of the same container. Partial, denied, truncated, timed-out, or unmatched metrics have no inferred difference. Directory changes under 1 MB count as unchanged. A swap change counts as a VM cause's likely mechanism only when both endpoints fall within two minutes of the event's own readings. Old records with `M`/`G` swap values are read as binary MiB/GiB; new records store exact bytes. Directory totals and volume allocation are never summed. Directory sizes are at most possible contributors, used only when no volume figures exist.

The secondary chart uses actual stored capacity points, snaps hover details to a real reading, and draws the 25 GB / 15 GB reference lines. It breaks lines at container changes and gaps over 75 minutes. Its time range is independent of history filters.

The historical viewer opens SQLite with `SQLITE_OPEN_READONLY` and `query_only`, takes short consistent read transactions, closes them before projecting events, and refreshes about every 30 seconds while the app is active with a visible window. Apart from the read-only live capacity reading described above, it performs no directory scans and launches no monitoring commands except when you explicitly choose Enable, Update, Repair or Disable background monitoring, or Allow Low-Space Notifications, in Settings. Those actions run the bundled background monitor's own `install`, `uninstall` or `authorize` command after a confirmation that explains what changes. It does not change the existing writer's journal mode, schema, data, or retention. Viewer preferences, external-drive choices, operational requests and catalog reader leases are stored locally. Only the background monitor writes capacity history and inventory SQL.

**Live capacity.** The overview leads with physical free space from an in-process `statfs()` on the Data volume. Recorded APFS capacity uses diskutil `CapacityFree` and `CapacityCeiling`; sequential readings and quota views can differ. Foundation ordinary, important-use and opportunistic availability are kept separate. Their difference from physical free space is not exact purgeable or reclaimable storage. The viewer reads it when it opens, when it becomes active, every 60 seconds while its window is visible and the app is active, and on ⌘R; overlapping requests are dropped. The status line shows when it last updated, and a reading older than 3 minutes, or one whose refresh failed, is marked *Stale*. Live readings are never stored, never evaluated for alerts, never notify, and never start the collector; the viewer does not link the notifications framework. The last background reading appears on its own line. Any difference from it is shown only when the live Data volume UUID belongs to the recorded container, and it is labelled an observation comparison, not a recorded event. Events, the inspector and the chart ("Recorded physical free capacity") use recorded readings only.

**Appearance.** View → Appearance, or Storage Monitor → Settings (⌘,), offers System, Light and Dark. The choice is saved in the viewer's own preferences and applies only to Storage Monitor. System follows macOS, including later changes. The macOS appearance setting is never changed. The QA launch option `--appearance light|dark` overrides the choice for that launch without saving it.

For a distributable, drag-to-Applications disk image with the background monitor bundled inside the app, see [PACKAGING.md](PACKAGING.md) (`scripts/build-dmg.sh`).

`scripts/build-gui.sh` builds a development viewer, `build/Storage Monitor.app`, with its own identity (`local.macbook.storage-monitor.viewer.dev`, "Storage Monitor Dev"), so its preferences and window state never change the installed app's. Run it in place; it is never installed.

Install the desktop app on its own, without the disk image, from a release build (production identity `local.macbook.storage-monitor.viewer`):

```sh
STORAGE_MONITOR_APP_ONLY=1 scripts/build-dmg.sh
scripts/install-gui.sh
```

The installer refuses a bundle without the production identifier. It prefers `/Applications/Storage Monitor.app` when the current user can write there and otherwise uses `~/Applications/Storage Monitor.app`; this Mac uses `/Applications`. Quit the GUI normally before updating it. The background app and LaunchAgent are untouched. A writable explicit destination can be selected with `scripts/install-gui.sh --destination /Applications/Storage\ Monitor.app`; no sudo is used. The supplied icon resource is reused exactly.

GUI test commands:

```sh
scripts/test-gui.sh
scripts/build-gui-ax-tests.sh   # then: build/GUIAXTests PID /abs/fixture.sqlite3 [--inspector-only]
```

The model suite creates isolated, clearly labelled QA fixture databases under `build/qa-fixtures`. To open a fixture in a separately labelled QA window, quit the normal viewer, then launch the same app with `open -n '/Applications/Storage Monitor.app' --args --database-path "$PWD/build/qa-fixtures/populated.sqlite3" --appearance dark --window-size 900x650`. A database override is never persisted to production preferences, and the QA preference suite is separate. Missing/corrupt/empty fixtures exercise the corresponding states without inserting production rows. `build/GUIAXTests PID /absolute/path/populated.sqlite3` drives actual native controls only if the host grants Accessibility and the target window is visibly labelled QA. See [GUI-VERIFICATION.md](GUI-VERIFICATION.md) for actual GUI verification and limitations.

The model suite also loads `tests/fixtures/2026-10-21-0400-event.json`, the real Oct 21 3:30 → 4:00 AM event copied verbatim from production history. It is the acceptance case: Data +1,103,945,728, VM +1,073,782,784, and Update +1,052,672 bytes reconcile exactly with the −2,178,781,184-byte free-space change, with no application named. Set `STORAGE_MONITOR_PRODUCTION_COPY=/path/to/a/copy.sqlite3` to also check that a copy of real history loads intact. `GUIAXTests … --inspector-only` checks the inspector's section order and its collapsed-by-default disclosures without opening popup menus. QA-only launch options `--select-event reading:N`, `--inspector-scroll-bottom` and `--expand-technical "APFS,Collector status"` make `--capture-window-path` renders show a chosen event.

## Commands

Run these from this project directory:

```sh
scripts/build.sh
bin/storage-monitor install
bin/storage-monitor authorize
bin/storage-monitor test-notification
bin/storage-monitor status
bin/storage-monitor check
bin/storage-monitor history 20
bin/storage-monitor alerts 20
bin/storage-monitor diagnostics 1
bin/storage-monitor diagnose
bin/storage-monitor uninstall
```

`diagnose` explicitly requests a deeper read-only snapshot. Normal checks run diagnostics only on a newly active growth condition. `uninstall` unloads and removes only this utility's LaunchAgent; it retains the app and history. `install` replaces this utility's app/agent and preserves history. Rebuild before reinstalling source changes. No sudo is used.

The installed executable works without this checkout:

```sh
"$HOME/Applications/MacBook Storage Monitor.app/Contents/MacOS/StorageMonitor" status
```

## External drives

The window's **Drive** selector scopes both Storage and Monitoring. Open **Manage external drives** to enable monitoring and indexing for chosen connected drives. Discovery alone never enrolls a drive. Supported filesystems are APFS, HFS+ and exFAT on verified local, physical external storage, including external PCIe SSDs. Network mounts, disk images, system helpers, Time Machine destinations and unverifiable identities are excluded.

Chosen drives resume when they reconnect. Identity follows the volume UUID, rather than the drive name or mount path. Duplicate mounted UUIDs stop work; a changed known physical backing or APFS capacity scope requires explicit re-enrollment. **Pause indexing** keeps capacity monitoring active. **Disable** stops both and retains recorded history and the last published catalog.

Each external volume has its own index. APFS siblings share one container capacity history and alert evaluation, labelled with all enrolled sibling names. A gap longer than 75 minutes starts a fresh change baseline; current low-space thresholds still apply. exFAT folders refresh on schedule or request, without claiming continuous file-event history. External views do not attach startup swap, cache or application attribution, or offer cleanup plans.

Working databases, capacity history and immutable published catalogs stay on internal storage under `external-volumes/` inside the monitor's data directory. The app writes no metadata to an indexed external drive. Offline catalogs remain browsable with their measured time; live Finder actions require the selected mount to be revalidated. One dispatcher serializes startup and external indexing and resumes fairly between targets.

External support requires a matching background monitor and its updated mount/registry wake configuration. Settings detects this capability independently of the release version. Building a development app does not update the installed monitor.

The corresponding helper commands are `external-discover`, `external-list`, `external-enable UUID`, `external-disable UUID`, `external-pause UUID`, `external-resume UUID`, `external-refresh UUID`, and `external-check`. Discovery reads bounded disk metadata; enabling is a separate action. As with other commands, `--data-dir` selects an isolated internal support directory. See [external-volume verification](docs/EXTERNAL-VOLUMES-VERIFICATION.md) for tested behavior and remaining native/physical checks.

## Alerts and notifications

Thresholds use **decimal GB** (1 GB = 1,000,000,000 bytes):

| Condition | Severity |
|---|---|
| Available capacity drops at least 3 GB from the previous successful reading | Warning |
| Available capacity drops at least 5 GB from any successful reading in the preceding 2 hours | Warning |
| Available capacity below 25 GB | Warning |
| Available capacity below 15 GB | Critical |

The 2-hour calculation compares the highest observed available capacity with the current reading, not a sum of all decreases. Boundaries are inclusive for growth and strict for low-space thresholds. The first reading establishes a growth baseline but can alert for already low space. Missing/failed readings never become zeros or alter the baseline. A new APFS container UUID resets the baseline and alert state.

Notifications include severity, current free capacity, and change since the previous check. Delivered active reasons are remembered in SQLite across launches; an unchanged condition does not repeatedly notify. Recovery rearms that condition, and a warning escalating to critical alerts immediately. A resolved growth condition does not re-notify an unchanged low-space condition. Failed or unconfirmed delivery stays pending and retries at most every 30 minutes unless a new condition appears. After enabling notifications, request an immediate retry of pending conditions with:

```sh
bin/storage-monitor check --retry-notifications
```

The app uses Apple's **UserNotifications** API in a registered, signed app bundle; it does not depend on Terminal or `osascript` notifications. `authorize` opens the background app and requests macOS notification permission. If denied, enable **MacBook Storage Monitor** in **System Settings → Notifications**. The utility cannot grant itself this permission. `notification-status` prints the current authorization state. In the numeric settings shown, `0` = unsupported, `1` = disabled, `2` = enabled.

`test-notification` only succeeds when the specific test notification is returned by `getDeliveredNotifications`. To test the same app from a real per-user LaunchAgent:

```sh
tests/verify-launchd-notification.sh
```

This creates and unloads a separate one-shot test job. A submitted notification is not proof of delivery. Focus, notification styles, sound preferences, and macOS policy can affect whether a banner or sound is noticed, even when Notification Center delivery is confirmed. See [VERIFICATION.md](VERIFICATION.md) for this Mac's actual result and outstanding permission requirements.

## Measurements and diagnostics

The monitor identifies the root APFS container with `/usr/sbin/diskutil` property lists, verifies every physical store is internal, and records `CapacityFree`, `CapacityCeiling - CapacityFree`, and the APFS volume allocation objects. Available capacity is the container's currently unallocated physical capacity; it does not include a promise that purgeable files can be reclaimed. It is deliberately different from Finder's estimate of available space. Never sum volume or directory totals to calculate container usage.

New growth alerts (and `diagnose`) collect a small, structured, read-only snapshot (schema 2, typically about 5 KB) without launching any subprocess:

- **APFS**: reused from the reading's complete `diskutil apfs list -plist` capture. There is no second, size-capped diskutil call. A `diskutil` capture that is truncated, timed out or failed is rejected rather than parsed.
- **Swap**: allocated (total swapfile size), used and free bytes, exactly, from `sysctlbyname("vm.swapusage")`.
- **Virtual memory**: the storage-related Mach counters (free/active/inactive/wired/compressor pages, swapins/swapouts) from `host_statistics64`, not the full `vm_stat` dump.
- **Directories**: bounded in-process walks of a short list of known locations, if present: Chrome signing clones found by listing only this user's own `/private/var/folders/…/{X,T,C}` (one level, no recursion), this user's temporary folder, Claude Desktop VM folders, the Google and Homebrew caches, Xcode DerivedData, and the npm cache. Each walk records logical and allocated bytes, does not follow symlinks or cross volumes, stops at 6 seconds or 200,000 entries, and the whole snapshot stops at 40 seconds. All of `/private/var/folders`, `~/Library/Application Support`, `~/Library/Caches`, app containers, browser profiles and the home folder are never scanned.

macOS permission refusals are normal. Each location records a status (complete, partial, timed out, failed, skipped), a count of refused paths and up to three examples, never hundreds of repeated error lines. A timed-out, capped or partly refused measurement is marked incomplete and is never used to compute a change. No privileges, Full Disk Access or SIP changes are requested.

Older snapshots (schema 1, raw `du`/`find`/`diskutil` output) still load. The viewer classifies their timeouts, truncation and permission refusals, counts each refused path once, and folds repeated refusals in the displayed raw output; Copy Raw Output keeps the original text.

The monitor's remaining subprocesses (`diskutil`, `launchctl`) each have a deadline and a bounded capture. On timeout they get SIGTERM, then SIGKILL after one second, and are always reaped.

## Folder growth attribution

Every check also records which monitored folders changed between this reading and the previous one. The design and its limits are in [ATTRIBUTION.md](ATTRIBUTION.md).

- **Folders.** `~/.cache`, `~/.codex`, `~/.local/share`, `~/Library/Caches`, selected Application Support folders (Claude, VS Code, Cursor), `~/.npm` and Xcode DerivedData are measured per immediate subfolder, with logical and allocated sizes. A change is reported only when the subfolder's previous measurement is valid at the previous reading. To add project build folders, list them in `~/Library/Application Support/MacBook Storage Monitor/monitored-roots.json` as `{"roots":[{"path":"/abs/path","label":"name"}]}`. Nested, overlapping and symlinked roots are rejected.
- **Changed files.** FSEvents history is replayed between the two readings' event IDs; there is no resident watcher. Paths and change types are recorded, never file contents. Gaps (dropped events, a changed event database, a missed reading) are recorded, never papered over.
- **Processes.** A process is shown only as a *correlation*: it held files open for writing inside a folder that grew. Confirmed process attribution would need Endpoint Security or root, which this tool does not use.
- **Cost.** The first check after install walks every root (about 14 s here). Later checks re-measure only subfolders with file activity (about 2 s here). Evidence adds one row of about 2–10 KB per reading, under the same 30-day retention. `bin/storage-monitor attribution [count]` prints recent evidence as JSON. `bin/storage-monitor attribution-probe --data-dir /abs/scratch` runs only the evidence collection, without a reading or notification, for development.

**Baseline initialization.** On install or first login, a one-time background job (`local.macbook.storage-monitor.baseline`) measures every accessible monitored folder in short, checkpointed slices, without waiting for scheduled checks (about 1–2 minutes on this Mac). It resumes after interruption, reconciles folders that change while it runs, and exits once coverage is complete. The overview shows *Folder monitoring*, for example "Active · 348 folders tracked" or "Initializing · 242 of 348 folders baselined". `bin/storage-monitor baseline-status` prints the same coverage as JSON. Protected folders are reported as unavailable and retried daily; folders that repeatedly time out are reported as incomplete and retried every 6 hours.

**Comprehensive filesystem coverage.** The monitor now covers the whole startup Data volume rather than only the predefined folders: `/Users`, `/Applications`, `/Library`, `/private`, `/opt`, `/usr/local`, hidden folders and everything else on it. Details are in [ATTRIBUTION.md §7](ATTRIBUTION.md).

- **How it is measured.** The volume is divided into about 12,000 disjoint measurement areas. The background job measures each one once (about 2.5 minutes here), and scheduled checks re-measure only the areas with file events, typically in 1–4 seconds.
- **Not walked.** Other mounted disks and network shares are never entered. The sealed system volume and the VM, Preboot and Update volumes are covered by APFS volume figures only.
- **Gaps and history.** After a gap in file-event history, nothing is assumed unchanged and the background job re-measures. Until comprehensive coverage is established, the predefined folders keep providing evidence, and history records the reading where comprehensive coverage began.
- **Turning it off.** `{"mode":"folders"}` in `~/Library/Application Support/MacBook Storage Monitor/coverage.json` returns to the predefined folders.
- **Inspecting coverage.** `bin/storage-monitor coverage-status` prints the current coverage, inaccessible regions and coverage epochs. Add `--units inaccessible` (or any state) to list individual areas.

**Full Disk Access.** Without it, macOS shows a permission prompt or an "app data" notification when a background process opens Desktop, Documents, Downloads, Pictures, Music, Movies, iCloud, app containers, or other apps' data in `~/Library`. Storage Monitor therefore never opens those folders, or any Application Support folder it was not already reading. If a folder still fails to answer, a watchdog marks it blocked and moves on. It reports them as inaccessible and keeps monitoring everything else.

To include them, open **System Settings → Privacy & Security → Full Disk Access**, click **+**, and add `~/Applications/MacBook Storage Monitor.app` (the background monitor, not the viewer). The monitor never asks for this itself. Root-only and SIP-protected system folders stay inaccessible either way. The overview's *Filesystem coverage* line and its tooltip show the current state, pending work, inaccessible regions and the last successful reconciliation.

In the inspector, measured folder growth and any process correlation appear under the Data volume cause. The breakdown states the unattributed remainder as an estimate; folder sizes are never added to APFS totals. Supporting evidence lists the folders, changed-file counts and correlated processes. Technical details gains Folder growth, File activity and Processes sections, collapsed by default.

## Local files and scheduling

| Path | Purpose |
|---|---|
| `~/Applications/MacBook Storage Monitor.app` | Native executable and notification identity |
| `~/Library/LaunchAgents/local.macbook.storage-monitor.plist` | Per-user calendar schedule and login startup |
| `~/Library/Application Support/MacBook Storage Monitor/history.sqlite3` | Measurements, alert reasons/results, diagnostic snapshots, folder attribution evidence, persistent alert state and folder baselines |
| Same folder: `monitor.log`, `monitor.log.1` | Rotating operational logs, approximately 256 KiB each |
| Same folder: `check.lock` | Nonblocking `flock` prevents overlapping checks/diagnostics |

Data folders are mode `0700`; the DB, logs, lock, and LaunchAgent plist are mode `0600`. SQLite retains 30 days, with additional ceilings of 10,000 measurements, 5,000 alert records, and 120 diagnostic snapshots to bound unusually frequent manual use. SQLite reuses freed pages and performs bounded incremental vacuum; the DB file need not shrink immediately after every expiry. Age retention runs on checks and history/status commands, including after downtime. launchd output goes to `/dev/null`, and failures go to the bounded internal log.

`status` includes the age of the most recent successful measurement, container/volume values, current conditions, notification health, and launchd load/last-exit status. An old reading should be treated as stale, not as current available capacity. `history`, `alerts`, and `diagnostics` accept a count (default 10, maximum 1,000). Diagnostics are emitted as JSON; alerts include notification outcomes. All data stays on this Mac. There is no network client, telemetry, root daemon, persistent sudo requirement, snapshot mutation, update-setting change, application termination, or user-file cleanup. Only the monitor's own bounded logs, expired DB rows, app installation, and agent files are maintained.

## Verification and development

```sh
scripts/build.sh
bin/storage-monitor self-test
tests/verify-launchd-notification.sh
```

The build needs Apple's Command Line Tools and the macOS SDK. Runtime uses only bundled Swift code, system frameworks, system SQLite, and absolute system utility paths; it has no Python/Node/package-manager dependency. `self-test` exercises production alert planning with SQLite reopen transitions, thresholds, retention, LaunchAgent serialization, locking, and subprocess deadlines using isolated temporary data. A different private absolute data directory can be selected with `--data-dir /absolute/path` for manual test measurements.

The supplied app artwork is preserved in `Assets/AppIcon.png`. Each build preserves the RGB artwork and adds an opaque alpha channel to generated output, creates all ten standard macOS icon representations (16–1024 pixels) with system `sips`, bundles `AppIcon.icns`, declares `CFBundleIconFile`, then signs the complete app. Packaging uses `iconutil` with a native standard ICNS/PNG-container fallback for hosts where it rejects valid iconsets. To attempt exporting the icon macOS resolves for the installed app for inspection:

```sh
/usr/bin/xcrun swift -module-cache-path build/module-cache tests/verify-icon.swift "$HOME/Applications/MacBook Storage Monitor.app" build/icon-preview
```

The probe exits 2 if this host's IconServices returns blank pixels. The installed resource can be decoded independently with `sips -s format png "$HOME/Applications/MacBook Storage Monitor.app/Contents/Resources/AppIcon.icns" --out build/icon-preview/direct-resource.png`. See the verification report for the observed host limitation.

Apple references: [UserNotifications](https://developer.apple.com/documentation/usernotifications/unusernotificationcenter), [delivered-notification queries](https://developer.apple.com/documentation/usernotifications/unusernotificationcenter/getdeliverednotifications(completionhandler:)), and [launchd calendar jobs](https://developer.apple.com/library/archive/documentation/MacOSX/Conceptual/BPSystemStartup/Chapters/ScheduledJobs.html).
