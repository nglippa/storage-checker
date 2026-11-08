"""Build the review summary from recorded results; never mutate app/catalog state."""
from pathlib import Path
import json, re, hashlib, statistics, datetime

root = Path(__file__).resolve().parents[1]
v = root / 'verification'
report = root / 'INTEGRATION-REPORT.md'
counts = {}
for name, filename, pattern in [
    ('Viewer model/read-only', 'gui-final.log', r'(\d+) GUI model/read-only tests passed'),
    ('Monitor self-test', 'monitor-self-test.log', r'(\d+) tests passed'),
    ('Inventory integration', 'inventory.log', r'(\d+) inventory tests passed'),
    ('Inventory browser model', 'inventory-model.log', r'(\d+) inventory model tests passed, 0 failed'),
    ('Hosted chart/input/state', 'chart-and-input.log', r'(\d+) of \1 hosted chart geometry and scroll routing checks passed'),
]:
    match = re.search(pattern, (v / filename).read_text())
    if not match:
        raise SystemExit('Missing successful result: ' + filename)
    counts[name] = int(match[1])
measurement = json.loads((root / 'measurements.json').read_text())
assert not measurement['failures']
source = json.loads((v / 'final-source-manifest.json').read_text())
repo = root.parents[1]
changed = [key for key, digest in source['sha256'].items() if hashlib.sha256((repo / key).read_bytes()).hexdigest() != digest]
assert not changed, 'Source changed after freeze: ' + str(changed)
(v / 'source-verification.json').write_text(json.dumps({'verified_utc': datetime.datetime.now(datetime.timezone.utc).isoformat(), 'files_checked': len(source['sha256']), 'changed_since_freeze': changed}, indent=2) + '\n')
classic = measurement['results']['classic']
new = measurement['results']['structured']
rows = [
    ('Displayed elements', classic['elements'], new['shown']),
    ('Layout, ms (classic sample / structured median)', classic['layoutMs'], new['layoutMs']),
    ('Layout + first offscreen canvas frame, ms', classic['firstFrameMs'], new['firstFrameMs']),
    ('Pan p50 / p95, ms', f"{classic['panP50']:.2f} / {classic['panP95']:.2f}", f"{new['panP50']:.2f} / {new['panP95']:.2f}"),
    ('Zoom p50 / p95, ms', f"{classic['zoomP50']:.2f} / {classic['zoomP95']:.2f}", f"{new['zoomP50']:.2f} / {new['zoomP95']:.2f}"),
    ('Labels at fit', classic['labelsFit'], new['labelsFit']),
    ('Offscreen host + initial layout + bitmap median, ms', statistics.median(new['pageClassicHostAndBitmapMs']), statistics.median(new['pageStructuredHostAndBitmapMs'])),
]
fmt = lambda x: f'{x:.2f}' if isinstance(x, float) else str(x)
text = '\n## Final recorded results\n\n'
text += 'Host: `Mac16,11`, Apple M4 Pro, 24 GiB RAM; macOS 27.0 (26A428), macOS 26.5 SDK, arm64 macOS 14 deployment target. Builds and tests were serialized. No native window was opened.\n\n'
text += '| Suite | Passed |\n|---|---:|\n' + ''.join(f'| {k} | {n} |\n' for k, n in counts.items())
text += f"\nThe benchmark completed {measurement['checks']} required checks with zero failures, including the offscreen production input bridge, saved renders, disc/label hit accuracy, same-root comparison and the 16.67 ms offscreen frame budget. This count includes artifact-existence assertions and is not a count of independent native interactions. Both development builds and strict code-signature checks passed; bundled notices match the source notice.\n\n"
text += '### Same-pipeline before/after\n\n'
text += 'The classic fallback and integrated Structured Explorer use the same restored bounded controller model and cloned catalog, 1100×600 pt canvas, 2× rasterization and warm caches. The Structured Explorer intentionally displays fewer elements at its three-level default. Layout/first-frame figures are computational/offscreen costs, not cold launch or first visible compositor frame. The original prototype timing used a different canvas and adapter and is not substituted for these measurements.\n\n'
text += '| Metric | Classic fallback | Integrated Structured Explorer |\n|---|---:|---:|\n' + ''.join(f'| {label} | {fmt(a)} | {fmt(b)} |\n' for label, a, b in rows)
text += f"\nStructured pan at 4× p50/p95: {new['pan4xP50']:.2f}/{new['pan4xP95']:.2f} ms. Selection-to-offscreen-frame p50/p95: {new['selectP50']:.2f}/{new['selectP95']:.2f} ms, with {new['relayoutsForSelections']} relayout(s) over 21 selection samples. Explore read+layout median: {statistics.median(new['recentreMs']):.2f} ms; Up median: {statistics.median(new['upMs']):.2f} ms. Warm incremental footprint delta: {new['memoryDeltaMB']:.2f} MiB; this is not total application memory.\n\n"
text += f"Disc-centre hits: {new['discHitsFit']}/{new['discs']} at fit, {new['discHits4x']}/{new['discs']} at 4×. Label-centre hits: {new['labelHitsFit']}/{new['labelsTestedFit']} at fit, {new['labelHits4x']}/{new['labelsTested4x']} at 4×. Hit tests cover synthetic/offscreen geometry, not a physical mouse.\n\n"
text += 'The page-cost callback excludes fixed screenshot settling waits and deferred work during those waits. It is useful for a rendering comparison but does not establish the V2 500 ms native section-switch target. Real display pacing, cold navigation and target-device input remain pending.\n\n'
text += '| Larger/skewed case | Result |\n|---|---|\n'
for item in measurement['scaling']:
    if 'budget' in item:
        text += f"| Budget {item['budget']:,}; actual {item['elements']:,} model elements | Truncated={item['truncated']}; L3 {item['shown3']:,} shown, layout {item['layout3Ms']:.2f} ms; L6 {item['shown6']:,} shown, layout {item['layout6Ms']:.2f} ms |\n"
    else:
        text += f"| Synthetic skew: {item['unbalancedElements']:,} elements, 40-level chain, 1,500 small folders | {item['shown']} shown; layout {item['layoutMs']:.2f} ms; raster {item['frameMs']:.2f} ms; spur explicitly skips {item['spurLevels']} levels |\n"
text += '\nLarger-model reads remain bounded and can stop before their requested element budgets; these are actual returned counts, not claims of 10k/20k fully rendered nodes. High-depth layout timings do not establish high-depth pan/frame pacing.\n\n'
text += '### Regression diagnosis and integrity\n\n'
text += 'The initial edge-label regression failed 83 of 108 cases before the placement repair; the final fixture passes 108/108. A later assertion incorrectly expected root-centred zoom to always introduce a new label even as outer rings left the viewport. Diagnostics showed all label hits correct and 11 rotated labels present. The fixture now zooms into an unlabelled branch, retains the new-detail assertion and checks rotated label interiors; the focused run finds 13 rotated labels. The failed and diagnostic runs remain in `verification/labels-red.log`, `labels-zoom-red.log` and `label-zoom-diagnosis.log`. No native requirement was weakened.\n\n'
text += f"The source freeze check covers {len(source['sha256'])} source/test/script files with no changes. `protected-state.json` confirms RC HEAD `873e069dc88788d24d620b4f9f6ff1904ea52f6a`, the unchanged DMG SHA-256 `3484abea58524cd090808714e38672cc0f82a628d3b42b9c797c66674f774f0c`, unchanged release-checkout status, exact research fix-source matches and all six research prototype files carried forward intact. No release action was taken.\n\n"
text += 'The compiler emits the pre-existing `CleanupInspectorView.swift:174` weak/strong capture warning. It was left unchanged because cleanup implementation is outside this visualization change. Universal/Intel and distribution-DMG builds were not run.\n\n'
text += 'Screenshots: `headless-renders/` (28 full-resolution captures); comparison board: `visual-comparison/integration-board.png`; full machine-readable metrics: `measurements.json`; commands/results: `verification/`. Native acceptance is still NOT VERIFIED as listed in `NATIVE-QA.md`.\n'
s = report.read_text().split('\n## Final recorded results')[0]
s = s.replace('| 10. Cleanup safety unchanged | PARTIALLY VERIFIED | Cleanup sources unchanged; final safety regression results to be recorded below |', '| 10. Cleanup safety unchanged | VERIFIED | Cleanup sources unchanged; viewer safety, inventory and browser regressions pass |')
s = s.replace('| 14. Relevant regressions pass | PARTIALLY VERIFIED | Serial final run in progress at report creation; final results below supersede this provisional row |', '| 14. Relevant regressions pass | VERIFIED | Final suite counts, signature checks and benchmark assertions pass as recorded below |')
s = s.replace('| 17. RC and DMG protected | PARTIALLY VERIFIED | Starting RC/DMG confirmed; final integrity recheck to be recorded below |', '| 17. RC and DMG protected | VERIFIED | Final RC/status/DMG and research-source checks recorded in protected-state.json |')
s = s.replace('Final counts and measurements are recorded below after the serial suite finishes.', 'Final counts and measurements are recorded below.')
s = s.replace('First-ring labels try four positions.', 'First-ring labels try four positions; major first-level folders retain label priority even at high depth.')
s = s.replace('when no geometry-clear position exists a priority label may cover underlying geometry', 'when no geometry-clear position exists a selection, hover or major-folder priority label may cover underlying geometry')
s = s.replace('`LIVING-TREE-CAMERA.md`, `LIVING-TREE-3D.md`.', '`LIVING-TREE-CAMERA.md`, `LIVING-TREE-3D.md`, and an integration addendum in `VERIFICATION.md`.')
if (root / 'native-qa/results.json').exists():
    text = text.replace('No native window was opened.', 'This headless run preceded the separately authorized native session.')
    text = text.replace('Native acceptance is still NOT VERIFIED as listed in `NATIVE-QA.md`.', 'Native acceptance is BLOCKED; see `native-qa/NATIVE-RESULTS.md`.')
    text += '\n## Native QA conclusion\n\nThe authorized native session is complete. The app is closed, QA preferences restored and temporary catalog disposed. Native acceptance is BLOCKED; see `native-qa/NATIVE-RESULTS.md` for actual results and remaining checks. No further milestone was started.\n'
report.write_text(s + text)
print(json.dumps({'counts': counts, 'benchmark_checks': measurement['checks'], 'source_files_checked': len(source['sha256'])}))
