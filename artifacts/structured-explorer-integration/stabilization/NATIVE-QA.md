# Native QA — stabilization

> **Native update, 2026-10-29:** The authorized session is complete; full acceptance remains partial. See [native results](native-qa-20261029T172929/NATIVE-RESULTS.md) for measured outcomes, incomplete checks and verified cleanup. The original implementation-phase record below is retained. Automated suites were not rerun during native QA.

**No native GUI check ran in this phase.** AGENTS.md requires explicit operator approval before any app launch, window focus or desktop input. Nothing below is VERIFIED natively. This is the plan for one final, controlled session.

## Approval requested

| Item | Value |
|---|---|
| App | `~/storage-checker-structured-explorer/build/Storage Monitor.app` (rebuilt this phase, strict signature verified) |
| Bundle identifier | `local.macbook.storage-monitor.viewer.dev`, version 2.1.0. Checked from the bundle and from the running process before any input. |
| Preferences | QA domain `local.macbook.storage-monitor.viewer.qa`, snapshotted before launch, restored and compared after exit. Production domain untouched. |
| Catalog | New APFS clone (`cp -c`) of `build/inventory-fresh-20261023T031313Z/previous-catalog.sqlite3` under a private `/private/tmp` folder. The snapshot is read only; the clone and the QA request queue are deleted after exit. |
| Window | One window titled *Storage Monitor — QA: …*. PID and window ID recorded at launch; the window is brought forward once at launch. |
| Duration | ≤ 12 minutes, one session, with a focus guard that stops on any frontmost-PID/bundle/title mismatch (as in the previous session's `safety-guard.swift`) |
| Excluded | Trash, cleanup, background worker, LaunchAgents, Full Disk Access, global settings, VoiceOver, other apps' windows |
| Cleanup | Quit only the launched QA PID; restore QA preferences; delete the clone; record SHA-256 of the snapshot before and after. |

**Physical input.** The operator's own hands on a physical mouse wheel and trackpad give the only valid evidence for "physical device" items. Automated events would be reported as *injected*, not *physical*.

## Ordered checks (strictly sequential: input, then wait for the logged effect, then capture)

The performance trace is enabled for the session. Every navigation is judged from `folder.open` → `frame.committed` → `livingTree.read` completion lines, never from screenshots.

1. **Navigation latency (P0).** Repeat Explore and Up five times each across two large folders. Pass: tree replaced ≤ 300 ms warm and ≤ 200 ms Up, with no 1–3 s delay while "Updating older measurements" is shown.
2. **Monitoring hover (P0).** On the 30-day chart, move to five readings including the last third. Log pointer coordinates against reading positions. Pass: callout with time, available space and change appears within one move, holds while dwelling, the plot never resizes, it clears over empty plot and on exit, and a click still opens the event. Repeat at the minimum window, in light and dark.
3. **Minimum window (P1).** At the enforced 1000×692 minimum, check that ring captions don't collide or clip, labels stay readable, and the selected label stays visible. Repeat with the Inspector expanded.
4. **Scroll (P1).** Wheel forward and reverse, both changing zoom past 100%. Trackpad scroll both ways, pinch, sideways pan, Shift/Option pan, momentum, both zoom limits, and scrolling over the Inspector.
5. **Double-click and Return (P1).** Double-click a disc and a label, at 1× and zoomed, and check the opened folder equals the one clicked. Click to select then press Return: one navigation. Return with the Search field focused does not open a folder. Escape and Up go to the parent once.
6. **Classic fallback.** Launch-only argument `-inventory.livingTree.renderer classic`, then without it. Selection and folder are kept, and no stale overlay remains.

## Unverified until that session

Physical wheel and trackpad, pinch, smart magnify, inertia. Native hover delivery. Return/Escape keyboard focus. Minimum-window and expanded-Inspector appearance in light and dark. Native first-visible-frame timing and section-switch latency (Storage ↔ Monitoring). VoiceOver, larger text and increased contrast remain unverified and are not part of this plan unless requested.
