# Remaining issues and verification limits

Current source: branch `migration-readiness`, committed source `199ece914c991a20b7ededfc845c8e436aaca227`, content fingerprint `19bab05cf59e04ec8dfc8993b0557bf5f9aa82bba8faf5963447f1291fb861d2` across160 named inputs. Version remains **2.2.0 (10)**. Earlier native observations retain their original source identities; the self-test follow-up changes only two CLI/source test files and a private byte-identical capture extraction.

This report supersedes earlier blanket claims that every lifecycle test needs an external Mac. Bounded real installer transactions now work on this Mac. [LOCAL-LIFECYCLE-RESULTS.md](LOCAL-LIFECYCLE-RESULTS.md) separates actual lifecycle/native observations from final-source automated results.

| Area | Status | Remaining evidence |
|---|---|---|
| Disabled queued-work status | VERIFIED | Current 22 new regressions plus actual natural-queue Disable/waiting/OpenSettings/re-enable confirmation; source-pinned captures below |
| Same-Mac install/update/rollback/repair/disable/interruption | VERIFIED for recorded development snapshot | 39 actual launchd assertions and deadline cleanup; older hashes retained, not relabelled current |
| Native Settings enable/repair/disable | VERIFIED for recorded development snapshots | Actual services/history/status observed; the recorded a8eced-source natural-queue waiting and re-enable sequence is also VERIFIED below |
| First-use variants | PARTIALLY VERIFIED | Missing-database setup observed; existing empty catalog/no-generation and final stopped/no-root states need native observation |
| Cleanup/Trash | PARTIALLY VERIFIED | Backend disposable move/restore and safety tests passed; native stale confirmation/refusal/cancel and restore UI remain NOT VERIFIED |
| Accessibility | PARTIALLY VERIFIED | Selected focus/selection/Search and warning readability observed; VoiceOver, full reverse order, actual Reduce Motion/Increase Contrast propagation and larger-text/dark sweep NOT VERIFIED |
| Compact layout | PARTIALLY VERIFIED | Native 1000×694 window and Settings scrolling observed; full error/long-path/theme matrix pending |
| Login/logout, sleep/wake | NOT VERIFIED | Real login persistence and wall-clock gaps need a separately planned disruptive session; explicit bootstrap is not login acceptance |
| Notifications and optional Full Disk Access | NOT VERIFIED | QA suppresses notifications; actual helper consent, delivery and protected coverage need component-specific authorization |
| Packaged ARM and Rosetta CLI self-tests | VERIFIED | Corrected `199ece9` development DMG:238 passed on arm64 and238 on x86_64/Rosetta, actual exits0; [receipt](PACKAGE-VERIFICATION-199ece9.md) |
| Physical Intel/macOS 14 | NOT VERIFIED | Current packaged x86_64/Rosetta238 pass supports emulated execution on Apple silicon/macOS27; physical Intel/macOS14 still needs suitable hardware |
| Performance | PARTIALLY VERIFIED | Functional checks on 8-GiB host; energy, battery, physical input feel and validated peak app RSS unbenchmarked |
| Public release/distribution | NOT ACCEPTED | Current development DMG packaging/CLI checks passed; Gatekeeper REJECTED the ad-hoc unnotarized candidate. No public release or notarization |

No production installation, database, permissions, existing QA runtime or monitoring job was modified to manufacture test states. The task-owned development services were removed. Read-only verification found 6 enabled-override bookkeeping rows across the two known QA scopes (three per scope); all six corresponding labels are absent, not loaded/running services. No override reset/removal was attempted.

The waiting fix adds no polling timer or process. Existing about-30-second samples can take one interval to reflect a state change. App and Settings refresh clocks are not a global rate limiter. Each refresh uses two read-only launchctl calls and at most two 64-KiB log tails. [Historical quiet child probes](evidence/remaining-closure/final-post-checks.json) measured about 2.967–6.863 ms and at most 2 MiB child RSS, not app energy or peak-memory use.

The pathname validation-to-Trash interval remains non-atomic; identity/process/token revalidation remains. No universal safe-cleanup or guaranteed recovered-space promise is made.

The previous approved waiting/recovery confirmation completed, and those grants are consumed. [MANUAL-NATIVE-QA.md](MANUAL-NATIVE-QA.md) identifies remaining system/hardware checks. Use source-pinned QA assets, not the old installed application or DMG. Automated test status is in [REGRESSION-RESULTS.md](REGRESSION-RESULTS.md).

## Recorded native confirmation — VERIFIED for a8eced source, 2026-11-04

The final source `a8eced9f62d5c3a3c54e3bb9840970eb8733a66be77e5ed77d054019652eaa77` and pinned viewer were exercised under the approved app-only grant. Actual Enable registered all three fixture jobs and committed a capacity reading plus a five-node fixture generation. Actual Disable removed all three jobs while retaining the reading and **one naturally pending job**. No synthetic queue or catalog edit was used. The main window showed **Folder updates are waiting**, preserved the browseable tree, exposed Open Settings and showed no first-pass/manual activity indicator. That link opened its own Settings; actual re-enable registered the jobs, advanced recorded readings from one to two, and the main summary became **Inventory is up to date**. Final Disable and independent guard teardown completed by **09:16:17 UTC**, before the 09:17:30 input cutoff / 09:20 hard end. Guard 6502 exited; exact apps/workers and all three jobs are absent, protected files match and no system settings changed.

[Session results](evidence/local-lifecycle/final-neutral-freshness/native-final-confirmation/session-results.json) · [waiting capture](evidence/local-lifecycle/final-neutral-freshness/native-final-confirmation/waiting-main.png) · [recovered capture](evidence/local-lifecycle/final-neutral-freshness/native-final-confirmation/re-enabled-main.png) · [teardown](evidence/local-lifecycle/final-neutral-freshness/native-final-confirmation/teardown.json). Current missing-database setup also reached actual Enable. Empty-catalog/no-generation and disabled-before-root variants, accessibility/system/Trash/hardware limits remain separate.

The initial artifact launch recipe omitted scope-specific temporary directories and was correctly refused before a window. The corrected direct-executable recipe sets only process-local `TMPDIR=<root>/Temporary/` and `SQLITE_TMPDIR=<root>/Temporary`; no admission rule or source changed. Refused-attempt logs are preserved. [Corrected readiness](evidence/local-lifecycle/final-neutral-freshness/NATIVE-FINAL-READY.json) records the recipe and the now-consumed single-use guard.
