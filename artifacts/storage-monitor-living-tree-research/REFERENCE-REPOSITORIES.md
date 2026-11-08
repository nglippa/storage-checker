# Reference repositories: Living Tree research

All paths are relative to `~/ref-repos/node_modules` unless noted. These are npm installs only (no git clones). Everything below was read from source; items marked (inferred) were not read directly. Nothing was installed or run.

## Summary table

| Project | Version | License | What we take | Native feasibility |
|---|---|---|---|---|
| @dgreenheck/ez-tree | 1.1.0 | MIT | Branch radius taper, gnarliness, force bend, child placement, section/segment budget | High; about 2 days in Swift (Core Graphics polylines or SceneKit tubes) |
| d3-hierarchy | 3.1.2 | ISC | tree() (Buchheim), cluster, partition, pack, squarify, sum/sort | High; tree() port about 1 day |
| d3-flextree | 2.1.2 | WTFPL | Variable node-size tidy tree, spacing(a,b) | Medium-high; layout core is about 250 lines |
| d3-zoom | 3.0.0 | ISC | wheelDelta formula, zoom-about-pointer, scaleExtent, ctrlKey pinch handling | Trivial; about 30 lines, fixes our wheel zoom |
| 3d-force-graph (+ three-forcegraph, three-render-objects, d3-force-3d, ngraph.*) | 1.80.1 (three-forcegraph 1.43.6, three-render-objects 1.43.0, d3-force-3d 3.0.6) | MIT | zoomToFit math, DAG level spacing, raycast hover throttle, cooldown knobs | Ideas only; we do not need a force sim for a hierarchy |
| three | 0.186.1 | MIT | TrackballControls wheel constants only | Reference only |
| web-gl-tree | not present | n/a | nothing | see "Not found" |

## @dgreenheck/ez-tree 1.1.0 (MIT)

- Files: `@dgreenheck/ez-tree/src/lib/{tree.js (841 lines), options.js, branch.js, rng.js, trellis.js, textures.js}`; demo in `src/app/`. License at `@dgreenheck/ez-tree/LICENSE` ("MIT License, Copyright (c) 2024 Daniel Greenheck").
- Architecture: three.js BufferGeometry. Branches are tubes of `sections` rings by `segments` vertices, built into one merged mesh. Leaves are billboard quads. Runtime dep is three only. Generation is one-shot CPU (no per-frame cost), then plain mesh rendering.
- Generation loop, `src/lib/tree.js:100-103`: a FIFO `branchQueue` is seeded with the trunk (`:88-98`); `generateBranch` (`:115-270`) emits geometry and enqueues children. That is BFS by level.
- Section length, `:121-124`: `branch.length / sectionCount`, further divided by `(levels-1)` for Deciduous.
- Radius taper, `:131-145`:
  - Deciduous: `sectionRadius = branch.radius * (1 - taper[level] * (i / sectionCount))`.
  - Evergreen: `radius *= 1 - i/sectionCount` (full taper to a point).
  - Final section of the last level is forced to `0.001` (`:134-138`).
- Child radius, `:315-317`: `options.branch.radius[level] * lerp(sectionA.radius, sectionB.radius, alpha)`. So the child's radius is a fraction (default 0.7) of the parent's radius at the attach point. This is the size-aware branch radius rule, and it chains down the tree.
- Child length, `:342-346`: `branch.length[level]` (Evergreen multiplies by `1 - childBranchStart`).
- Child placement, `:283-359`:
  - `start = rng.random(1.0, branch.start[level])`, so a uniform position along the parent from `start[level]` to 1.
  - Origin and orientation are interpolated between the two neighbouring sections (lerp for position, slerp for orientation).
  - Orientation = parent orientation x rotateY(radialAngle) x rotateX(angle[level]). `radialAngle = 2*PI*(radialOffset + i/count)`, so children are spaced evenly around the parent from a random phase (`:327-340`).
- Gnarliness (curvature jitter), `:194-199`: `g = max(1, 1/sqrt(sectionRadius)) * gnarliness[level]`, then `orientation.x/z += random(-g, g)`. Thin branches wobble more; thick ones stay straight. This is the "controlled curvature" rule.
- Growth force, `:202-218`: slerp-like `qSection.rotateTowards(qForce, force.strength / sectionRadius)`. Thin twigs bend toward the force direction (default up, strength 0.01) more than thick limbs. Twist is a Y-axis quaternion per section (`:204-214`).
- Defaults, `options.js:27-113`: levels 3; angle {1:70, 2:60, 3:60}; children {0:7, 1:7, 2:5}; gnarliness {0:.15, 1:.2, 2:.3, 3:.02}; length {20,20,10,1}; radius {1.5,.7,.7,.7}; sections {12,10,8,6}; segments {8,6,4,3}; start {.4,.3,.3}; taper all 0.7; twist 0. Leaves (`:116-143`): count 1, size 2.5, sizeVariance 0.7, angle 10.
- Bounded detail: sections and segments fall with level (12/8 for trunk, 6/3 for twigs). That is a ready-made LOD budget.
- RNG: `src/lib/rng.js` (22 lines), seeded, so trees are reproducible. We should seed from the folder path hash.
- Caveats (read): the Deciduous "terminal branch" test compares `this.options.type === 'deciduous'` (`:239`) against enum case used elsewhere ("Deciduous", `:124`); this looks like a case bug that may skip terminal continuation. Do not copy it. EZ-Tree is purely random and not data-driven; branch count and size are not tied to any data.
- Porting for us: replace `rng.random(a,b)` children count with the folder's real children count, replace fixed `radius[level]` ratio with `sqrt(childBytes/parentBytes)` (area-preserving, pipe-model, (inferred) standard in tree modelling), clamp to a min pixel radius, and keep gnarliness/force as the organic jitter. 2D: a polyline with width taper per section. 3D dome: same maths in SceneKit (or project the 3D points).

## d3-hierarchy 3.1.2 (ISC)

Files under `d3-hierarchy/src/`; license `d3-hierarchy/LICENSE` ("Copyright 2010-2021 Mike Bostock", ISC).

- `hierarchy/index.js:15` `hierarchy(data, children)`; `hierarchy/sum.js:1-8` post-order `node.value = own + sum(children)`; `hierarchy/sort.js:1` sorts children by comparator (pre-order). These are the byte-rollup and ordering primitives.
- `tree.js` (Buchheim et al. linear-time Reingold-Tilford):
  - `defaultSeparation` `:3-5`: `a.parent === b.parent ? 1 : 2`.
  - The radial variant is commented out at `:7-9`: `(a.parent === b.parent ? 1 : 2) / a.depth`.
  - `tree()` `:106-`: `eachAfter(firstWalk)` then `eachBefore(secondWalk)`; `firstWalk` `:144-162` places a node at the midpoint of its first/last child and offsets from the previous sibling by `separation`; `apportion` `:180-217` walks left/right contours with threads (nextLeft/nextRight `:15-26`) to push subtrees apart in O(n); `moveSubtree` `:28`, `executeShifts` `:40` distribute the shifts.
  - `size([dx,dy])` (`:228`) rescales to a box (`:120-137`); `nodeSize([dx,dy])` (`:232`) uses fixed spacing (`:219-222`).
  - Radial use is not in the library: take x as the angle and y as the radius: `angle = x/dx * 2*PI`, `r = y`, then `(r*cos, r*sin)`. This is the documented pattern (d3 docs, inferred); pair it with `size([2*PI, R])` and the radial separation above so outer rings do not crowd.
- `cluster.js:33-` dendrogram: leaves share one depth line (`y = maxY`), parents at the mean of children (`meanX` `:5`). Use it when we want all leaves aligned (an outer ring).
- `partition.js` (icicle / sunburst), `pack/index.js` + `pack/siblings.js:49` (front-chain circle packing, `enclose.js` for the minimal enclosing circle), `treemap/squarify.js:4-66` (`phi` ratio, `squarifyRatio`). `sum().sort(by value desc)` before partition/pack/treemap is the standard recipe.
- Native: all pure arithmetic over a tree. tree() port about 150 lines Swift, no allocation issues at 20k nodes (O(n)).

## d3-flextree 2.1.2 (WTFPL)

- Files: `d3-flextree/src/flextree.js` (the layout, ~300 lines); `d3-flextree/index.js`; license `d3-flextree/LICENSE` (WTFPL v2, "Copyright (C) 2004 Sam Hocevar"). It depends on d3-hierarchy only for the `hierarchy` node prototype (`flextree.js:1`).
- What it adds over d3.tree (Bouvier/Hjelle flextree variant, inferred from header comments in the source tree): each node has its own width/height instead of a uniform grid.
  - API: `flextree({nodeSize, spacing, children})` defaults at `:5-9`: `nodeSize: node => node.data.size` (a `[xSize, ySize]` pair), `spacing: 0`. `spacing` can be a number or `(nodeA, nodeB) => number` (`:41`, `:103`), so separation can depend on the pair.
  - Vertical: `layoutChildren` `:175-190` stacks children at `w.y + w.ySize` (child y = parent bottom), so different heights per level are respected. Horizontal: contour extents use `left = x - xSize/2`, `right = x + xSize/2` (`:47-48`) and `separate()` (below `:190`) keeps real gaps.
  - Output: `x` is the node centre, `y` is the node top; `extents`, `top/bottom/left/right` helpers (`:45-84`).
- Use for prototype B: encode folder size into node width via nodeSize `[w(size), h]`. This is the layered/structured explorer. For a radial layout, flextree is rectangular; for radial we use d3.tree with radial separation and scale ring spacing by depth (flextree is not radial-aware).
- Native: port of `layoutChildren/separate/updateLows` plus extents; moderate (about 1.5 days) because of the contour bookkeeping (`lExt/rExt/lThr/rThr`). Alternative: do fixed-size d3.tree with `separation = (a,b) => (w(a)+w(b))/2 + gap`, which approximates variable widths for leaves (inferred; not exact for internal nodes).

## d3-zoom 3.0.0 (ISC): relevant to the wheel-zoom fix

- File `d3-zoom/src/zoom.js`.
- Default wheel delta `:34-36`:
  `-event.deltaY * (deltaMode === 1 ? 0.05 : deltaMode ? 1 : 0.002) * (ctrlKey ? 10 : 1)`.
  So pixels: 0.002 per px; lines: 0.05 per line; pages: 1; a ctrlKey (pinch on macOS, delivered as wheel+ctrlKey, comment at `:12`) multiplies by 10.
- Scale step `:238`: `k = clamp(scaleExtent, t.k * 2^wheelDelta)`. Exponential in the delta, so each event is multiplicative and zoom in/out is symmetric. Default scaleExtent `[0, Infinity]` (`:59`); there is no default translateExtent limit (`:60`).
- Zoom about the pointer, `:262`: `translate(scale(t, k), pointer, pointInWorldAtGestureStart)`. The world point under the cursor is captured on the first event (`:241-250`) and held while wheel events keep arriving; `g.wheel` timeout (about 150 ms idle, below `:262`, inferred) ends the gesture.
- Ignore no-op events `:253`: `else if (t.k === k) return;` — if clamped scale doesn't change, the event is not consumed, so the page can still scroll.
- Filter `:12-14`: ignore secondary button; allow ctrl+wheel.
- Transform `transform.js:1-12`: `(k, x, y)`, apply `p*k + (x,y)`.
- Native mapping (NSEvent): use `scrollingDeltaY` with `hasPreciseScrollingDeltas` (trackpad pixels, 0.002 factor) vs line mouse wheel (use 0.05 style factor); trackpad pinch arrives as `magnify(with:)` with `event.magnification` (additive; use `exp(magnification)`), not as ctrl+wheel (inferred, AppKit). Always `k *= 2^delta`, clamp, then re-anchor so the point under the cursor stays fixed. Avoid per-event full redraw: coalesce into one display-link/`setNeedsDisplay` frame.

## 3d-force-graph 1.80.1 and dependencies (MIT)

- Only the bundle is installed: `3d-force-graph/dist/3d-force-graph.js` (about 150k lines incl. bundled three and three-forcegraph). Source line numbers below are into that bundle. License `3d-force-graph/LICENSE` ("Copyright (c) 2017 Vasco Asturiano"); three-forcegraph, three-render-objects, d3-force-3d are MIT (package.json read).
- Architecture: three.js WebGL scene (three-render-objects), force layout from d3-force-3d (default) or ngraph.forcelayout, nodes as sphere meshes (`nodeResolution` default 8 slices, `:63786`), links as lines/cylinders. Runtime: multi-MB; irrelevant for us except as algorithm reference.
- Layout engine knobs, `:63924-63936`: `warmupTicks` 0 (ticks before first render), `cooldownTicks` Infinity, `cooldownTime` 15000 ms. Stop rule `:64001`: ticks > cooldownTicks, or elapsed > cooldownTime, or d3 alpha < alphaMin. Warmup loop `:64689`.
- DAG mode `:64624-64680`: depths from `getDagDepths`; level gap `dagLevelDistance` defaults to `nodes / maxDepth * DAG_LEVEL_NODE_RATIO(2)` (`:63710`, `:64653`), times 0.7 for radial modes; for `td/bu/lr/rl/zin/zout` the node coordinate on one axis is fixed to `(depth - maxDepth/2) * dist` (`:64662-64665`), inverted for rl/td/zout; `radialin/radialout` use `forceRadial(r = depth * dist)` (`:64670-64672`). So radial DAG = concentric rings by depth with the sim only spreading angles. For a tree this is exactly what d3.tree radial gives deterministically, so skip the sim.
- Camera: TrackballControls default (`controlType`, hint text `:393-394`: left rotate, wheel/middle zoom, right pan); alternatives orbit, fly. `three/examples/jsm/controls/TrackballControls.js:971-1000` wheel: `_zoomStart.y -= deltaY * (pixels 0.00025 | lines 0.01 | pages 0.025)`, `zoomSpeed 1.2` (`:90`, factor `:630`). Compare d3-zoom's much larger 0.002; 0.00025 is why that control feels slow.
- zoomToFit `:150866-150909`: `fitToBbox`; `paddedFov = (1 - padding*2/height) * fov` (padding in px, default 10); for the 8 bbox corners, `distance = max(|dot(up)|/tan(vFov/2), |dot(right)|/tan(hFov/2)) - dot(forward)`; the camera moves along `-forward` from the bbox centre. Animated by `cameraPosition(pos, lookAt, ms)`. Directly portable to a SceneKit camera; the 2D equivalent is `scale = min(W/bboxW, H/bboxH) * (1 - pad)`.
- Picking `:150925-150932`: CPU raycast `Raycaster.setFromCamera` + `intersectObjects(objects, true)` (not GPU colour picking in this version). Hover is throttled by `pointerRaycasterThrottleMs` (`:150716`, check at `:150769`), with hover state at `:150783`; `clickAfterDrag` false by default (`:150744`, `:151021`) so camera drags don't click. Pixel ratio clamped to 2 (`:151048`).
- Rendering: continuous `requestAnimationFrame` loop (`:151330`) with `pauseAnimation` (`:151308`) as the opt-out. Labels: `nodeLabel` renders an HTML tooltip (float-tooltip) at the cursor, not per-node text; `nodeThreeObject` allows sprites (README line 116 area).
- Large counts: sphere per node with 8-slice segments, one draw call per object (no instancing in the stock path, inferred), so it degrades past about 5-10k nodes; the cooldown settings exist to stop the sim from burning CPU.
- Takeaway for us: copy zoomToFit math, hover throttling, click-after-drag guard, and "stop animating when idle". Do not copy the force sim.

## Not found

- `web-gl-tree` / `webgl-tree`: no package, directory or file of that name under `~/ref-repos` (searched filenames `*web-gl-tree*`, `*webgl-tree*`, `*webgl*tree*`, and package.json contents). It is not installed. Do not rely on it.
- `~/ref-repos/cyberpunk-dashboard` is a Next.js/Tailwind/shadcn dashboard (package name `my-v0-project`); styling only, not relevant to tree algorithms. `~/ref-repos/my-video` is a Remotion project; not relevant.

## Recommendations for the two prototypes

A. Organic tree (EZ-Tree-inspired)
1. Seeded RNG from path hash (reproducible); BFS queue like `tree.js:100`.
2. Data-driven: children count = actual child count (cap visible detail, aggregate the tail into an "other" twig); length from depth, radius from `sqrt(size_child/size_parent)` times the parent's local radius, never below ~0.75 px.
3. Per-section loop: `r_i = r0 * (1 - taper * i/N)`; jitter `g = max(1, 1/sqrt(r_i)) * gnarl[level]`; upward/outward bias `strength / r_i` (`tree.js:131-145, 194-218`).
4. Child placement: parameter t in [start,1] on parent, evenly spaced azimuth with random phase, `angle[level]` off-axis (`:283-340`).
5. Budget: sections/segments decay by level (options.js:75-89); draw 2D as variable-width polylines; skip subtrees whose projected radius < 1 px; cap at about 2-3k visible branches.

B. Structured explorer
1. `hierarchy().sum(size).sort(desc)`, then tidy tree with radial separation `(same parent ? 1 : 2) / depth`, polar transform; or flextree for the layered (top-down) variant with nodeSize `[w(size), h]` and `spacing(a,b)`.
2. Depth-limited expand/collapse: lay out only expanded nodes plus one level of collapsed placeholders; re-run layout (O(n)) on toggle and tween between old and new positions.
3. Zoom-to-node: `scale = min(W/w, H/h) * 0.8`, animate the transform; reuse the zoomToFit maths.
4. Wheel zoom: d3-zoom's `2^(-dy*0.002)` for precise deltas, `0.05` per line, pinch via `magnify`; anchor at the pointer; clamp scale; coalesce redraws.
5. Hit-testing: spatial grid or quadtree on node positions in layout space (inverse of the zoom transform), throttled hover.

Performance at 2k-20k nodes: layout O(n) is cheap (milliseconds); the cost is drawing. Use event-driven rendering (redraw only on input, tween, or data change), cull by projected size, and cache the static layer in a CGLayer/bitmap during interaction. (inferred, standard practice)

## License and attribution obligations

- MIT (ez-tree, 3d-force-graph, three-*, d3-force-3d, three): the copyright notice and permission text must be kept in copies or substantial portions. Re-implementing the algorithm independently in Swift does not copy code, but if a direct translation of tree.js is made, include the "Copyright (c) 2024 Daniel Greenheck" MIT notice. Safest: add a THIRD-PARTY notice for derived techniques.
- ISC (d3-hierarchy, d3-zoom): same preserved-notice requirement ("Copyright 2010-2021 Mike Bostock") for copies or substantial portions. Porting the tree() algorithm (published by Buchheim, Junger, Leipert) from the paper is unencumbered; a line-by-line translation of d3's code should carry the ISC notice.
- WTFPL (d3-flextree): permits anything; no attribution required, though credit is courteous.
- Plan: we embed no JS. We port algorithms into Swift with a short attribution block in the Swift source header and an entry in the app's notices file for any translated-from-source routines (EZ-Tree branch maths, d3 tree, d3-zoom wheel constants). This is the user's call (policy), not legal advice.
