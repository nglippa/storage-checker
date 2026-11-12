# Swap-counter presentation follow-up

Date: 2026-11-12. Source changes following the published 3.0.0 build 22, prepared
for the separately authorized 3.0.1 build 23 release. Packaging and publication
results are recorded in [the release record](../../STORAGE-MONITOR-3.0.1-RELEASE.md).
No installation was performed during this follow-up.

## Behavior

The 3.0.0 observer already collects `sysctl vm.swapusage` allocated and used bytes
near startup capacity readings when a VM-role volume is present. This change
uses those persisted counters in VM growth/recovery explanations, likely-cause
support, system signals and technical evidence. It displays separate before/after
allocation and usage values with signed changes. The Swap Changes filter now
includes usage changes within unchanged allocated swap.

Pairs must belong to the capacity readings and container, pass continuity,
duration and reboot/uptime checks, and have both endpoints for the displayed
counter. A missing used-byte pair does not discard a valid allocation pair.
Current values remain baselines when a valid pair is unavailable. Matching
allocation is classified as correlation; VM and swap bytes are not added as
independent causes, and no responsible application is inferred.

The supplied Nov 11 20:00–20:30 event predates per-reading counters in that history.
Its +2,147,483,648-byte VM allocation change remains a measured fact, but this
change cannot retrospectively establish its swap-allocation or usage delta.
Existing alert-triggered diagnostic comparisons keep their own intervals.

## Files

- `SourcesGUI/DiagnosticAnalysis.swift`: counter pairing, summaries, VM support
  and exact current values in technical evidence.
- `SourcesGUI/Models.swift`: allocation/usage filtering with interval validation.
- `tests/SwapCounterPresentationTests.swift`, `scripts/test-swap-counters.sh`:
  focused regression suite.
- `tests/GUIModelTests.swift`, `README.md`: legacy wording expectation and usage.

## Validation and limits

The regression cases cover growth/recovery, unchanged allocation, usage-only and
missing counters, mismatches, legacy history, reboot/uptime reversal, long gaps,
capacity changes, collection duration, timestamp/container alignment, filtering
and exact-byte evidence. Initial failing runs established the missing paired
explanation, omitted usage-only filter result, and misaligned-filter result.

Final command results (exit 0):

| Command | Actual result |
| --- | --- |
| `scripts/test-swap-counters.sh` | 32 checks passed on the final sources |
| `scripts/test-gui.sh` | 1,163 GUI model/read-only checks passed; notification-linkage and read-only live-capacity checks passed |
| `scripts/test-snapshot-integration.sh` | 52 integration checks passed; no collector/schema changes in this follow-up |
| `STORAGE_MONITOR_SDK_PATH=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk scripts/build-gui.sh` | Viewer and ad-hoc service built; service mutation capability remains disabled |
| `sh -n scripts/prepare-apfs-platform-probe.sh scripts/test-swap-counters.sh` and `git diff --check` | Passed |

Temporary logs use the `/private/tmp/storage-swap-counter-` prefix. All fixture
databases are disposable. No tests ran mutations against user-drive snapshots.

## Interactive GUI verification

After renewed explicit user authorization, exercised the final development app
at 1000×640 with three disposable synthetic databases. These are test histories,
not observations of actual swap growth on the user's Mac.

- Growth in dark appearance: expanded explanation shows allocated 2.00 → 5.00 GB
  (+3.00 GB) and used 0.50 → 1.50 GB (+1.00 GB); correlation and unknown-app
  qualifications remain. Swap Changes returns one of the two recorded events.
- Usage-only change in light appearance: allocated 2.00 → 2.00 GB (0 B), used
  +1.00 GB. The event remains in Swap Changes, and the explanation says these
  counters do not explain the VM allocation change. No matching correlation is
  asserted. The full explanation wraps and is reachable through scrolling.
- Legacy history without observations: explanation says the counter change
  cannot be reconstructed. Swap Changes returns zero events and clears details.
- Copy Details was invoked in each app window. The resulting copied fixture text
  was checked: growth/usage preserve both pairs and the source, unknown-app
  qualification remains, and legacy output invents no swap values. Copies remain
  under `/private/tmp/storage-swap-counter-gui/`.
- Cmd-F focuses the labelled search field; Tab then Down moves selection from the
  loss event to the baseline reading and updates the inspector. Disclosure and
  filter controls expose labels and states; the cause's accessibility description
  includes the complete paired counter evidence.
- Original All Events / Last 30 Days development filter settings were restored,
  and each owned QA application was quit. No production database, installed
  application, worker or LaunchAgent was changed.

**VoiceOver speech, reading order and announcements remain NOT VERIFIED.**
`NSWorkspace.isVoiceOverEnabled` was false before and after the app-bound
Command-F5 attempt; that shortcut did not enable the screen reader through this
automation interface. Accessible labels are observed evidence, not a substitute
for spoken-output testing. No system accessibility setting was changed.
