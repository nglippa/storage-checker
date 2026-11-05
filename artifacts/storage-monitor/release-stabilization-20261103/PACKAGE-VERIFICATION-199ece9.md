# Corrected development DMG verification — 2026-11-05

Packaged source: `migration-readiness` commit `199ece914c991a20b7ededfc845c8e436aaca227`; content fingerprint `19bab05cf59e04ec8dfc8993b0557bf5f9aa82bba8faf5963447f1291fb861d2` (160 named inputs). This later documentation-only commit does not change the packaged compiler inputs. Version remains **2.2.0 (10)**.

**The corrected packaged full self-tests passed on arm64 and on x86_64 under Rosetta: 238/238 each, with actual exit zero. Gatekeeper remains REJECTED; this ad-hoc, unnotarized candidate is not public-release acceptance.**

## Artifact

- File: `build/dist/Storage-Monitor-2.2.0-selftest-fix-199ece9-20261105.dmg`
- Size: **16,923,096 bytes**
- SHA-256: `624f239edba086c5b759d313b8ecee0796c23d0a2427c0ce7bacfa642e62c4f1`
- Portable checksum: same filename plus `.sha256`; copied image/checksum verified without overwriting existing artifacts.
- Universal arm64+x86_64 viewer and helper; minimum macOS 14.0 in both architectures and Info.plists.
- Stock universal build used SDK 26.5, existing ad-hoc signing and verification enabled. Exit0, **614.577s**, compiler warnings0. All **25 existing package checks passed**, including the bundled238 self-tests.
- Both independent packaged self-test runs were sequential with no build running. No retries were needed.

## Independent checks

| Stage | Exit | PASS lines | Duration |
|---|---:|---:|---:|
| `portable-sidecar` | 0 | 0 | 0.142s |
| `image-integrity` | 0 | 0 | 4.026s |
| `readonly-mount` | 0 | 0 | 0.201s |
| `viewer-architectures` | 0 | 0 | 0.134s |
| `viewer-minimum-os` | 0 | 0 | 0.046s |
| `monitor-architectures` | 0 | 0 | 0.021s |
| `monitor-minimum-os` | 0 | 0 | 0.024s |
| `strict-signature` | 0 | 0 | 0.083s |
| `signature-details` | 0 | 0 | 0.012s |
| `distribution-qa-refusal` | 1 | 0 | 0.094s |
| `packaged-self-test-arm64` | 0 | 238 | 84.208s |
| `packaged-self-test-x86_64` | 0 | 238 | 87.387s |
| `gatekeeper` | 3 | 0 | 0.452s |
| `detach-owned-mount` | 0 | 0 | 0.074s |

Lifecycle-QA flags were explicitly refused before initialization; this expected exit1 is a passing fail-closed check. Gatekeeper exit `3` is recorded as actual rejection rather than converted to distribution acceptance. Strict signature validity is distinct from notarization/trust.

## Diagnosis and regression evidence

The [self-test diagnosis](SELF-TEST-DIAGNOSIS-20261105.md) explains the producer-readiness assumption and the broad wall-clock fixture timer. It preserves uncertainty about the exact historical failed conjuncts. The original [3670499 package failures](PACKAGE-VERIFICATION-3670499.md) and image are historical evidence and were not rewritten or deleted.

The corrected source passed **238 monitor checks on each architecture**, **379 inventory integration**, **149 supplemental monitor** and **97 headless controller** checks. Readiness-refusal cleanup and deterministic counterexamples passed on both architectures. The100ms capture deadline,16-byte cap, busy result and three-active-second collector guard were retained. No production timeouts/locks/clock policies were changed; the shared capture body is byte-identical. GUI/model/chart/Inspector source inputs are unchanged and their old receipts retain their original identities.

## Boundaries

All owned mounts detached. All10 pre-existing DMG/checksum file hashes across the two checkouts remained unchanged. No GUI launch, production installation/monitoring/database/permissions change, cache reset, Gatekeeper bypass, notarization, release upload or publication was performed. Raw power/activity logs remain local only.

Rosetta validates the packaged Intel slice on this Apple silicon host; it is not physical Intel/macOS14 execution. Packaged first launch/installation/quarantine acceptance, remaining native accessibility and system lifecycle checks remain NOT VERIFIED. See [current limits](REMAINING-ISSUES.md).

[Machine-readable receipt](PACKAGE-VERIFICATION-199ece9.json).
