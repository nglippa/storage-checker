# On-demand indexing and Atlas

Released in Storage Monitor 3.1.0 (24), 2026-11-13.

Indexing previously depended on monitoring setup because the viewer used the
LaunchAgent's presence and enabled worker state to gate its controls. Its
first-launch presentation offered Enable Monitoring; its request mailbox relied
on that supervisor to start a worker. Atlas itself only reads indexed data.

The viewer now offers Start Index independently of background monitoring. The
app includes the existing indexing engine and runs explicit, bounded
`inventory-index` slices until runnable work drains. It stops on pause, failure,
busy/unknown results, low-space/deferred-only work, timeout or application quit.
Changing the visible drive or section does not redirect or cancel the session.
The engine's file locks serialize it with any scheduled worker. A reliably
observed live background worker can still serve ordinary mailbox requests;
configured, idle or failed monitoring never blocks the app-owned job.

The viewer never writes catalog SQL. Start/resume/recheck/pause use the existing
mailbox; the engine persists and publishes results. Existing catalogs remain
available in Atlas and the browser with monitoring off. No index starts merely
from opening a page. No LaunchAgent installation, notification authorization,
Time Machine operation or permission-setting change is part of Start Index.

External-drive discovery and enrollment are available without enabling
monitoring. Manual indexing resolves and revalidates the selected UUID, its
registered backing, mount lease and dataset identity; it never falls back to the
startup volume or dispatches other drives. Offline, ambiguous, changed or
disabled targets fail closed. Automatic reconnect handling still belongs to
optional background monitoring.

Full Disk Access remains optional. The viewer directs the user to grant access
to Storage Monitor for app-started work; the separately installed monitor has
its own scheduled-work permission context. Missing access remains incomplete
coverage, not a reason to enable monitoring.

## Verification

- On-demand controller and harmless subprocess tests passed: duplicate/QA
  refusal, continuation/drain/failure handling, selected-target retention,
  cancellation, real launch failure/timeout and bounded output capture.
- Viewer/model suite: 1,169 checks passed, including independent first launch,
  retained catalogs and direct recovery guidance with monitoring off.
- Catalog/browser suite: 101 checks passed, including actual `inventory-index`
  against a disposable tree, mailbox wake, and browser/visualization behavior.
- External dispatcher-wave suite: 24 checks passed, including manual selected
  UUID isolation and refusal of paused/unregistered targets.
- External ViewerStore/helper integration suite: 13 checks passed.
- Actual CLI fixture checks confirmed fresh and already-complete catalogs both
  return `continues: false`. A missing external UUID is rejected before a
  catalog is created; malformed external requests cannot fall back to startup.
- Final engine and GUI builds passed with the UUID guard, using SDK 26.5 for
  the viewer. Deep/strict signing verification passed; the embedded indexing
  engine hash matched the freshly built engine. UserNotifications linkage and
  LiveCapacity no-process/SQL guards passed against the final bundle.
- Independent Claude review was checked against authoritative source. It led
  to live-worker PID gating rather than configuration gating, queued drive
  actions during discovery, separate stderr capture, more timeout headroom,
  and explicit quit cancellation. Its possible perpetual-loop finding was
  ruled out by the closing-replay deadline branch and the real CLI drain tests.
  Existing external requests already update the registry pause state; target
  views already have explicit identities, and startup data-directory routing
  was verified and made explicit. Single-folder refreshes use the canonical
  queue and can process other already queued work; they do not remove a pause.
- Native running-app Start Index/Atlas interaction, actual Full Disk Access
  attribution and physical external-drive lifecycle: **NOT VERIFIED**. All
  indexing performed during automated verification uses disposable fixtures.
  An unrestricted user-volume scan has not been run.
