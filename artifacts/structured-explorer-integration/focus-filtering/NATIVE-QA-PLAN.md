# Native QA plan — PENDING, not authorized to launch

No native window has been launched, focused or operated for this milestone. Headless renders and direct in-process event tests do not establish physical input or VoiceOver behavior. Request explicit approval for the exact development QA window and a bounded session before executing this plan.

## Setup and guard

- Freshly rebuilt development viewer, unique copied QA bundle/name/identifier; never the installed or protected release app. Verify executable hash, strict signature, bundle identifier and title before use.
- Disposable APFS clone under `/private/tmp`, passed with `--database-path`. Confirm QA banner/title and Trash disabled. Never redirect to production data or bypass the guard.
- Use QA preferences routing; snapshot and restore that domain on exit. A different bundle name alone does not isolate preferences. Confirm production preferences remain unchanged; no global appearance/keyboard/accessibility settings without specific authorization.
- Suggested session: 15 minutes in one named window. Record actual PID, executable, database and unique title. Confirm exact ownership before every input; stop on mismatch. No refocusing or manipulating another window.
- Start at standard size in dark appearance; repeat relevant checks in light and at enforced minimum size. Keep a dense existing hierarchy and a repeated-name path available.

## Acceptance matrix — every row currently NOT VERIFIED natively

| Area | Operator actions / expected observation |
|---|---|
| Size | All, exact 100/500 MB and 1/5/10 GB presets; custom decimal MB/GB; invalid/zero/negative/overflow rejected without changing active threshold; unknown size explained |
| Dim / hide | Same positions, colors and sizes; nonmatches recede in Dim; disappear in Hide except real context/selection chains; counts match their stated bounded scope |
| Selection exception | Select a small folder then raise threshold; folder and actual ancestor chain stay recognizable, below-filter explanation visible; Inspector path/size unchanged |
| Focus | Selected folder/ancestors/descendants emphasized; unrelated branches around 20%; path-to-root mode continuous; light/dark selection remains clear |
| Pointer targets | Overlapping faded labels/discs do not steal emphasized targets; direct faded-disc click selects predictably; hidden targets cannot be clicked |
| Context menus | Right-click multiple folder nodes and labels: Isolate This Path, Show Path to Root, Focus on Selection, Clear Focus / Isolation target the clicked folder; cancellation leaves selection unchanged |
| Isolation | Folder is visual root with true path/ID/size; breadcrumb context and Exit visible; nested isolation, Up, Return/double-click and exit/reset restore expected context and entry selection |
| Bounded content | A folder whose descendants are not loaded has an explanatory state and an explicit indexed-folder exploration route; no silent blank canvas or filesystem scan |
| Camera/navigation | Click, double-click, Return, Escape/Up, breadcrumb, Fit, Reset View, filter Reset; zoom/pan preserved; no repeated 1–3-second delays |
| Physical input | Real wheel zoom both directions/limits; actual trackpad vertical/sideways scroll, pinch, inertia and drag pan; changes do not trigger selection unexpectedly |
| Keyboard | Tab through controls; menus/custom editor Apply/Cancel; focus/isolation/reset actions; canvas arrows skip hidden nodes; Return in search stays in search |
| Synchronization | Inspector and Navigator share selected inventory ID; selected path remains true; outside-isolation selection/navigation exits isolation predictably |
| Layout | Minimum/standard/wide windows, both appearances; no clipped controls, unreadable exception text, colliding labels or distracting transitions |
| Accessibility | VoiceOver control names/values, active filter and selected exception, path/isolation/reset actions; no opacity-only state. Record spoken output if authorized; otherwise pending |
| Classic fallback | Existing QA renderer preference switch and return: classic controls/selection/camera intact; Structured filters resume without catalog rebuild; no stale input menu |

## Evidence and cleanup

Record actual action/results, timestamps and screenshots of the named QA window only. Measure folder-open to tree-read/visible result separately from headless computation, and record missed targets. Restore QA preferences, stop only owned QA processes under the session grant, preserve logs and verify snapshot/release/production preference hashes. Do not package, install, commit or promote. A pending or failed row is not a release pass.
