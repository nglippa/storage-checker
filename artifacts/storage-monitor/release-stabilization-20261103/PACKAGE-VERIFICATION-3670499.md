# Development DMG verification — 2026-11-04

> Historical candidate: its failures below are preserved. The corrected source/candidate is verified separately in [PACKAGE-VERIFICATION-199ece9.md](PACKAGE-VERIFICATION-199ece9.md).

Source: committed `migration-readiness` at `367049910dce2fec3700c9a86f916f09488fe623`; content fingerprint `a8eced9f62d5c3a3c54e3bb9840970eb8733a66be77e5ed77d054019652eaa77` (160 named inputs). This is a later documentation-only record; the DMG contains the source commit, not this later report commit.

**Development candidate only: Gatekeeper REJECTED; the additional Rosetta full self-tests FAILED twice. No public-release acceptance is claimed.**

## Artifact

- Local file: `build/dist/Storage-Monitor-2.2.0-stabilization-3670499-20261104.dmg`
- Version/build: **2.2.0 (10)**, unchanged; no new release version selected.
- Size: **16,900,513 bytes**
- SHA-256: `c3f900c652029ccd23d9ebb28df048459c1c1fc171ff7caab02b07e1ec612af5`
- Universal viewer/helper: arm64 + x86_64, minimum macOS 14.0 in metadata and both Mach-O slices.
- Existing ad-hoc signatures verify. No Developer ID, hardened-runtime change or notarization.
- Image and portable `.sha256` sidecar are local ignored build artifacts, not committed or uploaded.

## Build and checks

The unmodified packaging script ran in an independent local clone pinned to the source commit with SDK 26.5, both architectures, the unique image name, ad-hoc identity `-` and the source commit timestamp. Verification remained enabled. Exit **0**, duration **674.279s**, compiler warnings **0**.

| Check | Result | Duration |
|---|---|---:|
| Existing noninteractive DMG verifier | 25/25 passed, including its bundled 235 self-tests | Included in build |
| Independent SHA-256 sidecar | Passed; exit 0 | 0.069s |
| Independent hdiutil image verification | Passed; exit 0 | 3.275s |
| Strict nested signatures | Passed; exit 0 | 0.040s |
| Distribution lifecycle-QA admission | Correctly refused (exit 1), before initialization | 0.021s |
| Independent packaged arm64 self-tests | 235 passed; actual exit 0 | 84.769s |
| Packaged x86_64 / Rosetta attempt 1 | **FAILED; exit 1** | 1.517s |
| Packaged x86_64 / Rosetta attempt 2 | **FAILED; exit 1** | 37.697s |

## Unresolved translated-suite failures

1. Initial x86_64 attempt: `Storage Monitor: FAIL: continuous output cannot starve deadline or exceed capture cap` (exit 1, 1.517s). Its assertion requires timeout, truncation and exactly 16 output bytes from a 100-ms continuous-output command; the failing conjunct was not printed.
2. One identical quiet retry: `Storage Monitor: FAIL: scheduled check skips folder evidence after a bounded wait while the baseline is busy` (exit 1, 37.697s). This assertion requires a busy folder result and total elapsed time under three seconds; the failing conjunct was not printed.

Cold translation or timing sensitivity is an inference, not a proven explanation. An external x86 probe using the exact committed process runner observed three timed-out, truncated 16-byte outputs with reaped children. A focused full collector probe observed four busy results, valid held descriptors and waits of 522–550 ms, with and without explicit lifetime extension. No premature unlock was reproduced. Those probes **do not replace the failed full suite**. No source, assertion, timeout, Rosetta cache or OS setting was changed; no further full-suite retries were run. Rosetta was already installed.

Both complete failed stdout/stderr logs, probe results and command metadata are committed under `evidence/package-3670499/`. The ARM run captured its actual exit and count independently of the existing verifier's final-line pipeline.

## Distribution and acceptance limits

Gatekeeper assessment: **REJECTED**, exit **3**. Its informational status in the existing verifier was not weakened or changed. This ad-hoc, unnotarized package is not public-release ready.

The image was mounted read-only with `-nobrowse -noautoopen`; every owned mount was detached. No viewer launch, drag installation or production setup was performed. Eight existing DMG/checksum files retained their prior hashes; the new artifact was copied without overwriting any existing file and its copied sidecar verified. Production monitoring, databases, permissions and installed apps were not modified.

Packaged native first launch/setup/update/rollback and quarantine behavior remain **NOT VERIFIED**. The prior source-pinned disposable native observations are separate. Physical Intel/macOS 14, full accessibility and remaining system lifecycle acceptance remain pending. See [remaining checks](REMAINING-ISSUES.md).

[Machine-readable receipt](PACKAGE-VERIFICATION-3670499.json) contains exact commands, environment overrides, exits, durations, binary hashes and limitations. Full local build logs remain outside Git.
