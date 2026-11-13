# Time Machine snapshot requests — upcoming release

Date: 2026-11-13. Released in Storage Monitor 3.1.0 (24), following 3.0.1 (23).

Snapshot Management adds **Request Time Machine Snapshot…**, independent of the
privileged helper and selected volume. Confirmation explains that every APFS
volume included in Time Machine is in scope, macOS chooses names, and Time
Machine controls retention and deletion. Requests can take up to two minutes.

Confirming a request opens its history tab so the result is visible. The viewer
records requests in a private per-user journal, displaying started
and finished times, outcome, reported date token, exit code and bounded output
on demand. Success is labeled **reported created**. Uncertain or interrupted
requests require review and acknowledgement before a new request; no automatic
retry is performed. QA disables requests and never opens the live journal.
Time Machine snapshots remain outside deletion previews and retention tools.

The native snapshot route and privileged helper are unchanged and remain
capability-gated. This change adds no scheduling, snapshot deletion/thinning,
or Time Machine settings changes.

## Verification

- Backend fake-runner suite: passed; this suite never invokes real tmutil.
- `scripts/test-snapshot-model.sh`: APFS and Time Machine model suites passed,
  including off-main execution, duplicate-request busy gating, unavailable
  helper/unsupported volume independence, QA no-command/no-journal-write checks,
  uncertainty acknowledgement, interrupted recovery and error mapping.
- `scripts/test-snapshot-management.sh`: passed, including explicit Time Machine
  exclusion from manual deletion previews and automatic retention.
- `scripts/build-gui.sh` with SDK 26.5: passed (arm64 development bundle); deep,
  strict code-signature verification passed. Build version remains 3.0.1 (23)
  until release preparation assigns the next version.
- `scripts/test-gui.sh`: 1,163 viewer/model checks passed against disposable
  fixtures, followed by passing UserNotifications linkage and LiveCapacity
  no-process/SQL guards. The new Time Machine model checks run through the
  snapshot model script above; no suite invokes the real tmutil runner.
- Rebuilt after the final tab-selection change; the final binary's deep/strict
  signature and both guards passed again. `git diff --check` passed. Focused
  read-only review of model/UI safety and acknowledgement wiring found no
  substantive issues.
- Reviewed `scripts/test-gui.sh`: its no-process/SQL guard applies to
  `SourcesGUI/LiveCapacity.swift`; the fixed tmutil adapter is in
  `SourcesShared/TimeMachineSnapshots.swift`. The UserNotifications linkage
  guard and LiveCapacity guard remain unchanged.
- Native GUI checks passed after explicit operator approval, 2026-11-13
  07:30–07:35 UTC: the request action remained enabled with the helper unavailable
  and an unsupported selected volume; the confirmation exposed the complete
  scope/naming/retention/two-minute text; Cancel dismissed it with zero journal
  entries. A disposable QA database and snapshot fixture showed the request
  action disabled, the QA disclosure, and the empty request-history state.
- Live verification found the default embedded TabView did not expose visible
  navigation on this macOS build. Replaced it with an explicit native segmented
  section picker; rebuilt and verified navigation to Time Machine Requests in
  the running QA app. Final deep/strict signature verification and
  UserNotifications linkage guard passed. Test instances were terminated
  before the approved five-minute desktop window ended.
- After separate explicit approval, exactly one real request was made through
  the development viewer at 2026-11-13 07:38:05 UTC. It returned exit 0 and
  **reported created**, token `2026-11-13-013805`. The journal contains exactly
  one entry. `tmutil listlocalsnapshots /` lists
  `com.apple.TimeMachine.2026-11-13-013805.local`; this token was absent before
  the request. No retry, deletion or Time Machine settings change was performed.
  The root listing confirms that token; every included volume was not separately
  enumerated. [Structured live evidence](artifacts/apfs-snapshot-management/TMUTIL-LIVE-VALIDATION-20261113.json).
- The real populated history automatically opened and displayed **reported
  created**, started/finished times, date token and exit code. Live inspection
  also found that the command-output disclosure was not opening on this macOS
  build; it was replaced with an explicit Show/Hide Command Output button.
  Rebuilt successfully, reopened the same live journal without another request,
  and verified that Show reveals the exact recorded command output and changes
  to Hide. The real history entry survives reopening the app. The final bundle's
  deep/strict signature and UserNotifications linkage guard passed again. The
  development test instance was terminated; the journal still has one request.
- The acknowledgement sheet's native interaction remains **NOT VERIFIED**;
  fake-runner model tests cover its state flow. No synthetic entries were
  planted in live history.
