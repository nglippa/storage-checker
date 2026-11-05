# Studio indexing diagnosis — 2026-11-05

SSH identity verified: Mac-Studio.local, arm64, nicholaslippa, macOS 27.2 build 26B123. Dedicated identity at ~/.ssh/id_ed25519_storage_studio; user appended its public key with restrict options. No private key is recorded here.

Installed background helper: Storage Monitor 2.2.0 build 10. codesign --verify --deep --strict succeeds. Quarantine attribute exists, but worker execution is established by timestamped logs; no Gatekeeper or Full Disk Access failure is inferred.

All three expected production LaunchAgents are registered and idle with last exit code 0. Inventory job has run 6 times. Its installed arguments include inventory-work --budget 1200 and WatchPaths points at the inventory-requests directory.

Latest worker summary (2026-11-05T07:01:18Z): generation 2, outcome interrupted, status paused, reason cancelled, directories 0, entries 0, pending 1, full_disk_access granted. Earlier Nov 5 summaries have the same paused/cancelled result.

The production inventory.cancel marker exists: 6 bytes, permissions 0600, created/modified 2026-10-25T04:16:56Z. Catalog file dates to Oct 21 and is 1,569,099,776 bytes; no WAL/SHM/journal companions were present during metadata inspection. inventory-requests directory was empty.

Conclusion: the freshly installed DMG reused existing operational data containing persistent pause intent. The worker runs and honors that pause; merely reloading results or reinstalling the viewer does not resume it.

All remote checks were read-only metadata, bounded logs, filtered launchctl print, plist parsing, signature and quarantine reads. The production database was never opened; no app/service/database/pause flag was changed. Native GUI was not launched or manipulated.

The proposed recovery required user authorization: preserve the marker under remote /private/tmp, invoke the existing installed helper inventory-resume once, allow WatchPaths to wake its existing index worker, and verify real resumed progress. Authorization was subsequently granted and the action completed as recorded below. This changed pause intent and permitted normal existing catalog writes; it did not install/update/reset or request a full refresh.

## Authorized resume and observed recovery

The user explicitly approved: “Resume the existing Studio index.” The approved action backed up the original pause flag to `/private/tmp/storage-monitor-resume-20261105/inventory.cancel.paused-20261025.backup`, then invoked the installed helper `inventory-resume --data-dir` once. It exited 0 with “Inventory resume requested.” Request ID: `1C2613A0-11ED-4F49-BBF4-68C7D6AABA04`. The pause marker was removed by this normal request mechanism; the existing launchd WatchPaths consumed the request and started its normal worker (PID 46844, run 7). No install, helper replacement, service bootout/kickstart, catalog reset, or full-refresh request occurred.

Baseline disposable APFS clone: active generation 2, state paused, reason cancelled, total nodes 1, completed directories 0, pending directories 1.

Recovery snapshot at approximately 2026-11-05T07:25:23Z: active generation 2, state building, reason null, total nodes 18,166, completed directories 1,622, pending directories 5,047, unknown directories 996. Latest persisted progress sample at 07:25:14Z recorded completed listings 2,423 and nodes 17,590. The worker remained running. This verifies real catalog advancement after resume.

Snapshot method: APFS `cp -c` into dedicated remote `/private/tmp`, only accepting a copy when source inode, size, and mtime_ns were unchanged across the clone and no journal/WAL/SHM was observed before or after it. SQLite opened only the disposable clone with mode=ro and immutable=1. The production database was never opened by diagnostics. Baseline copy: `/private/tmp/storage-monitor-resume-20261105/before-resume.sqlite3`. Recovery copy: `/private/tmp/storage-monitor-resume-20261105/progress-1793863523235508000.sqlite3`.

NOT VERIFIED: full database integrity (the baseline quick_check reached its deliberately bounded three-second deadline); completion of the entire disk index; native app rendering and interaction (no GUI activation/input was performed).

## Sustained normal continuation

At 2026-11-05T07:43:14Z, the existing worker committed its normal 1201-second slice: generation 2, directories 24,622, entries 262,432, pending 48,518, status continuing, continues true, empty reason, Full Disk Access granted. Launchd automatically started the next slice (run 8, PID 48231); its last exit 75 is normal saved-work continuation. No cancelled/error result was observed after the approved resume. These summary counts do not establish completion of the whole index.

## Fresh build delivery

The build 11 candidate completed **1164 GUI/model checks**, **114 inventory controller/model checks**, **25 package checks**, and **238 direct monitor self-tests**, all passing. The direct monitor run exited 0 outside the sandbox after the earlier sandbox swap-read failure. Full release details are in [the build receipt](STUDIO-REFRESH-BUILD11-20261105.md).

Local DMG: `/Users/nicholaslippa/orca/projects/storage-checker/build/dist/Storage-Monitor-2.2.0-Studio-refresh-build11-20261105.dmg`.

Verified Mac Studio copy: `/Users/nicholaslippa/Downloads/Storage-Monitor-2.2.0-Studio-refresh-build11-20261105.dmg`. Remote size is **17,102,428 bytes** and SHA-256 is `57ff94fcef5e8630c4746545a82e30ca4a8f571de47e5a950dc205e900baae60`; both match the local artifact. **Delivered; awaiting installation.** Transfer did not launch or install the app or modify the installed helper, services or database.

**NOT VERIFIED:** new packaged native window rendering; toolbar/manual Reload interaction; visible Resume interaction; real Enable/Repair flow; Gatekeeper first launch. The verified recovery above used the existing installed helper and does not establish these new packaged viewer behaviors.
