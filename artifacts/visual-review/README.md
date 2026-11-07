# Storage Monitor visual review — 28 October 2026

Exactly two review collages are supplied in this directory. Individual unretouched PNG renders are in `source-screenshots/`. The collages add editorial headings and captions outside the screenshots; standalone component crops are explicitly labelled and full originals are retained; screenshots retain their proportions and are never enlarged beyond their source pixel dimensions.

## Deliverables and verification

- `storage-monitor-collage-1-inventory-cleanup.png` — **6400×15280**, 15,741,948 bytes; 16 numbered states/components.
- `storage-monitor-collage-2-monitoring-experience.png` — **6400×10100**, 5,595,147 bytes; 10 distinct states/components, including three evidence-panel crops.
- `source-screenshots/` — **26** complete, original 2× PNG exports.

Final checks passed: exactly two top-level PNG collages; all 26 expected sources present; PNG chunk CRCs valid; every captured window invisible; all 41 original application-source hashes unchanged. The build completed successfully. Composition was visually inspected at overview scale; representative full-size sources and detail content were inspected separately. No native interaction verification is claimed.

## Capture method and provenance

**All 26 screenshots are headless/offscreen native-view renders. None is a native onscreen window screenshot.** They were captured from a new executable compiled from the current working-tree application views after the UX refinement milestone, using the macOS 26.5 SDK. This is a capture build of the real views, not a reconstruction of the interface or the installed production app.

The capture process used `NSApplication.ActivationPolicy.prohibited`. Its windows were never ordered onscreen. Each export asserted that its window was invisible; the process logged zero visible windows at completion. No desktop input, AX actions, app activation, global appearance changes, Stage Manager changes, cleanup, Trash actions, installs, commits, packaging, or releases were performed. The strict do-not-launch runtime and the user's development viewer were not launched or controlled.

Application source files were not edited. The capture build used temporary copies of two files: the app entry-point annotation was removed and the Settings type made accessible in one copy; a same-file accessor exposed the existing Living Tree help content in another. These changes only permit the separate capture entry point and standalone component capture. `provenance.json` records hashes of all 41 original GUI/shared Swift sources. `verification.json` records the final source comparison, PNG dimensions, integrity checks and hashes. Build/runtime output is in `capture-final.log`.

The inventory and monitoring history come from an APFS clone of the preserved, consistent QA snapshot:

`build/inventory-fresh-20261023T031313Z/previous-catalog.sqlite3`

That snapshot is dated 22 October 2026 and contains 2,959,505 inventory rows and 29 recorded readings. It has no WAL/SHM siblings. The original was only read to clone it. The active QA catalog was unsuitable for the combined tour because it has no monitoring readings. Live capacity is a fresh read from this Mac. Cleanup evidence additionally re-observes the real filesystem paths and current process information **read-only**; those paths are not copied by cloning the catalog. No data was invented, and stale measurements remain visibly qualified.

View choices were set only in the capture process's volatile defaults domain. Light/dark appearance was set on the capture app and hosting views only, without changing macOS settings. Monitoring uses a 30-day event filter so the preserved real events remain visible; the chart shows its actual seven-day range. The minimum-size cases use 1000×640 pt content, matching the prior headless acceptance procedure's 1000×700 window allowance of 60 pt for title bar/toolbar. Larger cases use 1440×840 pt content. These are labelled **window equivalents**, not measurements of an onscreen native frame. All original bitmap exports have twice their logical width and height.

## Collage 1 — Storage Inventory & Cleanup

| No. | Represented screen/state |
|---|---|
| 01 | Storage landing: capacity, Storage Atlas, folder Navigator, current-folder Inspector |
| 02 | Compact Storage in dark appearance |
| 03 | Expanded Users hierarchy, selected folder and Inspector |
| 04 | Atlas drilled into a large folder, breadcrumb and nested allocation |
| 05 | Living Tree 2D overview with controls, Navigator and Inspector |
| 06 | Living Tree 3D overview |
| 07 | Living Tree 3D selected folder and matching Inspector |
| 08 | Selected Living Tree in a light window (the canvas itself stays dark by design) |
| 09 | Largest files ranking and selected file details |
| 10 | Largest folders ranking and selected folder details |
| 11 | Review-candidate filter and its actual empty/revalidation state |
| 12 | Populated All assessments list, selected real item and Inspector |
| 13 | Actual Living Tree navigation help content, standalone component |
| 14 | Full Cleanup Inspector in light appearance, evidence and removal restriction |
| 15 | Another real artifact's Cleanup Inspector in dark appearance |
| 16 | Actual informational review-plan component, including excluded selections |

**Cleanup limitation:** the bounded discovery page has no eligible review candidates. Stale measurements and incomplete journal freshness require revalidation. The populated list therefore shows actual assessments and their uncertainty rather than positive eligibility. A positively eligible candidate list and production eligibility/confirmation flow were **NOT CAPTURED**. The empty state is retained for review; no catalog metadata was changed to bypass it.

## Collage 2 — Monitoring & Application Experience

| No. | Represented screen/state |
|---|---|
| 01 | Default Monitoring overview at desktop size: live capacity/status, latest notable change, chart and populated event list |
| 02 | Desktop-size light Monitoring, recorded event selected and explanation panel open |
| 03 | Minimum-window equivalent, dark |
| 04 | Minimum-window equivalent, light |
| 05 | Minimum-window equivalent, event selected and explanation panel open |
| 06 | Compact summary scrolled to reveal its chart while retaining the event list |
| 07 | Complete explanation component: What happened, What may explain it, How sure is this?, What you can do |
| 08 | Latest notable event's explanation in light appearance |
| 09 | Actual Settings component: appearance, background monitoring, notifications and privacy controls; QA monitoring actions disabled |
| 10A–C | One expanded Details and evidence panel in three overlapping crops: measured changes, storage breakdown, supporting evidence, technical disclosure and copy controls |

## Missing native evidence — NOT VERIFIED

- Native title bar, Storage/Monitoring toolbar switch, toolbar buttons and system menu presentation are absent from these exports.
- The help content is real, but popover placement, native sizing, dismissal and clipping are not captured.
- The informational plan and tall Inspectors are standalone component renders; they do not imply sheets/windows of those dimensions exist in the normal application.
- Native keyboard focus, arrow-key navigation, immediate Search clicks, disclosure-label clicks and help Esc behaviour were not exercised. The current focus-fix source was compiled; screenshots alone cannot prove those interactions.
- Exact outer 1000×700 and larger native window geometry was not verified onscreen.
- The full-app Move to Trash sheet, warning acceptance and cleanup execution were not captured or exercised.

## Visible review concerns

- At minimum Monitoring size, the summary's lower chart area lies below its initial scroll fold. The event list remains present, but the independent summary scrolling may be easy to miss. The scrolled state is included.
- Opening the event panel at minimum size makes the main area noticeably cramped. Some long filter summaries truncate, and the last visible table row can be partial at the scroll boundary.
- Living Tree contains dense, tiny branches and truncated long labels. Both 2D and 3D full frames are preserved for assessment.
- Some secondary/evidence text and chart threshold lines are low contrast, especially in light appearance.
- The preserved QA inventory is stale; most sizes say Previously measured and the cleanup candidate filter is empty. These are actual data/qualification states, not hidden or repaired.
- **Capture limitation:** the compact dark Monitoring inspector renders black text on dark in the offscreen split-view export (image 05), even with explicit capture-process appearance. Its same real component renders readably on its own in image 07. The defective export is retained and labelled; whether the native app reproduces this is **NOT VERIFIED**. Do not treat it as a confirmed product bug.
- Native material rendering and toolbar appearance are outside this capture method's fidelity.

These observations are for visual review only. No issues were fixed as part of this task.
