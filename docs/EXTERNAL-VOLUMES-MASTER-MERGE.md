# External-volume development merge

The user requested fetching remote master and merging it on a new development branch.

- Worktree: `/Users/nicholaslippa/storage-checker-external-volumes`
- New branch: `dev/external-volumes-master`
- External-volume development checkpoint: `22aa959`
- Fetched `origin/master`: `6cf2fac` (13 commits beyond the original base `c843fe0`)
- No push, installation, release, production agent/database change or personal-volume indexing.

## Integration

Eight conflicted files were resolved by preserving master’s monitoring-health, inventory lifecycle, Migration Readiness and lifecycle QA behavior alongside external drive selection, mount validation, scoped history and dispatcher deadlines. External controls and metadata sampling remain excluded from both QA runtimes.

The combined code initially routed global monitoring health through the selected external drive. A fixture reproduced this failure. Worker evidence now always uses the startup data directory, and a bounded read-only query obtains the startup reading timestamp independently of selected-drive history. The regression fixture passes with distinct startup/external timestamps.

Live capacity retains master’s explicit refreshing state and injected clock together with external source revisions, so late responses cannot overwrite a newly selected drive. External inventory lifecycle presentation uses the selected registration rather than startup monitoring settings. Lifecycle-scoped setup avoids applying production external-helper configuration checks to private QA labels.

## Fresh verification

| Check | Result |
|---|---|
| Inventory integration, including master’s additions | 379 passed outside sandbox on disposable fixtures |
| Viewer models/read-only contracts | 1,149 passed |
| Monitor self-test | 238 passed outside sandbox |
| Lifecycle QA model/safety contracts | 52 passed; no real launchctl or GUI executed |
| External ViewerStore/helper integration | 13 passed, including global-health routing regression |
| External live/history models | 9 passed |
| Full dispatcher wave | 21 passed |
| Helper and self-contained development app | Built successfully |
| Deep/strict signing, plist lint, matching bundled-helper executable | Passed |
| Integration diff whitespace check against `origin/master` | Passed |

Logs: `/private/tmp/storage-external-merge-*.log`. The first inventory run hit the known sandbox capacity-counter limitation; the same built test binary passed outside the sandbox. One viewer compilation was invalidated by concurrent merge edits and was rerun successfully after source changes settled. An initial Store compile issue and the reproduced health-routing failure are retained in the RED logs.

The full merge diff from the development checkpoint also reports whitespace already present in master’s archived evidence patches/source copies. Those upstream archives were preserved byte-for-byte. The pre-existing cleanup weak-capture compiler warning remains.

Read-only review also observed two behaviors inherited unchanged from `origin/master`: lifecycle inventory failures use the production no-relaunch exit policy, and the inventory accounting popover’s Full Disk Access Settings button lacks the QA disable used by the Settings screen. These were retained as upstream behavior for this bounded merge; neither was exercised through a native window.

The original checkout remains on its existing local master with its original dirty files intact. **NOT VERIFIED:** native light/dark drive-picker interaction, opt-in/pause/disable/rapid switching through windows, offline Finder presentation, physical-drive indexing/unplug/reconnect, multiple physical APFS sibling mounts, and real notification delivery. The user’s headless-only preference remains in force.
