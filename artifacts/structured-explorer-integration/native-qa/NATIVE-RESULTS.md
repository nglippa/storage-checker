# Authorized native QA — 2026-10-29

The single authorized session lasted **572.94 seconds (9 minutes 32.94 seconds)**. The QA process is closed and its QA preference domain is restored exactly. No further desktop input or application launch follows this session. The disposable catalog and QA-local inventory-request queue were removed after the process exited; evidence remains preserved.

## Safety and identity

- App: integration worktree's `build/Storage Monitor.app`.
- Bundle identifier: `local.macbook.storage-monitor.viewer.dev` (checked from bundle and running application).
- PID: **63381**; native window ID **67406**.
- Focused title: **Storage Monitor — QA: structured-explorer-native.sqlite3**.
- Catalog: private disposable APFS clone recorded in `session.json`; no production catalog used.
- Preferences: `local.macbook.storage-monitor.viewer.qa`, isolated from production; snapshot before launch, restored after process termination, and property-list dictionaries compared equal (3 original keys).
- The exact frontmost PID, bundle and focused title were checked before each input. A separate guard checked focus every 100 ms, with a timed shutdown. No focus-safety stop occurred. Stop reason was `requested completion`.
- No other app/window was controlled. No VoiceOver activation, accessibility setting changes, Trash operations, installation, packaging, merge, commit, push, release or background-worker changes.

Evidence: `session.json`, `stopped.json`, `results.json`, `restored.txt`, before/after preference snapshots (private), AX snapshots, `native-performance.log`, native PNGs and `safety-guard.swift`.

## Final native acceptance matrix

| Requested check | Status | Actual result |
|---|---|---|
| 1. Structured Explorer node and label selection | VERIFIED | Native clicks produced Users and Applications selections. AX descriptions gained the selected state; matching Navigator rows and Inspector names/sizes were observed. |
| 2. Physical mouse wheel / trackpad where available | PARTIALLY VERIFIED | Injected native scroll increased zoom from 100% to 102%. A later reverse-scroll attempt still reported 100%, so zoom-out was not positively verified. Physical device use, pinch, smart magnify and trackpad momentum were not verified. |
| 3. Pan, double-click recenter, Fit, Reset, Up | PARTIALLY VERIFIED | Drag moved the root 70×30 pt without changing Applications selection. Fit reached 302%; Reset returned to 100%. A double-click sequence opened VMware Fusion.app (node 115), then Up reached Applications (15), then Startup Data (1). Intended double-click target accuracy was not conclusively established. Return was sent during pending navigation and was not independently verified. |
| 4. Navigator / Inspector synchronization | VERIFIED | Selected Users and Applications agreed across canvas, highlighted Navigator row, and Inspector path/size. Selection remained Applications during pan/Fit/Reset. |
| 5. Monitoring hover stability / flicker | BLOCKED | The 30-day chart displayed 29 readings. Eight native chart crops during one dwell were pixel-identical, and no flicker was observed in those sampled frames. However, the expected hover callout did not appear during the automated pointer attempts; this does **not** prove hover/flicker acceptance. A positive native hover test remains required. |
| 6. Minimum layout / navigation responsiveness | BLOCKED | Requested 1000×640 was clamped by the app to 1000×692. Controls, Inspector and Navigator remained available; ring captions crowded/overlapped in the compressed canvas. Navigation first frames were 43–77 ms, but the first matching tree-read completion followed folder navigation by 1.52–2.72 seconds while the previous tree remained visible. |
| 7. Classic fallback and return to Structured Explorer | VERIFIED | Changed only the QA renderer preference. Classic appeared with View Selection/Isolate controls and was captured. Switching the QA preference back and revisiting Storage restored Structured Explorer controls/canvas; no app restart or production preference change. |

## Defects and acceptance gaps

### NQ-1 — delayed hierarchy replacement (acceptance blocker)

The breadcrumb/inventory changed before the hierarchy replaced the old root. The immediate native snapshots after attempted exploration still showed the prior tree; later snapshots showed the new root. Instrumentation recorded:

| Navigation | First committed frame | First matching tree-read completion after open | Read work itself |
|---|---:|---:|---:|
| Open node 115 (VMware Fusion.app) | 77 ms | 2176.7 ms | 40.4 ms |
| Up to node 15 (Applications) | 43 ms | 1522.3 ms | 195.5 ms |
| Up to node 1 (Startup Data) | 46 ms | 2723.3 ms | 74.4 ms |

These delays are instrumentation bounds, not exact first visible tree-pixel timestamps. The catalog retained pending reconciliation work, and the UI said “Updating older measurements”; polling/rebuilds continued during the session. The cause has **not** been diagnosed, and these results should not be generalized to every catalog. They are enough to withhold fast-navigation acceptance in this tested state. The offscreen 2 ms frame figures do not cover this delay.

### NQ-2 — crowded ring captions at minimum size (UI defect)

At the enforced 1000×692 window, the hierarchy became tightly compressed and level captions crowded/overlapped. The ordinary label plates and essential controls remained readable. Ring captions are not covered by the existing label-plate collision tests. See `07-minimum-structured.png` and `minimum-window-ax.json`.

### NQ-3 — hover and reverse-scroll acceptance not established (test gaps)

The native chart was visible and stable in sampled images, but pointer attempts did not produce a visible callout. The session cannot distinguish input-delivery/targeting limitations from an application hover issue. Do not label this a confirmed hover implementation defect or a flicker pass. Similarly, the reverse-scroll attempt produced no observed zoom change and needs a deliberate native retest.

### NQ-4 — double-click targeting and Return need a controlled retest

Native logging proves a double-click sequence reached folder navigation for node 115. It does not prove the earlier Applications target attempt opened Applications: the intended target and the actual point under the pointer were not conclusively matched after selection/camera changes. Return was sent while navigation was already pending; no separate folder-open event establishes its success. These remain partial/untested rather than confirmed input defects.

An earlier progress update described Return too broadly. The event log is authoritative: only the double-click folder-open and subsequent Up events are established.

## Remaining limitations

Physical mouse/trackpad hardware, native pinch/momentum, VoiceOver, increased-contrast/larger-text modes, and controlled display-frame pacing were not verified. VoiceOver and system accessibility settings were deliberately left untouched as instructed. No implementation fixes or new milestone were started. Native acceptance remains **BLOCKED** by NQ-1 and the outstanding hover/gesture/targeting checks.
