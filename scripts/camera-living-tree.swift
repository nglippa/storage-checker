import SwiftUI
import AppKit
import ImageIO
import UniformTypeIdentifiers
import SQLite3

// Living Tree camera: offscreen renders at several zooms and window sizes, and measurements of zoom, pan, hit
// testing, labels, resizing, camera stability through journal updates, memory over repeated navigation and idle
// CPU. Run through scripts/benchmark-living-tree-camera.sh on an APFS clone under /private/tmp. Nothing is shown on
// screen: the process may not activate (activation policy .prohibited), panels are drawn by ImageRenderer and the
// full page by an NSHostingView in a borderless window that is never ordered in.

@MainActor func waitUntil(seconds: Double = 20, _ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while !condition() { if Date() > deadline { return false }; try? await Task.sleep(for: .milliseconds(25)) }
    return true
}

func writePNG(_ image: CGImage, to url: URL) {
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
    CGImageDestinationAddImage(destination, image, nil)
    CGImageDestinationFinalize(destination)
}

func footprint() -> Int64 {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let result = withUnsafeMutablePointer(to: &info) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) } }
    return result == KERN_SUCCESS ? Int64(info.phys_footprint) : -1
}

func cpuSeconds() -> Double {
    var usage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    return Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1e6 + Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1e6
}

func percentile(_ values: [Double], _ p: Double) -> Double {
    guard !values.isEmpty else { return 0 }
    let sorted = values.sorted()
    return sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * p + 0.5))]
}

func ms(_ seconds: Double) -> String { String(format: "%.2f", seconds * 1000) }

/// Commits a size change to a folder and every ancestor in one transaction, as a worker relist would.
func commitSizeChange(_ database: String, folder: Int64, delta: Int64) {
    var db: OpaquePointer?
    guard sqlite3_open(database, &db) == SQLITE_OK else { return }
    defer { sqlite3_close(db) }
    sqlite3_busy_timeout(db, 30_000)
    sqlite3_exec(db, "BEGIN IMMEDIATE", nil, nil, nil)
    let sql = "WITH RECURSIVE chain(id) AS (SELECT ? UNION ALL SELECT n.parent_id FROM inventory_nodes n JOIN chain c ON n.id=c.id WHERE n.parent_id IS NOT NULL) UPDATE inventory_nodes SET total_allocated=MAX(0,total_allocated+?),measured_at=unixepoch() WHERE id IN (SELECT id FROM chain)"
    var statement: OpaquePointer?
    sqlite3_prepare_v2(db, sql, -1, &statement, nil)
    sqlite3_bind_int64(statement, 1, folder); sqlite3_bind_int64(statement, 2, delta)
    sqlite3_step(statement); sqlite3_finalize(statement)
    sqlite3_exec(db, "COMMIT", nil, nil, nil)
}

@main struct LivingTreeCameraHarness {
    @MainActor static func main() async {
        setvbuf(stdout, nil, _IOLBF, 0)
        _ = NSApplication.shared
        NSApplication.shared.setActivationPolicy(.prohibited)
        let arguments = CommandLine.arguments
        guard arguments.count == 3 else { fputs("usage: camera <prepared catalog clone> <output folder>\n", stderr); exit(2) }
        let database = arguments[1], output = URL(fileURLWithPath: arguments[2], isDirectory: true)
        try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        // Registered (in-memory) defaults only: nothing is written to any preferences file.
        UserDefaults.standard.register(defaults: ["inventory.explorer.visualization": "tree", "inventory.explorer.mapHeight": 560.0, "inventory.explorer.inspector": true])
        // The settled state: pending reconciliation cleared on the clone, as a finished reconciliation would.
        var db: OpaquePointer?
        if sqlite3_open(database, &db) == SQLITE_OK {
            sqlite3_busy_timeout(db, 30_000)
            sqlite3_exec(db, "DELETE FROM inventory_reconcile; DELETE FROM inventory_prune_jobs;", nil, nil, nil)
            sqlite3_close(db)
        }

        let browser = InventoryBrowserModel(database: database, readiness: ViewerReadiness(output: nil))
        await browser.load()
        guard let root = browser.directory else { fputs("no inventory root\n", stderr); exit(1) }
        let explorer = browser.explorer, tree = browser.livingTree
        explorer.show(root: root, trail: browser.breadcrumbs)
        tree.show(root: root, trail: browser.breadcrumbs)
        guard await waitUntil({ tree.model != nil && explorer.state.children[root.id] != nil }) else { fputs("tree did not build\n", stderr); exit(1) }
        // The first build after cloning is cold and may stop at the read guard (measured in benchmark-living-tree.sh);
        // into the largest folder and back gives the warm, full tree the renders and measurements use.
        print("first build elements=\(tree.model!.count) build=\(ms(tree.statistics.lastBuildSeconds))ms truncated=\(tree.model!.truncated)")
        if let largest = tree.model![tree.model!.rootKey]!.children.compactMap({ tree.model![$0]?.node }).filter({ $0.kind == .directory }).max(by: { ($0.allocatedBytes ?? 0) < ($1.allocatedBytes ?? 0) }) {
            browser.navigate(largest); await browser.load(); tree.show(root: browser.directory ?? largest, trail: browser.breadcrumbs)
            _ = await waitUntil { tree.model?.root.id == largest.id }
            browser.navigate(root); await browser.load(); tree.show(root: browser.directory ?? root, trail: browser.breadcrumbs)
            explorer.show(root: browser.directory ?? root, trail: browser.breadcrumbs)
            _ = await waitUntil { tree.model?.root.id == root.id }
        }
        // A tree grown from a cut-short first build keeps that build's memory (elements drawn before are preferred);
        // with no data change it settles within a rebuild or two. Measure that, and measure from the settled tree.
        var settleRounds = 0, lastTips = [LivingTreeKey: CGPoint]()
        for round in 1...4 {
            let tips = Dictionary(uniqueKeysWithValues: tree.layout()!.geometry.branches.map { ($0.key, $0.end) })
            if round > 1 && tips == lastTips { break }
            lastTips = tips; settleRounds = round
            guard let other = tree.model![tree.model!.rootKey]!.children.compactMap({ tree.model![$0]?.node }).first(where: { $0.kind == .directory }) else { break }
            browser.navigate(other); await browser.load(); tree.show(root: browser.directory ?? other, trail: browser.breadcrumbs)
            _ = await waitUntil { tree.model?.root.id == other.id }
            browser.navigate(root); await browser.load(); tree.show(root: browser.directory ?? root, trail: browser.breadcrumbs)
            _ = await waitUntil { tree.model?.root.id == root.id }
        }
        print("settled after \(settleRounds) rebuild(s) without data changes")
        let model = tree.model!
        print("tree elements=\(model.count) build=\(ms(tree.statistics.lastBuildSeconds))ms truncated=\(model.truncated)")

        /// Renders the whole tree panel (header, canvas, controls, footer) at `size`; returns the canvas size the view
        /// laid out (so camera operations use exactly the drawn canvas).
        @discardableResult func render(_ name: String?, _ size: CGSize) -> CGSize? {
            let view = LivingTreeView(browser: browser, explorer: explorer, tree: tree)
                .frame(width: size.width, height: size.height).environment(\.colorScheme, .dark).environment(\.livingTreeInteractive, false)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            guard let image = renderer.cgImage else { print("render \(name ?? "-") failed"); return nil }
            if let name { writePNG(image, to: output.appendingPathComponent(name + ".png")); print("render \(name) \(Int(size.width))x\(Int(size.height))@2x zoom=\(LivingTreeView.percent(tree.camera.zoom)) labels=\(tree.labels(for: tree.lastCanvasSize ?? size, focus: nil, measure: LivingTreeLabelMetrics.measure).count)") }
            return tree.lastCanvasSize
        }
        /// Lays out once at `size`, makes that canvas the controller's viewport, then applies `camera` and renders.
        func shoot(_ name: String, _ size: CGSize, _ camera: () -> Void) {
            tree.setCamera(.fit, animated: false)
            if let canvas = render(nil, size) { tree.viewportChanged(canvas) }
            camera()
            render(name, size)
        }

        let standard = CGSize(width: 1240, height: 640)
        // The largest top-level folder and the largest expanded folder two levels down (a branch with structure).
        let rootChildren = model[model.rootKey]!.children
        let major = rootChildren.filter { model[$0]?.role == .branch }.max { (model[$0]!.bytes ?? 0, $1) < (model[$1]!.bytes ?? 0, $0) }!
        let focusTarget = model.order.filter { model[$0]!.depth == 2 && model[$0]!.expanded && model[$0]!.children.count >= 8 }
            .max { (model[$0]!.bytes ?? 0, $1) < (model[$1]!.bytes ?? 0, $0) } ?? major
        /// The element nearest the centre of the framed view, and its tip on screen.
        func centred() -> (key: LivingTreeKey, point: CGPoint)? {
            guard let framing = tree.framing(for: tree.viewport), let plane = tree.planeGeometry() else { return nil }
            let t = tree.camera.transform(in: framing)
            return plane.branches.filter { $0.depth >= 1 }.map { ($0.key, t.apply($0.end)) }
                .min { hypot($0.1.x - framing.anchor.x, $0.1.y - framing.anchor.y) < hypot($1.1.x - framing.anchor.x, $1.1.y - framing.anchor.y) }
        }
        func centreDrift(_ before: (key: LivingTreeKey, point: CGPoint)?) -> CGFloat {
            guard let before, let framing = tree.framing(for: tree.viewport), let tip = tree.planeGeometry()?[before.key]?.end else { return -1 }
            let now = tree.camera.transform(in: framing).apply(tip)
            return hypot(now.x - before.point.x, now.y - before.point.y)
        }
        func tipOnScreen(_ key: LivingTreeKey) -> CGPoint? {
            guard let geometry = tree.layout()?.geometry, let branch = geometry[key], let transform = tree.transform(for: tree.viewport) else { return nil }
            return transform.apply(branch.end)
        }

        // MARK: Renders
        shoot("living-tree-camera-fit", standard) {}
        if let framing = tree.framing(for: tree.viewport), let extent = tree.extent {
            let drawn = tree.cameraTarget.transform(in: framing).apply(extent)
            let old = LivingTreeGeometer.layout(model, tree.arrangement!, in: tree.viewport).extent!
            print("fit canvas=\(Int(tree.viewport.width))x\(Int(tree.viewport.height)) tree=\(Int(drawn.width))x\(Int(drawn.height)) (\(Int(100 * drawn.width * drawn.height / (tree.viewport.width * tree.viewport.height)))% of canvas area) previous-layout=\(Int(old.width))x\(Int(old.height)) (\(Int(100 * old.width * old.height / (tree.viewport.width * tree.viewport.height)))%)")
        }
        let zoomPoint = { tipOnScreen(focusTarget) ?? CGPoint(x: tree.viewport.width / 2, y: tree.viewport.height / 2) }
        shoot("living-tree-camera-2x", standard) { tree.zoom(by: 2, at: zoomPoint(), animated: false) }
        shoot("living-tree-camera-4x", standard) { tree.zoom(by: 4, at: zoomPoint(), animated: false) }
        if let node = model[focusTarget]?.node {
            let chain = model.ancestry(of: focusTarget).dropFirst().dropLast().compactMap { model[$0]?.node }
            explorer.select(node, through: Array(chain))
            shoot("living-tree-camera-focused", standard) { tree.focus(on: focusTarget, animated: false) }
            print("focused \(model[focusTarget]!.name) zoom=\(LivingTreeView.percent(tree.camera.zoom))")
        }
        shoot("living-tree-camera-narrow", CGSize(width: 640, height: 640)) {}
        shoot("living-tree-camera-wide", CGSize(width: 1900, height: 560)) {}
        tree.setCamera(.fit, animated: false)

        // The whole explorer page with the interaction layer in place (a borderless window that is never ordered in).
        do {
            let host = NSHostingView(rootView: InventoryExplorerView(browser: browser).frame(width: 1440, height: 1000))
            host.frame = NSRect(x: 0, y: 0, width: 1440, height: 1000)
            let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 1440, height: 1000), styleMask: [.borderless], backing: .buffered, defer: true)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: .darkAqua)
            window.contentView = host
            host.appearance = NSAppearance(named: .darkAqua)
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(1.2))
            host.layoutSubtreeIfNeeded()
            if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.appearance!.performAsCurrentDrawingAppearance { host.cacheDisplay(in: host.bounds, to: bitmap) }
                if let image = bitmap.cgImage { writePNG(image, to: output.appendingPathComponent("living-tree-camera-page.png")); print("render living-tree-camera-page 1440x1000 (window never ordered in)") }
            }
            window.contentView = nil
        }

        // MARK: Measurements (canvas of the standard panel)
        if let canvas = render(nil, standard) { tree.viewportChanged(canvas) }
        let canvas = tree.viewport
        let layout = tree.layout()!

        /// One frame of camera movement: projection, label placement (when due) and rasterizing the base and label layers.
        func frame() -> (model: Double, total: Double) {
            let started = Date()
            guard let projected = tree.projected(for: canvas) else { return (0, 0) }
            let labels = tree.labels(for: canvas, focus: nil, measure: LivingTreeLabelMetrics.measure)
            let modelTime = Date().timeIntervalSince(started)
            let view = ZStack {
                LivingTreeBaseCanvas(revision: tree.revision, size: canvas, transform: projected.transform, zoom: tree.camera.zoom, geometry: projected.geometry, model: tree.model!)
                LivingTreeLabelCanvas(labels: labels, tips: labels.map { projected.geometry[$0.key]?.end ?? projected.transform.apply($0.tip) }, size: canvas)
            }.frame(width: canvas.width, height: canvas.height)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            _ = renderer.cgImage
            return (modelTime, Date().timeIntervalSince(started))
        }
        for zoom in [1.0, 2.0, 4.0, 8.0] {
            tree.setCamera(.fit, animated: false)
            if zoom > 1 { tree.zoom(by: zoom, at: zoomPoint(), animated: false) }
            var pans = [(Double, Double)]()
            for i in 0..<40 { tree.pan(by: CGVector(dx: i % 20 < 10 ? 9 : -9, dy: 4)); pans.append(frame()) }
            print("pan frame zoom=\(Int(zoom))x model p50=\(ms(percentile(pans.map(\.0), 0.5)))ms p95=\(ms(percentile(pans.map(\.0), 0.95)))ms | with raster @2x p50=\(ms(percentile(pans.map(\.1), 0.5)))ms p95=\(ms(percentile(pans.map(\.1), 0.95)))ms")
        }
        tree.setCamera(.fit, animated: false)
        var zooms = [(Double, Double)]()
        for i in 0..<40 { tree.zoom(by: i < 20 ? 1.08 : 1 / 1.08, at: zoomPoint(), animated: false); zooms.append(frame()) }
        print("pinch frame (1.08x steps, 1x-4.7x) model p50=\(ms(percentile(zooms.map(\.0), 0.5)))ms p95=\(ms(percentile(zooms.map(\.0), 0.95)))ms | with raster @2x p50=\(ms(percentile(zooms.map(\.1), 0.5)))ms p95=\(ms(percentile(zooms.map(\.1), 0.95)))ms")

        // Animated wheel zoom: steps to settle, and whether the point under the pointer stays put.
        tree.setCamera(.fit, animated: false)
        let pointer = zoomPoint()
        let content = tree.transform(for: canvas)!.invert(pointer)
        tree.zoom(by: pow(1.2, 3), at: pointer, animated: true)
        var steps = 0, drift: CGFloat = 0, stepTimes = [Double]()
        while tree.isMoving && steps < 1_000 {
            let started = Date(); tree.stepMotion(1.0 / 120); stepTimes.append(Date().timeIntervalSince(started)); steps += 1
            let p = tree.transform(for: canvas)!.apply(content)
            drift = max(drift, hypot(p.x - pointer.x, p.y - pointer.y))
        }
        print("animated wheel zoom 1.73x: settled in \(steps) frames (\(String(format: "%.2f", Double(steps) / 120)) s at 120 Hz), step p50=\(ms(percentile(stepTimes, 0.5)))ms, pointer drift max=\(String(format: "%.3f", drift))pt")

        // Hit testing through the camera.
        var generator = SystemRandomNumberGenerator()
        for zoom in [1.0, 4.0, 16.0] {
            tree.setCamera(.fit, animated: false)
            if zoom > 1 { tree.zoom(by: zoom, at: zoomPoint(), animated: false) }
            let transform = tree.transform(for: canvas)!
            var times = [Double](), found = 0
            let points = (0..<20_000).map { _ in CGPoint(x: CGFloat.random(in: 0..<canvas.width, using: &generator), y: CGFloat.random(in: 0..<canvas.height, using: &generator)) }
            for p in points { let started = Date(); if layout.hits.hit(p, transform: transform) != nil { found += 1 }; times.append(Date().timeIntervalSince(started)) }
            // Every drawn tip is found at its own position.
            let geometry = layout.geometry
            var tipsChecked = 0, tipsHit = 0
            for branch in geometry.branches where branch.role != .trunk && LivingTreeDetail.isDrawn(branch, through: transform) {
                let p = transform.apply(branch.end)
                guard CGRect(origin: .zero, size: canvas).contains(p) else { continue }
                tipsChecked += 1
                if let key = layout.hits.hit(p, transform: transform), key == branch.key || model.ancestry(of: key).contains(branch.key) || geometry[key].map({ hypot(transform.apply($0.end).x - p.x, transform.apply($0.end).y - p.y) < 1 }) == true { tipsHit += 1 }
            }
            print("hit test zoom=\(Int(zoom))x mean=\(String(format: "%.1f", times.reduce(0, +) / Double(times.count) * 1e6))us p99=\(String(format: "%.1f", percentile(times, 0.99) * 1e6))us max=\(String(format: "%.1f", (times.max() ?? 0) * 1e6))us hits=\(found)/20000 tips-on-screen=\(tipsChecked) resolved-at-tip=\(tipsHit)")
        }

        // Label placement (uncached) and how many labels each zoom shows.
        for zoom in [1.0, 2.0, 4.0, 8.0] {
            tree.setCamera(.fit, animated: false)
            if zoom > 1 { tree.zoom(by: zoom, at: zoomPoint(), animated: false) }
            let transform = tree.transform(for: canvas)!
            var times = [Double](), count = 0, overlaps = 0
            for _ in 0..<5 {
                let started = Date()
                let labels = LivingTreeLabeler.layout(model: model, geometry: layout.geometry, hits: layout.hits, transform: transform, viewport: canvas, zoom: tree.camera.zoom, focus: nil, measure: LivingTreeLabelMetrics.measure)
                times.append(Date().timeIntervalSince(started)); count = labels.count
                let rects = labels.map { $0.rect(transform) }  // flat: tips are layout points
                overlaps = 0
                for i in rects.indices { for j in rects.indices where j > i && rects[i].intersects(rects[j]) { overlaps += 1 } }
            }
            print("labels zoom=\(Int(zoom))x placed=\(count) (budget \(LivingTreeLabeler.budget(zoom: zoom))) overlaps=\(overlaps) placement p50=\(ms(percentile(times, 0.5)))ms max=\(ms(times.max() ?? 0))ms")
        }

        // Resizing: refit (untouched view) and a zoomed view kept through resizes.
        tree.setCamera(.fit, animated: false)
        var resizes = [Double](), fills = [CGFloat]()
        for i in 0..<40 {
            let size = CGSize(width: 520 + CGFloat(i) * 35, height: 360 + CGFloat(i % 7) * 60)
            let started = Date()
            tree.viewportChanged(size)
            _ = tree.projected(for: size); _ = tree.labels(for: size, focus: nil, measure: LivingTreeLabelMetrics.measure)
            resizes.append(Date().timeIntervalSince(started))
            if let framing = tree.framing(for: size), let extent = tree.extent {
                let drawn = tree.camera.transform(in: framing).apply(extent)
                fills.append(max(drawn.width / framing.available.width, drawn.height / framing.available.height))
            }
        }
        tree.viewportChanged(canvas)
        tree.zoom(by: 3, at: zoomPoint(), animated: false)
        let zoomed = tree.cameraTarget
        let centre = tree.transform(for: canvas)!.invert(CGPoint(x: canvas.width / 2, y: (canvas.height + 30 - 12) / 2))
        for i in 0..<20 { tree.viewportChanged(CGSize(width: 700 + CGFloat(i) * 40, height: 420 + CGFloat(i) * 12)) }
        tree.viewportChanged(canvas)
        let after = tree.transform(for: canvas)!.invert(CGPoint(x: canvas.width / 2, y: (canvas.height + 30 - 12) / 2))
        print("resize 40 sizes: refit+project+labels p50=\(ms(percentile(resizes, 0.5)))ms max=\(ms(resizes.max() ?? 0))ms; fit fills \(String(format: "%.3f", fills.min() ?? 0))-\(String(format: "%.3f", fills.max() ?? 0)) of the limiting side; zoomed view through 20 resizes: zoom kept=\(tree.cameraTarget.zoom == zoomed.zoom) centre moved=\(String(format: "%.3f", hypot(after.x - centre.x, after.y - centre.y))) layout units")

        // Camera through journal updates: committed size changes to drawn folders rebuild the tree; the camera and the
        // view of what is on screen stay put.
        // The change feed is positioned first, and any rebuild that first read causes (the snapshot's measurement state
        // can differ from the catalog's after setup) finishes before "before" is recorded.
        let revisionAtStart = tree.revision
        tree.inventoryChanged()
        _ = await waitUntil { tree.illumination.cursor != nil }
        var stableSince = Date(), seen = tree.revision
        _ = await waitUntil(seconds: 10) {
            if tree.revision != seen { seen = tree.revision; stableSince = Date() }
            return Date().timeIntervalSince(stableSince) > 2.5
        }
        print("journal setup: first change read rebuilt the tree=\(tree.revision != revisionAtStart)")
        tree.setCamera(.fit, animated: false)
        tree.zoom(by: 4, at: zoomPoint(), animated: false)
        let cameraBefore = tree.cameraTarget, transformBefore = tree.transform(for: canvas)!
        let arrangementBefore = tree.arrangement!
        let watched = tree.model!.order.filter { key in
            guard let p = tipOnScreen(key) else { return false }
            return CGRect(origin: .zero, size: canvas).contains(p) && tree.model![key]!.depth >= 2
        }
        let tipsBefore = Dictionary(uniqueKeysWithValues: watched.compactMap { key in tipOnScreen(key).map { (key, $0) } })
        let centreBefore = centred()
        // Folders elsewhere in the tree (not the viewed subtree or its ancestors) change, as a background relist would.
        let viewed = Set(model.subtree(of: focusTarget) + model.ancestry(of: focusTarget))
        let changed = model.order.filter { model[$0]!.role == .branch && model[$0]!.depth == 2 && (model[$0]!.bytes ?? 0) > 50_000_000 && !viewed.contains($0) }.prefix(6)
        try? await Task.sleep(for: .milliseconds(1_100))
        let revision = tree.revision
        for key in changed { commitSizeChange(database, folder: key.nodeID!, delta: (model[key]!.bytes ?? 0) / 12) }
        tree.inventoryChanged()
        let rebuilt = await waitUntil(seconds: 10) { tree.revision > revision }
        var moved = [CGFloat](), movedOutside = [CGFloat]()
        let changedSet = Set(changed)
        let placementsBefore = arrangementBefore.placements
        for (key, before) in tipsBefore {
            guard let now = tipOnScreen(key) else { continue }
            let d = hypot(now.x - before.x, now.y - before.y)
            moved.append(d)
            if model.ancestry(of: key).allSatisfy({ !changedSet.contains($0) }) { movedOutside.append(d) }
        }
        for key in model.ancestry(of: focusTarget) + (model[model.rootKey]!.children) {
            if let a = placementsBefore[key], let b = tree.arrangement?.placements[key], a != b {
                print("  moved \(model[key]!.name): angle \(String(format: "%.5f", a.angle))->\(String(format: "%.5f", b.angle)) lower \(String(format: "%.5f", a.lower))->\(String(format: "%.5f", b.lower)) upper \(String(format: "%.5f", a.upper))->\(String(format: "%.5f", b.upper)) reach \(String(format: "%.4f", a.reach))->\(String(format: "%.4f", b.reach)) share \(String(format: "%.4f", a.share))->\(String(format: "%.4f", b.share))")
            }
        }
        print("journal update changed \(changed.count) folders elsewhere (+8% each: \(changed.map { model[$0]!.name }.joined(separator: ", "))); watched tips outside changed subtrees=\(movedOutside.count)")
        moved.sort()
        print("journal update (4x zoom on \(model[focusTarget]!.name)): centre element moved=\(String(format: "%.3f", centreDrift(centreBefore)))pt rebuilt=\(rebuilt) camera kept=\(tree.cameraTarget == cameraBefore) (views held \(tree.statistics.viewsHeld)) transform kept=\(tree.transform(for: canvas)! == transformBefore) watched tips=\(moved.count) unmoved(<0.5pt)=\(moved.filter { $0 < 0.5 }.count) median=\(String(format: "%.2f", moved.isEmpty ? 0 : moved[moved.count / 2]))pt max=\(String(format: "%.2f", moved.last ?? 0))pt")

        // Memory and remembered cameras over repeated navigation into folders and back.
        let folders = rootChildren.compactMap { model[$0]?.node }.filter { $0.kind == .directory }.sorted { ($0.allocatedBytes ?? 0) > ($1.allocatedBytes ?? 0) }.prefix(8)
        let startFootprint = footprint()
        var navigations = 0
        for cycle in 0..<4 {
            for folder in folders {
                browser.navigate(folder); await browser.load()
                tree.show(root: browser.directory ?? folder, trail: browser.breadcrumbs)
                _ = await waitUntil { tree.model?.root.id == folder.id }
                if cycle % 2 == 0 { tree.zoom(by: 2, at: nil, animated: false) }
                _ = render(nil, standard)
                browser.navigate(root); await browser.load()
                tree.show(root: browser.directory ?? root, trail: browser.breadcrumbs)
                _ = await waitUntil { tree.model?.root.id == root.id }
                _ = render(nil, standard)
                navigations += 2
            }
        }
        print("navigation x\(navigations): footprint start=\(startFootprint / 1024)KB end=\(footprint() / 1024)KB (+\((footprint() - startFootprint) / 1024)KB) remembered cameras=\(tree.rememberedCameraCount) (max 6)")

        // Idle: nothing scheduled once the camera is still.
        tree.setCamera(.fit, animated: false)
        tree.zoom(by: 2, at: nil, animated: true)
        // The motion timer runs on the main run loop: spin it until the move settles.
        let deadline = Date().addingTimeInterval(3)
        while tree.isMoving && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        let settled = !tree.isMoving
        let cpuBefore = cpuSeconds()
        RunLoop.main.run(until: Date().addingTimeInterval(5))
        print("idle 5 s after an animated zoom (settled=\(settled), moving=\(tree.isMoving)): cpu=\(String(format: "%.3f", cpuSeconds() - cpuBefore)) s")
        // MARK: 3D
        tree.setCamera(.fit, animated: false)
        tree.setDimension(.depth)
        tree.setOrbit(.standard, animated: false)
        tree.viewportChanged(canvas)
        if let dome = tree.domeLayout {
            let started = Date(); _ = LivingTreeGeometer3D.layout(tree.model!, tree.arrangement!)
            let layoutTime = Date().timeIntervalSince(started)
            var projections = [Double](), extents = [Double](), indexes = [Double]()
            for i in 0..<30 {
                let o = LivingTreeOrbit(yaw: Double(i) * 0.21, pitch: 0.35)
                var t = Date(); let g = LivingTreeProjection.geometry(dome, orbit: o); projections.append(Date().timeIntervalSince(t))
                t = Date(); _ = LivingTreeHitIndex(g); indexes.append(Date().timeIntervalSince(t))
                if i < 5 { t = Date(); _ = LivingTreeProjection.extent(dome, pitch: 0.3 + Double(i) * 0.1); extents.append(Date().timeIntervalSince(t)) }
            }
            print("3d layout \(dome.branches.count) branches \(ms(layoutTime))ms; projection p50=\(ms(percentile(projections, 0.5)))ms p95=\(ms(percentile(projections, 0.95)))ms; hit index p50=\(ms(percentile(indexes, 0.5)))ms; fit extent over a full turn p50=\(ms(percentile(extents, 0.5)))ms")
        }
        // Turning: one drag frame = a new projection, the base and label layers (labels placed again every ~7°).
        var turns = [(Double, Double)]()
        for _ in 0..<60 { tree.turn(yaw: 0.02, pitch: 0.002, animated: false); turns.append(frame()) }
        print("3d turn frame (0.02 rad steps) model p50=\(ms(percentile(turns.map(\.0), 0.5)))ms p95=\(ms(percentile(turns.map(\.0), 0.95)))ms | with raster @2x p50=\(ms(percentile(turns.map(\.1), 0.5)))ms p95=\(ms(percentile(turns.map(\.1), 0.95)))ms")
        // The fit does not change while turning: the zoom stays put and the tree is never clipped.
        tree.setOrbit(.standard, animated: false); tree.setCamera(.fit, animated: false)
        var clipped = 0, scales = Set<Int>()
        for i in 0..<72 {
            tree.setOrbit(LivingTreeOrbit(yaw: Double(i) * .pi / 36, pitch: 0.35), animated: false)
            guard let framing = tree.framing(for: canvas), let plane = tree.planeGeometry(), let extent = plane.extent else { continue }
            scales.insert(Int((framing.fitScale * 10_000).rounded()))
            if !CGRect(origin: .zero, size: canvas).insetBy(dx: -1, dy: -1).contains(tree.camera.transform(in: framing).apply(extent)) { clipped += 1 }
        }
        print("3d full turn at the fit: distinct fit scales=\(scales.count) clipped views=\(clipped)/72")
        // Hit testing in 3D: every on-screen tip resolves to itself or a tip drawn within 1.5 pt of it.
        tree.setOrbit(.standard, animated: false); tree.setCamera(.fit, animated: false)
        if let projected = tree.projected(for: canvas), let hits = tree.hitIndex() {
            var checked = 0, resolved = 0, times = [Double]()
            for branch in projected.geometry.branches where branch.role != .trunk && CGRect(origin: .zero, size: canvas).contains(branch.end) && LivingTreeDetail.isDrawn(branch) {
                checked += 1
                let t = Date(); let key = hits.hit(branch.end, transform: projected.transform); times.append(Date().timeIntervalSince(t))
                if let key, key == branch.key || projected.geometry[key].map({ hypot($0.end.x - branch.end.x, $0.end.y - branch.end.y) < 1.5 }) == true { resolved += 1 }
            }
            print("3d hit test: tips on screen=\(checked) resolved=\(resolved) mean=\(String(format: "%.1f", times.reduce(0, +) / Double(max(1, times.count)) * 1e6))us")
        }
        var labels3D = [Double](), labelCount = 0
        for _ in 0..<5 {
            let transform = tree.transform(for: canvas)!, layout = tree.layout()!
            let t = Date()
            labelCount = LivingTreeLabeler.layout(model: tree.model!, geometry: layout.geometry, hits: layout.hits, transform: transform, viewport: canvas, zoom: 1, focus: nil, measure: LivingTreeLabelMetrics.measure).count
            labels3D.append(Date().timeIntervalSince(t))
        }
        print("3d labels at the fit: \(labelCount) placed in p50=\(ms(percentile(labels3D, 0.5)))ms")
        // Animated turn (keys): frames to settle, then idle.
        tree.turn(yaw: 0.35, pitch: 0, animated: true)
        var turnFrames = 0
        while tree.isMoving && turnFrames < 1_000 { tree.stepMotion(1.0 / 120); turnFrames += 1 }
        print("3d animated turn (20°) settled in \(turnFrames) frames")
        // Journal update in 3D at 2x: orbit, camera and on-screen tips stay put when folders elsewhere change.
        tree.setOrbit(.standard, animated: false); tree.setCamera(.fit, animated: false)
        tree.zoom(by: 2, at: CGPoint(x: canvas.width / 2, y: canvas.height / 2), animated: false)
        let model3 = tree.model!
        let orbitBefore = tree.orbit, camera3 = tree.cameraTarget
        let centre3 = centred()
        let tips3 = Dictionary(uniqueKeysWithValues: tree.projected(for: canvas)!.geometry.branches.filter { CGRect(origin: .zero, size: canvas).contains($0.end) }.map { ($0.key, $0.end) })
        let viewed3 = Set(model3.subtree(of: focusTarget) + model3.ancestry(of: focusTarget))
        let changed3 = model3.order.filter { model3[$0]!.role == .branch && model3[$0]!.depth == 2 && (model3[$0]!.bytes ?? 0) > 50_000_000 && !viewed3.contains($0) }.prefix(4)
        try? await Task.sleep(for: .milliseconds(1_600))
        let revision3 = tree.revision
        for key in changed3 { commitSizeChange(database, folder: key.nodeID!, delta: (model3[key]!.bytes ?? 0) / 12) }
        tree.inventoryChanged()
        let rebuilt3 = await waitUntil(seconds: 10) { tree.revision > revision3 }
        let changedSet3 = Set(changed3)
        var moved3 = [CGFloat]()
        if let after = tree.projected(for: canvas)?.geometry {
            for (key, before) in tips3 where model3.ancestry(of: key).allSatisfy({ !changedSet3.contains($0) }) {
                if let now = after[key]?.end { moved3.append(hypot(now.x - before.x, now.y - before.y)) }
            }
        }
        moved3.sort()
        print("3d journal update (2x): centre element moved=\(String(format: "%.3f", centreDrift(centre3)))pt rebuilt=\(rebuilt3) orbit kept=\(tree.orbit == orbitBefore) camera kept=\(tree.cameraTarget == camera3) tips outside changed subtrees=\(moved3.count) unmoved(<0.5pt)=\(moved3.filter { $0 < 0.5 }.count) max=\(String(format: "%.2f", moved3.last ?? 0))pt")
        tree.setOrbit(.standard, animated: false); tree.setCamera(.fit, animated: false)
        tree.turn(yaw: 0.35, pitch: 0, animated: true)
        let deadline3 = Date().addingTimeInterval(3)
        while tree.isMoving && Date() < deadline3 { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        let cpu3 = cpuSeconds()
        RunLoop.main.run(until: Date().addingTimeInterval(5))
        print("3d idle 5 s after an animated turn (moving=\(tree.isMoving)): cpu=\(String(format: "%.3f", cpuSeconds() - cpu3)) s")

        // 3D renders.
        func shoot3D(_ name: String, _ size: CGSize, orbit: LivingTreeOrbit = .standard, _ camera: () -> Void) {
            tree.setOrbit(orbit, animated: false)
            shoot(name, size, camera)
        }
        // The view applies the remembered 2D/3D choice when it appears: 3D for these renders (in-memory default only).
        UserDefaults.standard.register(defaults: ["inventory.livingTree.dimension": LivingTreeDimension.depth.rawValue])
        if let rootNode = tree.model?.root { explorer.select(rootNode, through: []) }
        shoot3D("living-tree-3d", standard) {}
        shoot3D("living-tree-3d-turned", standard, orbit: LivingTreeOrbit(yaw: LivingTreeOrbit.standard.yaw + 1.9, pitch: 0.3)) {}
        shoot3D("living-tree-3d-above", standard, orbit: LivingTreeOrbit(yaw: 0.45, pitch: 1.15)) {}
        shoot3D("living-tree-3d-zoom", standard) { tree.zoom(by: 2.5, at: CGPoint(x: tree.viewport.width * 0.5, y: tree.viewport.height * 0.35), animated: false) }
        if let node = tree.model?[focusTarget]?.node, let m = tree.model {
            explorer.select(node, through: Array(m.ancestry(of: focusTarget).dropFirst().dropLast().compactMap { m[$0]?.node }))
            shoot3D("living-tree-3d-focused", standard) { tree.focus(on: focusTarget, animated: false) }
            print("3d focused \(m[focusTarget]!.name) zoom=\(LivingTreeView.percent(tree.camera.zoom)) yaw=\(String(format: "%.2f", tree.orbit.yaw))")
        }
        shoot3D("living-tree-3d-narrow", CGSize(width: 640, height: 640)) {}
        UserDefaults.standard.register(defaults: ["inventory.livingTree.dimension": LivingTreeDimension.flat.rawValue])
        tree.setDimension(.flat)
        print("footprint_end=\(footprint() / 1024)KB")
    }
}
