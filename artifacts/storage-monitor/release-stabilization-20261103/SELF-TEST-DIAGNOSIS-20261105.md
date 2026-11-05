# Monitor self-test diagnosis and correction — 2026-11-05

Base: `migration-readiness` at `b2deb98e34cb4600ea4348afde072efef432bf79`. The original package was built from `367049910dce2fec3700c9a86f916f09488fe623`; it and its failed-run logs remain unchanged.

Corrected source content fingerprint: `19bab05cf59e04ec8dfc8993b0557bf5f9aa82bba8faf5963447f1291fb861d2` (the same 160 named inputs; only `Sources/StorageMonitor.swift` and `Sources/Attribution.swift` changed).

## What the failures established

The original errors combined multiple conditions and omitted their values. Their exact failed conjuncts cannot be reconstructed. Calling the failures a proven Rosetta defect or a proven premature lock release would be inaccurate.

Two same-order, optimized x86 diagnostic runs of the old conditions completed 235 checks. They measured timeout=true, truncation=true and 16 captured bytes for the continuous producer, and a busy collector with its descriptor held and roughly 0.52–0.53 seconds of actual work. No premature unlock, unbounded wait, or capture overflow was reproduced.

Two test-design defects were independently identified:

1. A newly spawned producer was assumed to have produced more than 16 bytes before a 100 ms capture deadline. A legitimate timeout before readiness does not imply truncation or a full 16-byte capture. The fixture never established its premise, and the failed result did not print the three conditions.
2. The three-second busy-collector assertion started its Date timer before SQLite reopening and event-marker preparation, counting unrelated fixture work and machine sleep. Read-only historical power evidence confirms that the original retry overlapped substantial Sleep/Dark Wake intervals. It is not a valid isolated measurement of the collector's active lock wait. Raw power/activity logs remain local and are not included in the committed evidence.

## Correction without weakening protections

- The existing capture loop was extracted into a private helper, byte-for-byte unchanged. Public `run` signature, defaults, launch, nonblocking setup, absolute Date deadline placement, bounded draining, termination/grace/SIGKILL behavior, reaping, and stream closure remain unchanged. No production timeout, clock or lock policy was changed.
- The continuous fixture launches a real `/usr/bin/yes`, uses a non-consuming pipe query to require more than 16 buffered bytes within a bounded ten-active-second fixture allowance, and then exercises that same capture engine with the original **100 ms deadline and 16-byte cap**. It still requires timeout, truncation and exactly 16 bytes, and now also requires the producer PID to be reaped.
- Darwin's FIONREAD request was verified against the actual SDK C constant and on both arm64 and x86_64 pipes. No C shim, new shipped dependency, public API or CLI test command was added.
- The public no-output timeout case explicitly verifies that an empty, non-truncated capture is valid when the deadline arrives before output.
- The busy fixture prepares SQLite and its marker before timing the collector; verifies lock ownership; explicitly retains the fixture lock across the call; and keeps the original busy-result and three-second guard measured with `SuspendingClock` active time. Its configured lock wait remains 0.5 seconds.
- Failure messages now include timeout/truncation/byte counts or busy status/active elapsed time. Three additional assertions bring the full monitor suite from 235 to **238**.
- An independent readiness-refusal regression forces an unready producer and verifies termination/reaping on both architectures. This tests cleanup on preparation failure rather than deleting or bypassing that path.

Apple documents [SuspendingClock](https://developer.apple.com/documentation/swift/suspendingclock/suspending) as excluding system sleep. [withExtendedLifetime](https://developer.apple.com/documentation/swift/withextendedlifetime(_:_:)-4mmpv) preserves the fixture owner during the closure. These changes apply to test setup/timing, not production lock behavior.

## Recorded verification

All commands below use disposable fixtures and no desktop interaction. Results remain tied to their source fingerprint; diagnostic old-source passes do not replace the corrected-source results. No assertions, timeouts, OS settings or Rosetta caches were relaxed or reset.

| Stage | Exit | PASS lines | Duration |
|---|---:|---:|---:|
| `compile-fixed-arm64` | 0 | 0 | 120.387s |
| `compile-fixed-x86_64` | 0 | 0 | 82.256s |
| `compile-readiness-cleanup-arm64` | 0 | 0 | 0.937s |
| `compile-readiness-cleanup-x86_64` | 0 | 0 | 0.717s |
| `readiness-refusal-cleanup-arm64` | 0 | 1 | 0.488s |
| `fixed-full-self-test-arm64` | 0 | 238 | 84.989s |
| `readiness-refusal-cleanup-x86_64` | 0 | 1 | 2.049s |
| `fixed-full-self-test-x86_64` | 0 | 238 | 86.454s |
| `inventory-integration` | 0 | 379 | 393.901s |
| `monitor-supplement` | 0 | 149 | 157.104s |
| `source-diff-check` | 0 | 0 | 1.745s |
| `compile-delayed-producer-arm64` | 0 | 0 | 0.257s |
| `compile-counterexamples-arm64` | 0 | 0 | 1.556s |
| `compile-delayed-producer-x86_64` | 0 | 0 | 0.082s |
| `compile-counterexamples-x86_64` | 0 | 0 | 0.868s |
| `counterexamples-arm64` | 0 | 2 | 4.194s |
| `counterexamples-x86_64` | 0 | 2 | 5.625s |
| `headless-browser-controller` | 0 | 97 | 166.188s |

All planned stages above completed with exit zero and no compiler warnings. GUI/model/chart/Inspector compiler inputs are unchanged; their previous receipts retain their own identities. The browser/controller suite was rerun because its monitor runtime input changed. Final packaging and push provenance are recorded separately after the source fix is committed. Version remains 2.2.0 (10); signing/notarization policy and existing package security checks are unchanged. Physical Intel/macOS 14 and native installation acceptance remain distinct from Rosetta CLI coverage.
