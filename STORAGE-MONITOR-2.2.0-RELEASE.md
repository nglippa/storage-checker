# Storage Monitor 2.2.0 (build 10)

Release source integrates Structured Explorer as the default Living Tree presentation, retains the classic renderer, and includes navigation-throttle, chart-hover, caption-placement, scroll-routing and double-click stabilization. The d3-hierarchy-derived layout's ISC notice is bundled in both the viewer and helper. No catalog schema migration or storage-accounting change is introduced by this integration.

Version metadata is shared by all build scripts through `scripts/version.env`: marketing version **2.2.0**, monotonically increasing build **10**. The release DMG is universal (arm64 and x86_64), targets macOS 14+, and is ad-hoc signed. Packaging does not install or start monitoring.

## Automated verification

All nine release commands completed with exit 0 on 2026-10-29, using the macOS 26.5 SDK. Logs and machine-readable results remain local in `build/release-2.2.0-verification/` of the integration worktree.

| Check | Result |
|---|---|
| Monitor and viewer development builds | Both passed |
| Monitor self-test | 235 passed |
| Viewer model/read-only suite | 937 passed |
| Inventory integration suite | 350 passed |
| Inventory browser suite | 68 passed, 0 failed |
| Hosted chart geometry and scroll routing | 42/42 passed |
| Structured Explorer benchmark | 43 checks, 0 failures |
| Navigation benchmark with pending reconciliation | 0 failures; 0 renderer-switch tree builds |

Navigation measurements (offscreen host, warm OS cache): first controller visit p50 120.8 / max 144.6 ms; revisit p50 100.0 / max 128.7 ms; Up p50 118.6 / p95 122.4 / max 124.8 ms. These results do not replace native visible-frame or physical-input acceptance.

Benchmarks used disposable APFS clones. The preserved source catalog's SHA-256 was unchanged before/after: `0fa4373a1198e6dc17fe145c79fc9e882195a3e67ff6b298329bf54114f133a1`. The compiler emitted the existing `CleanupInspectorView.swift` capture warning; there were no build errors. A focused read-only integration/packaging review found no concrete release blockers.

## Native acceptance and known limits

The authorized development-binary native session ran before the version-only release stamp. [Its report](artifacts/structured-explorer-integration/stabilization/native-qa-20261029T172929/NATIVE-RESULTS.md) is authoritative for the sampled checks and cleanup; it is not a native acceptance run of the distribution binary.

- Sampled native checks passed: last-reading hover in normal/dark and minimum/light, readable selected labels at 1000×692, Users disc/label double-click at 100% and 225%, Return/Escape/Search focus, reverse zoom, 40%/2400% limits, and classic/Structured switching without another tree read.
- The earlier multi-second navigation delay did not recur. Repeat-entry tree-read readiness was p50 179.4 / max 213.9 ms. Up was p50 196.9 / max 218.2 ms and missed the strict 200 ms target in 4/10 samples; including layout computation, Up was p50 207.7 / max 228.7 ms. These are trace endpoints, not controlled visible-pixel timing.
- Full hover dwell/clearing/size/appearance coverage, physical wheel and trackpad/pinch/momentum, Inspector scrolling/toggling, launch-argument fallback, first-visible-frame timing, VoiceOver, larger text, increased contrast and RTL remain **NOT VERIFIED** or partial as detailed in the native report. Full native acceptance is not claimed.
- QA preferences were restored and compared equal; the QA PID exited; its disposable clone was removed; the preserved catalog hash was unchanged. Native screenshots, AX dumps, logs, private QA preferences and generated binaries remain local evidence and are not source-controlled.

## Package verification

At source integration, package construction and verification have not yet run. They run from the merged master commit; the completed package result is recorded in a follow-up documentation commit.

The DMG verifier mounts read-only with `-nobrowse -noautoopen`, inspects both bundles, and executes only the monitor's isolated self-test. It does not open the viewer or Finder. Installed apps, production data/preferences, LaunchAgents and the active inventory QA worker are untouched. No installation, notarization, tag, remote push or hosted release is part of this task.
