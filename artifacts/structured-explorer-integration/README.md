> **2.2.0 release integration, 2026-10-29:** This work is now authorized for commit, merge to master and DMG packaging. The stabilization fixes and [latest native acceptance](stabilization/native-qa-20261029T172929/NATIVE-RESULTS.md) supersede the initial native-session findings below. Full native acceptance remains partial; see [the 2.2.0 release record](../../STORAGE-MONITOR-2.2.0-RELEASE.md). Earlier milestone/authorization statements are historical. Generated screenshots, logs, databases, preferences and other raw QA artifacts are retained locally and are not part of the source commit.

> Native QA is complete (9m32.94s); the app is closed and QA preferences restored. **Acceptance is BLOCKED.** See [native results and final matrix](native-qa/NATIVE-RESULTS.md) for the 1.52–2.72 s hierarchy delay, minimum-window caption crowding, and incomplete hover/gesture/targeting checks.

# Structured Explorer — integration review

Prototype B is integrated as the default Living Tree in the uncommitted `integration/structured-explorer` worktree. This is an implementation/test milestone, not a release. The protected RC, DMG, research sources, installed apps, production data and background workers remain untouched.

- [Full integration report and requirement status matrix](INTEGRATION-REPORT.md)
- [Visual comparison board](visual-comparison/integration-board.png)
- [Full-resolution production-view captures](headless-renders/)
- [Machine-readable performance measurements](measurements.json)
- [Native QA outcomes and remaining checks](NATIVE-QA.md)
- [Regression/provenance logs](verification/)
- [Completed native-session launch record](verification/native-review-ready.json)

Passed suites: viewer 934, monitor 235, inventory 350, inventory-browser 67, hosted chart/input/state 24. Benchmark: 43 assertions, zero failures. Both development apps pass strict code-signature verification. Final offscreen pan/zoom p95 is 2.18/1.99 ms; this is not native display pacing or cold-start acceptance.

The original Living Tree remains selectable with the `classic` renderer preference in the development/QA domain. Full rollback and review instructions are in the report. The authorized native session used only the verified QA PID/window and is now finished. Further native testing requires fresh permission; VoiceOver remains unverified and was not activated.
