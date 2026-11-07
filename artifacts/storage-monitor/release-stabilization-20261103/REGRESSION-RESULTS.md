# Regression results

Current tested source: `199ece914c991a20b7ededfc845c8e436aaca227`, content fingerprint `19bab05cf59e04ec8dfc8993b0557bf5f9aa82bba8faf5963447f1291fb861d2`, version2.2.0(10). All following corrected-source stages exited0 without compiler warnings.

| Corrected-source stage | Checks passed | Duration |
|---|---:|---:|
| Monitor arm64 | 238 | 84.989s |
| Monitor x86_64/Rosetta | 238 | 86.454s |
| Inventory integration | 379 | 393.901s |
| Monitor supplement | 149 | 157.104s |
| Headless browser/controller | 97 | 166.188s |

Readiness-refusal cleanup and deterministic counterexamples passed on both architectures. The new [development DMG](PACKAGE-VERIFICATION-199ece9.md) passed25stock packaging checks, independent image/signature checks and actual packaged238 self-tests on BOTH architectures. Gatekeeper remainsREJECTED; physical Intel/macOS14 and native package installation are not implied.

[Diagnosis](SELF-TEST-DIAGNOSIS-20261105.md) · [source and results](evidence/selftest-diagnosis-20261105/results.json) · [controller/controls](evidence/selftest-diagnosis-20261105/followup-results.json) · [unchanged GUI compiler inputs](evidence/selftest-diagnosis-20261105/gui-input-proof.json).

The previous viewer1149, chart/input52, Inspector10 and structured-filtering36 receipts retain their original identities and are not relabelled new runs. Their relevant compiler inputs are unchanged; the controller was rerun because its monitor runtime changed. The earlier39actual lifecycle assertions and native waiting/recovery observations retain their source identities.

## Historical detailed stabilization receipts — a8eced snapshot

The remainder records the earlier source state and commands. Its old branch/dirty/source labels and235/148 counts describe that historical snapshot, not the corrected source above.


Branch `migration-readiness`, HEAD `6981c2da5ef1c4a1c528332eb0b1be1948721c39`, with uncommitted stabilization changes. Content fingerprint `a8eced9f62d5c3a3c54e3bb9840970eb8733a66be77e5ed77d054019652eaa77` binds 160 source, script, fixture and instruction files. Version remains **2.2.0 (10)**. This 160-file manifest covers the named compiler/test/tooling inputs, fixtures and root instructions/notices; historical151-file manifests had a narrower selection and are preserved separately. It is not a universal artifact checksum.

The fresh GUI stages below ran sequentially against the final frozen source and disposable copy. Core stages retained from the preceding fully passing snapshot are separated in their own table. Before/after hashes guarded both the repository and scratch source. Exact argv/cwd/exit/duration/warnings are in [results.json](evidence/local-lifecycle/final-neutral-freshness/results.json), full logs beside it; [completion receipt](evidence/local-lifecycle/final-neutral-freshness/complete.json).

| Stage | Exit | Duration | Warnings | Final log evidence |
|---|---:|---:|---:|---|
| viewer-model | 0 | 221.946 s | 0 | PASS viewer binary does not link UserNotifications (cannot send notifications); PASS live capacity code launches no process and writes no SQL |
| browser-controller | 0 | 128.739 s | 0 | PASS agreement: all three show the same text (68.72 GB logical, 50.3 MB allocated); 97 inventory model tests passed, 0 failed |
| chart-and-input | 0 | 220.424 s | 0 | PASS Reset restores All, Dim, focus off, isolation off and the entry selection; 52 of 52 hosted chart geometry and scroll routing checks passed |
| inspector | 0 | 44.315 s | 0 | exit: 0; log: /private/tmp/storage-monitor-cleanup-scroll.t1wgDJ/test.log |
| production-default-viewer-compile | 0 | 99.628 s | 0 |  |
| fresh-viewer-linkage | 0 | 0.047 s | 0 | 	/usr/lib/swift/libswiftsimd.dylib (compatibility version 1.0.0, current version 23.0.0, weak); 	/usr/lib/swift/libswiftCoreGraphics.dylib (compatibility version 1.0.0, current version 1.0.0) |
| fresh-viewer-structural | 0 | 0.058 s | 0 | PASS live capacity code launches no process and writes no SQL; 2 current-source structural checks passed |
| diff-check | 0 | 0.079 s | 0 |  |

## Retained core receipts for the two-caption follow-up

The following stages passed on previous fingerprint `78903e63bf4d700bc464dd1c01d7460856bd99d5f3f4f4bfa4f890ca18c4542b`. They are retained with their original hashes, not presented as runs on the latest source. The exact [two-literal delta and compiler-input proof](evidence/local-lifecycle/final-neutral-freshness/retained-core-inputs.json) shows that only unused presentation literals differ among core inputs; neither CLI Sources nor filtering tests call that function. The two added assertions belong only to the freshly rerun viewer suite. [Combined receipts](evidence/local-lifecycle/final-neutral-freshness/combined-results.json).

| Retained stage | Exit | Duration | Warnings |
|---|---:|---:|---:|
| lifecycle-model-safety | 0 | 89.946 s | 0 |
| production-default-monitor-compile | 0 | 83.987 s | 0 |
| monitor-self-test | 0 | 83.968 s | 0 |
| inventory-integration | 0 | 369.106 s | 0 |
| structured-filtering | 0 | 63.087 s | 0 |
| monitor-supplement | 0 | 155.600 s | 0 |

Viewer model: **1,149 assertions**, including **20 new disabled-queue/lifecycle regressions and two neutral freshness-copy regressions**, the existing **190 Trash safety checks**, and embedded Migration Readiness/filtering coverage. Embedded tests are not added twice. Fresh structural/linkage results are distinct from model assertions. Other actual totals are in the final logs above, not historical quotas.

Build SDK: `/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk`; deployment target macOS 14. The current repository's harnesses/flags are used. No explicit signing, packaging, production installation or release stages ran. Hosted chart/Inspector tests use unshown/offscreen views without activation or desktop input.

The original real launchd **39 assertions**, timeout guard and native Settings receipts retain their original hashes in [LOCAL-LIFECYCLE-RESULTS.md](LOCAL-LIFECYCLE-RESULTS.md). Distribution-admission inputs remain exactly unchanged: [scoped proof](evidence/local-lifecycle/final-neutral-freshness/retained-distribution-inputs.json); this is not a whole distribution build or accepted package. Prior x86/Rosetta evidence remains qualified by original inputs and does not prove real Intel/macOS 14.

[REMAINING-ISSUES.md](REMAINING-ISSUES.md) separates native/system/hardware limits. Current waiting-state native acceptance is recorded separately below; model/build results do not substitute for untested accessibility behavior. Pre-local-lifecycle summaries are preserved under evidence/local-lifecycle/final-neutral-freshness/pre-local-lifecycle-reports/.

## Final source-pinned native preparation

Build-only preparation and read-only admission/guard validation passed with no compiler warnings. [Readiness and exact commands](evidence/local-lifecycle/final-neutral-freshness/NATIVE-FINAL-READY.json), [three build receipts](evidence/local-lifecycle/final-neutral-freshness/qa-build-results.json), [scope inspection](evidence/local-lifecycle/final-neutral-freshness/qa-scope-inspection-details.json), [guard validation](evidence/local-lifecycle/final-neutral-freshness/qa-guard-validation.json). All160 content inputs match the final source; the absolute compilation prefix deliberately pins the new runtime. No GUI launch or launchctl mutation occurred. The independent guard is validated but **not armed**.

Temporary window: **Storage Monitor — Lifecycle QA — Disposable Fixtures**. Runtime: `/private/tmp/storage-monitor-lifecycle-l0xllynj/source/build/lifecycle-qa/runtime`. Profile expires **2026-11-04T11:00:10.131371+00:00**; latest start for a ten-minute session is **2026-11-04T10:50:10.131371+00:00**. After that, use the existing preparer and regenerate path/hash-bound readiness/guard; never bypass the lease by editing its expiry. Prior grants remain expired.

## Current native confirmation — VERIFIED, 2026-11-04

The final source `a8eced9f62d5c3a3c54e3bb9840970eb8733a66be77e5ed77d054019652eaa77` and pinned viewer were exercised under the approved app-only grant. Actual Enable registered all three fixture jobs and committed a capacity reading plus a five-node fixture generation. Actual Disable removed all three jobs while retaining the reading and **one naturally pending job**. No synthetic queue or catalog edit was used. The main window showed **Folder updates are waiting**, preserved the browseable tree, exposed Open Settings and showed no first-pass/manual activity indicator. That link opened its own Settings; actual re-enable registered the jobs, advanced recorded readings from one to two, and the main summary became **Inventory is up to date**. Final Disable and independent guard teardown completed by **09:16:17 UTC**, before the 09:17:30 input cutoff / 09:20 hard end. Guard 6502 exited; exact apps/workers and all three jobs are absent, protected files match and no system settings changed.

[Session results](evidence/local-lifecycle/final-neutral-freshness/native-final-confirmation/session-results.json) · [waiting capture](evidence/local-lifecycle/final-neutral-freshness/native-final-confirmation/waiting-main.png) · [recovered capture](evidence/local-lifecycle/final-neutral-freshness/native-final-confirmation/re-enabled-main.png) · [teardown](evidence/local-lifecycle/final-neutral-freshness/native-final-confirmation/teardown.json). Current missing-database setup also reached actual Enable. Empty-catalog/no-generation and disabled-before-root variants, accessibility/system/Trash/hardware limits remain separate.

The initial artifact launch recipe omitted scope-specific temporary directories and was correctly refused before a window. The corrected direct-executable recipe sets only process-local `TMPDIR=<root>/Temporary/` and `SQLITE_TMPDIR=<root>/Temporary`; no admission rule or source changed. Refused-attempt logs are preserved. [Corrected readiness](evidence/local-lifecycle/final-neutral-freshness/NATIVE-FINAL-READY.json) records the recipe and the now-consumed single-use guard.
