# Storage Monitor 2.4.2 (build 21) — release record

Date: 2026-11-08. Ad-hoc signed, not notarized. Universal, macOS 14 or later.

## Change

2.4.1 installed three per-user LaunchAgents (check, baseline, inventory). The build has no Team ID, so macOS ignores `AssociatedBundleIdentifiers` and showed three "Background Items Added" notifications. 2.4.2 installs one agent, `local.macbook.storage-monitor`, running `supervise`. The supervisor starts the existing `check`, `initialize-baseline` and `inventory-work` commands as child processes with the former launchd semantics (see `SourcesShared/SupervisorModel.swift` and `Sources/Supervisor.swift`). Install and upgrade remove the legacy `.baseline` and `.inventory` agents; uninstall removes them too.

## Verified

Automated, on the build machine:

- helper `self-test`: 282 passed (includes install, upgrade from three agents, rollback, uninstall, supervisor scheduling and a supervisor run against a stand-in worker);
- `scripts/test-gui.sh`: 1163 passed, 0 failed;
- `scripts/test-lifecycle-qa.sh`: 50 passed;
- `scripts/test-inventory-model.sh`: 97 passed;
- `scripts/build-dmg.sh` self-verification of `Storage-Monitor-2.4.2.dmg`.

Real install, Mac mini (macOS 27.2, Apple silicon), upgrade from 2.4.1 (20), 2026-11-08:

- after `install`, only `local.macbook.storage-monitor.plist` remains and launchd lists only that label, running `supervise`;
- the user saw **one** "Background Items Added" notification (2.4.1: three);
- the supervisor started check, baseline and inventory within 10 s of load; all exited 0;
- the 03:30 local slot started a check by itself (09:30:19Z), which woke inventory through `supervisor-wakes`; both exited 0; the supervisor PID was unchanged throughout;
- `supervisor-status.json` and `monitor.log` recorded every start and exit.

## Not verified

- catch-up of a missed slot after a real sleep;
- a real volume mount starting a check;
- `KeepAlive` restart of the supervisor after a crash;
- the real-launchd lifecycle QA harness (`scripts/verify-lifecycle-qa.py`, `scripts/lifecycle-qa-guard.py`), edited for one label but not run;
- native Settings interaction (health lines from `supervisor-status.json`);
- Intel execution.

Full Disk Access must be granted again after the upgrade: a new ad-hoc signature is a new identity to macOS (the Mac mini reported `full_disk_access: not_granted`).
