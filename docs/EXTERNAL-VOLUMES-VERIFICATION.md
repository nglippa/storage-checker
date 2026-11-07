# External-volume update verification

Source: `feature/external-volumes`, based on `c843fe0`, in `/Users/nicholaslippa/storage-checker-external-volumes`.

This is an unreleased development candidate. No commit, push, installation, release-version assignment, production agent change or personal-volume indexing was performed. The original checkout's cleanup-inspector/scroll changes remain intact.

## Recorded results

| Check | Result |
|---|---|
| Existing inventory integration | 350 passed; built binary run against disposable fixtures outside sandbox |
| Existing viewer models/read-only behavior | 960 passed |
| Monitor self-test | 235 passed outside sandbox; OS swap-counter access is restricted in sandbox |
| Headless inventory-browser models | 68 passed, 0 failed |
| NativeQA isolation + existing trash safety | 211 assertions passed, 0 failed; no windows opened |
| External inventory root barriers | 26 passed |
| Registry identity/concurrent writers/private storage | 23 passed |
| Metadata discovery | 25 passed |
| Mount leases/capacity sessions/SQLite alias refusal | 25 passed |
| Immutable SQLite catalogs/publication/pruning | 30 passed, including orphan cleanup and validation deadline |
| External controls/rotation/durable wakes | 13 passed |
| Full multi-target dispatcher wave | 21 passed, including automatic reconnect without re-enrollment, persisted fairness, budget exhaustion, wake preservation, failure isolation and concurrent-worker exclusion |
| Drive context/offline routing | 7 passed |
| Late live-capacity response/history projection | 9 passed, including generic-filesystem attribution and session baseline limits |
| Actual external slice on disposable fixture | 11 passed, including renamed reconnect, changed-backing fresh generation, immutable old catalog and failed-publication retry |
| ViewerStore/history identity/helper readiness | 12 passed |
| Development app and matching bundled helper | Built with macOS 26.5 SDK; deep/strict code-signature verification and plist lint passed |
| Diff and shell syntax checks | Passed |

Logs are retained under `/private/tmp/storage-external-*.log`. RED logs intentionally record missing APIs or unsafe behavior before fixes; they are not current acceptance results. The sandbox reports false zero important-usage capacity on this host, despite ample real free space. No product low-space guard was weakened; focused fixture tests use the existing test override and broad inventory validation used an approved unsandboxed test binary.

On November 7, the full dispatcher was exercised with explicit injected metadata, validators, runners and a monotonic clock. The fixtures cannot invoke live discovery or a real inventory scan. The new suite passed 21 checks (`storage-external-wave-final.log`), and the controls and actual external-slice regressions passed again (13 and 11; `storage-external-controls-wave.log`, `storage-external-dispatch-wave.log`). The production wave budget now uses system uptime so wall-clock changes do not alter its remaining allowance. The helper and bundled development app were rebuilt successfully (`storage-external-build-wave.log`, `storage-external-candidate-wave.log`); strict/deep signing, plist lint, exact bundled-helper binary comparison, shell syntax and diff checks passed again. The original checkout still matches its preserved dirty baseline.

## Native and physical checks

**NOT VERIFIED:** Native drive-picker layout/interaction in light and dark appearance; opt-in, pause/disable and rapid switching through the actual windows; offline Finder-action presentation; physical-drive indexing/unplug/reconnect; multiple physical APFS sibling mounts; real delivery of external low-space notifications. Fixture tests cover their model/engine contracts, not these native outcomes.

The user explicitly chose **Keep verification headless**. No GUI was launched. An isolated fixture preview was built and signed, but never opened. The existing cleanup weak-capture compiler warning remains in the unchanged cleanup implementation.

Metadata-only discovery was also exercised against the attached **Studio-AI** PCIe SSD outside the sandbox: APFS, external physical storage, valid mount identity, and no verification error. Unsupported mounts remained excluded. The temporary discovery directory is `/private/tmp/storage-external-live-discovery.PVu6IS`; neither a registry nor an inventory directory was created. No real external drive was enrolled or indexed.

The 13:20:24 discovery failure was a regression fixture using actual diskutil key shapes: partition metadata omits VirtualOrPhysical, and whole disks use WholeDisk. It passed at 13:22:12 after correction; the final expanded suite passes 25 assertions. Intermediate failed and RED logs are retained for audit, including fixed priority and fixture issues; only the final results above are acceptance evidence.

Candidate: `build/Storage Monitor.app`, development bundle identifier `local.macbook.storage-monitor.viewer.dev`, with `Contents/Helpers/MacBook Storage Monitor.app`. Release metadata remains the repository's **2.2.0 (10)**; this is not an assigned release or an installed update. The original checkout's existing dirty files and installed runtime remain untouched.

## Reproduction

Focused suites are `scripts/test-external-{volumes,discovery,inventory,runtime,catalogs,controls,dispatch,wave,selection,live,store}.sh`. They use disposable internal fixtures and never install or start production services. The Store test removes the app entry point in a temporary source copy; it does not create a window.

Existing suites: `scripts/test-inventory.sh`, `scripts/test-gui.sh`, `scripts/test-inventory-model.sh`, `scripts/test-native-qa.sh`, plus the built monitor's `self-test`. On this host, inventory/browser/self-test binaries need approved unsandboxed execution for accurate filesystem/swap counters. All fixture roots remain disposable and internal.

Build the helper with `scripts/build.sh`, then the self-contained development candidate with `STORAGE_MONITOR_BUNDLE_HELPER=1 STORAGE_MONITOR_SDK_PATH=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk scripts/build-gui.sh`. These commands build and sign local artifacts; they do not install or launch them.
