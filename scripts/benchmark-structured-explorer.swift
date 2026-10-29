import SwiftUI
import AppKit
import ImageIO
import UniformTypeIdentifiers
import SQLite3

// Structured Explorer: headless renders of the real explorer page (Structured Explorer, Navigator, Inspector) and of
// the classic Living Tree, plus measurements of both on the same model with the same pipeline (model work, then the
// canvas rasterized by ImageRenderer at 2×). Run through scripts/benchmark-structured-explorer.sh on an APFS clone under
// /private/tmp. Nothing is shown on screen: activation policy .prohibited, windows never ordered in. Preferences are
// registered in memory only (nothing is written to any preferences file). The only write is to the disposable clone
// (pending reconciliation cleared, as the camera benchmark does).

@MainActor func waitUntil(seconds: Double = 30, _ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while !condition() { if Date() > deadline { return false }; try? await Task.sleep(for: .milliseconds(10)) }
    return true
}
func writePNG(_ image: CGImage, to url: URL) {
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
    CGImageDestinationAddImage(destination, image, nil); CGImageDestinationFinalize(destination)
}
func footprint() -> Int64 {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let result = withUnsafeMutablePointer(to: &info) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) } }
    return result == KERN_SUCCESS ? Int64(info.phys_footprint) : -1
}
func pct(_ values: [Double], _ p: Double) -> Double { let s = values.sorted(); return s.isEmpty ? 0 : s[min(s.count - 1, Int(Double(s.count - 1) * p + 0.5))] }
func ms(_ s: Double) -> String { String(format: "%.2f", s * 1000) }
func timed<T>(_ body: () -> T) -> (T, Double) { let t0 = DispatchTime.now().uptimeNanoseconds; let v = body(); return (v, Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e9) }

/// A synthetic, highly unbalanced catalog: one folder holds 95%, a 40-level chain, and 1,500 tiny folders.
struct Unbalanced {
    var nodes = [Int64: InventoryNode](), children = [Int64: [Int64]]()
    static func node(_ id: Int64, _ parent: Int64?, _ name: String, folder: Bool, size: Int64, children: Int64) -> InventoryNode {
        InventoryNode(id: id, parentID: parent, identity: InventoryIdentity(device: 1, inode: UInt64(id), birthNanoseconds: 1), path: "/u/\(id)/\(name)", name: name,
                      kind: folder ? .directory : .file, logicalBytes: size, allocatedBytes: size, previousLogicalBytes: nil, previousAllocatedBytes: nil, objectLogicalBytes: nil, objectAllocatedBytes: nil,
                      directLogicalBytes: 0, directAllocatedBytes: 0, childCount: children, descendantFiles: 0, descendantDirectories: 0, status: .complete,
                      coverageState: "complete", listingState: nil, statusReason: nil, measuredAt: nil, modifiedAt: nil, generation: 1, isHardlinkAlias: false, historicalGrowthBytes: nil)
    }
    init() {
        var spec = [(Int64, Int64?, String, Bool, Int64)](), next: Int64 = 1
        func add(_ parent: Int64?, _ name: String, folder: Bool, size: Int64 = 0) -> Int64 { let id = next; next += 1; spec.append((id, parent, name, folder, size)); return id }
        let root = add(nil, "Unbalanced", folder: true)
        let giant = add(root, "giant", folder: true)
        for i in 0..<30 { _ = add(giant, "huge\(i).bin", folder: false, size: 30_000_000_000 - Int64(i) * 100_000_000) }
        var chain = add(root, "chain", folder: true)
        for level in 0..<40 { chain = add(chain, "level\(level)", folder: true); _ = add(chain, "f.bin", folder: false, size: 40_000_000) }
        let crowd = add(root, "crowd", folder: true)
        for i in 0..<1_500 { let f = add(crowd, "small\(i)", folder: true); _ = add(f, "x", folder: false, size: Int64(1_000_000 + i)) }
        var kids = [Int64: [Int64]](), size = [Int64: Int64]()
        for (id, parent, _, _, bytes) in spec { size[id] = bytes; if let parent { kids[parent, default: []].append(id) } }
        func total(_ id: Int64) -> Int64 { (kids[id] ?? []).reduce(size[id]!) { $0 + total($1) } }
        for (id, parent, name, folder, _) in spec { nodes[id] = Self.node(id, parent, name, folder: folder, size: total(id), children: Int64(kids[id]?.count ?? 0)) }
        children = kids
    }
    func span(_ parent: Int64, _ count: Int) -> LivingTreeBuilder.Span {
        let all = (children[parent] ?? []).map { nodes[$0]! }.sorted { ($0.allocatedBytes ?? 0, $1.id) > ($1.allocatedBytes ?? 0, $0.id) }
        let page = Array(all.prefix(count)), rest = all.dropFirst(count)
        guard let last = page.last, !rest.isEmpty else { return (InventoryChildPage(items: page, next: nil), nil) }
        return (InventoryChildPage(items: page, next: InventoryChildCursor(allocated: last.allocatedBytes, name: last.name, id: last.id)),
                InventoryChildRemainder(count: Int64(rest.count), allocated: rest.reduce(0) { $0 + ($1.allocatedBytes ?? 0) }, unmeasured: 0))
    }
}

@main struct StructuredExplorerBenchmark {
    @MainActor static func main() async {
        setvbuf(stdout, nil, _IOLBF, 0)
        _ = NSApplication.shared
        NSApplication.shared.setActivationPolicy(.prohibited)
        let args = CommandLine.arguments
        guard args.count == 3 else { fputs("usage: benchmark <catalog clone> <output folder>\n", stderr); exit(2) }
        let database = args[1], out = URL(fileURLWithPath: args[2], isDirectory: true)
        let shots = out.appendingPathComponent("headless-renders", isDirectory: true)
        try? FileManager.default.createDirectory(at: shots, withIntermediateDirectories: true)
        let defaults = UserDefaults.standard
        func prefer(_ values: [String: Any]) { defaults.register(defaults: values) }   // registration domain: in memory only
        prefer(["inventory.explorer.visualization": "tree", "inventory.explorer.mapHeight": 600.0, "inventory.explorer.inspector": true, "inventory.explorer.showMap": true,
                "inventory.explorer.treeNavigatorExpanded": true, "inventory.livingTree.renderer": "structured", "inventory.structuredExplorer.depth": 3])
        var lines = [String](), json = [String: Any](), failures = [String](), checks = 0
        func require(_ ok: Bool, _ message: String) { checks += 1; if !ok { failures.append(message); fputs("FAIL \(message)\n", stderr) } }
        func say(_ s: String) { print(s); lines.append(s) }
        var db: OpaquePointer?
        if sqlite3_open(database, &db) == SQLITE_OK { sqlite3_exec(db, "DELETE FROM inventory_reconcile; DELETE FROM inventory_prune_jobs;", nil, nil, nil); sqlite3_close(db) }

        // MARK: Data — the production controller's model
        let browser = InventoryBrowserModel(database: database, readiness: ViewerReadiness(output: nil))
        await browser.load()
        guard let root = browser.directory else { fputs("no inventory root\n", stderr); exit(1) }
        let explorer = browser.explorer, tree = browser.livingTree, state = browser.structuredExplorer
        explorer.show(root: root, trail: browser.breadcrumbs)
        tree.show(root: root, trail: browser.breadcrumbs)
        guard await waitUntil({ tree.model != nil }) else { fputs("tree did not build\n", stderr); exit(1) }
        if let largest = tree.model![tree.model!.rootKey]!.children.compactMap({ tree.model![$0]?.node }).filter({ $0.kind == .directory }).max(by: { ($0.allocatedBytes ?? 0) < ($1.allocatedBytes ?? 0) }) {
            for target in [largest, root] {
                browser.navigate(target); await browser.load(); tree.show(root: browser.directory ?? target, trail: browser.breadcrumbs)
                _ = await waitUntil { tree.model?.root.id == target.id }
            }
            explorer.show(root: browser.directory ?? root, trail: browser.breadcrumbs)
        }
        let model = tree.model!
        let rootDepth = model[model.rootKey]!.depth
        let major = model[model.rootKey]!.children.filter { model[$0]?.role == .branch }.max { (model[$0]!.bytes ?? 0) < (model[$1]!.bytes ?? 0) }!
        let deep = model.order.filter { model[$0]!.role == .branch && model[$0]!.depth - rootDepth >= 5 && (model[$0]!.bytes ?? 0) >= (model.trunkBytes ?? 1) / 2000 }
            .max { (model[$0]!.depth, model[$0]!.bytes ?? 0) < (model[$1]!.depth, model[$1]!.bytes ?? 0) } ?? major
        var byName = [String: [LivingTreeKey]]()
        for key in model.order where model[key]!.role == .branch { byName[model[key]!.name, default: []].append(key) }
        let repeated = byName.filter { $0.value.count > 1 }.max { $0.value.count < $1.value.count }
        say("model elements=\(model.count) max depth=\(model.order.map { model[$0]!.depth }.max()! - rootDepth) trunk=\(AtlasText.bytes(model.trunkBytes ?? 0))")
        say("targets large=\(model[major]!.node!.path) deep=\(model[deep]!.node!.path) (level \(model[deep]!.depth - rootDepth))")
        func select(_ key: LivingTreeKey) {
            guard let node = model[key]?.node else { return }
            explorer.select(node, through: model.ancestry(of: key).dropFirst().dropLast().compactMap { model[$0]?.node })
        }

        // MARK: Renders — the real explorer page, offscreen
        func capture<V: View>(_ view: V, _ size: CGSize, dark: Bool, measured: ((Double) -> Void)? = nil, settle: (() -> Void)? = nil) async -> CGImage? {
            let hostStart = DispatchTime.now().uptimeNanoseconds
            let window = NSWindow(contentRect: CGRect(x: -20000, y: -20000, width: size.width, height: size.height), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height).background(Color(nsColor: .windowBackgroundColor)))
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            let hostSeconds = Double(DispatchTime.now().uptimeNanoseconds - hostStart) / 1e9
            for _ in 0..<6 { host.layoutSubtreeIfNeeded(); try? await Task.sleep(for: .milliseconds(40)) }
            if let settle { settle(); for _ in 0..<12 { host.layoutSubtreeIfNeeded(); try? await Task.sleep(for: .milliseconds(50)) } }
            let bitmapStart = DispatchTime.now().uptimeNanoseconds
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { require(false, "offscreen page bitmap unavailable"); return nil }
            host.cacheDisplay(in: host.bounds, to: rep)
            let image = rep.cgImage
            measured?(hostSeconds + Double(DispatchTime.now().uptimeNanoseconds - bitmapStart) / 1e9)
            window.contentView = nil
            return image
        }
        func save(_ name: String, _ image: CGImage?) {
            guard let image else { require(false, "missing render \(name)"); return }
            let url = shots.appendingPathComponent(name + ".png")
            writePNG(image, to: url)
            require(FileManager.default.fileExists(atPath: url.path), "PNG written for \(name)")
            say("render \(name) \(image.width)x\(image.height)")
        }
        let page = CGSize(width: 1440, height: 900), minimum = CGSize(width: 1000, height: 640)
        let pageView = InventoryExplorerView(browser: browser)
        for dark in [true, false] {
            let s = dark ? "dark" : "light"
            prefer(["inventory.livingTree.renderer": "structured", "inventory.structuredExplorer.depth": 3])
            explorer.select(root, through: []); state.camera = StructuredExplorerCamera()
            save("new-01-overview-\(s)", await capture(pageView, page, dark: dark))
            save("new-02-large-selected-\(s)", await capture(pageView, page, dark: dark) { select(major) })
            save("new-03-deep-selected-\(s)", await capture(pageView, page, dark: dark) { select(deep) })
            save("new-04-zoomed-out-\(s)", await capture(pageView, page, dark: dark) { select(major); state.camera = StructuredExplorerCamera(zoom: 0.6) })
            save("new-05-zoomed-in-\(s)", await capture(pageView, page, dark: dark) {
                select(major)
                let layout = state.layout(model, revision: tree.revision, depth: 3, selection: major)
                if let rect = layout.subtreeBounds(major) { state.camera.frame(rect, bounds: layout.bounds, size: state.viewport) }
            })
            for levels in [1, 2, 4, 6] {
                prefer(["inventory.structuredExplorer.depth": levels])
                save("new-06-levels-\(levels)-\(s)", await capture(InventoryExplorerView(browser: browser), page, dark: dark) { explorer.select(root, through: []); state.camera = StructuredExplorerCamera() })
            }
            prefer(["inventory.structuredExplorer.depth": 3])
            if let repeated, dark { save("new-07-repeated-name-\(s)", await capture(pageView, page, dark: dark) { select(repeated.value[1]); state.camera = StructuredExplorerCamera() }) }
            save("new-08-minimum-window-\(s)", await capture(InventoryExplorerView(browser: browser), minimum, dark: dark) { select(major); state.camera = StructuredExplorerCamera() })
            // The classic tree, same page, same selections (QA fallback renderer).
            prefer(["inventory.livingTree.renderer": "classic"])
            save("old-01-overview-\(s)", await capture(InventoryExplorerView(browser: browser), page, dark: dark) { explorer.select(root, through: []); tree.setCamera(.fit, animated: false) })
            save("old-02-large-selected-\(s)", await capture(InventoryExplorerView(browser: browser), page, dark: dark) { select(major) })
            save("old-03-deep-selected-\(s)", await capture(InventoryExplorerView(browser: browser), page, dark: dark) { select(deep); tree.focus(on: deep, animated: false) })
            prefer(["inventory.livingTree.renderer": "structured"])
        }
        // Explore: double-click semantics (the app's navigation) into the large folder, then Up.
        browser.navigate(model[major]!.node!); await browser.load()
        _ = await waitUntil { tree.model?.root.id == model[major]!.node!.id }
        save("new-09-explored-large-folder-dark", await capture(InventoryExplorerView(browser: browser), page, dark: true) { explorer.select(model[major]!.node!, through: []) })
        browser.navigate(root); await browser.load()
        _ = await waitUntil { tree.model?.root.id == root.id }
        explorer.show(root: root, trail: browser.breadcrumbs); explorer.select(root, through: [])

        // Production input-handler bridge, hosted offscreen. These call the input view's closure in process;
        // no NSEvent is posted, no NSCursor operation is invoked and no desktop window is ordered or activated.
        // Physical-device/keyboard/VoiceOver behavior still needs separate native QA.
        prefer(["inventory.livingTree.renderer": "structured", "inventory.structuredExplorer.depth": 3])
        let inputWindow = NSWindow(contentRect: CGRect(x: -20000, y: -20000, width: page.width, height: page.height),
                                   styleMask: [.borderless], backing: .buffered, defer: false)
        inputWindow.isReleasedWhenClosed = false
        let inputHost = NSHostingView(rootView: InventoryExplorerView(browser: browser).frame(width: page.width, height: page.height))
        inputWindow.contentView = inputHost
        func pump() async {
            for _ in 0..<6 { inputHost.layoutSubtreeIfNeeded(); try? await Task.sleep(for: .milliseconds(30)) }
        }
        func inputView(_ view: NSView) -> LivingTreeInputView? {
            if let input = view as? LivingTreeInputView { return input }
            for child in view.subviews { if let found = inputView(child) { return found } }
            return nil
        }
        state.camera = StructuredExplorerCamera()
        await pump()
        if let input = inputView(inputHost), let drawn = state.drawn, let target = drawn.layout[major] {
            let p = drawn.transform.apply(target.point)
            input.handle?(.down(p, clicks: 1, [])); input.handle?(.up(p, clicks: 1))
            await pump()
            require(explorer.selection == model[major]?.node?.id && browser.parentID == root.id,
                    "hosted click selects the folder through the shared explorer without navigating")
            let oldZoom = state.camera.zoom
            input.handle?(.scroll(CGVector(dx: 0, dy: 1), precise: false, momentum: false, [], p))
            await pump()
            require(state.camera.zoom > oldZoom, "hosted wheel route changes the Structured Explorer camera zoom")
            let wheelZoom = state.camera.zoom
            input.handle?(.magnify(0.25, p)); await pump()
            require(state.camera.zoom > wheelZoom, "hosted pinch route changes the Structured Explorer camera zoom")
            let beforePan = state.camera
            let oldSelection = explorer.selection
            input.handle?(.down(p, clicks: 1, []))
            input.handle?(.dragged(CGPoint(x: p.x + 35, y: p.y + 20)))
            input.handle?(.up(CGPoint(x: p.x + 35, y: p.y + 20), clicks: 1))
            await pump()
            require(state.camera != beforePan && explorer.selection == oldSelection, "hosted drag pans without selecting another item")
            input.handle?(.command(.reset)); await pump()
            require(state.camera.isFit, "hosted reset command restores the fit")
            select(deep); await pump()
            require(state.drawn?.layout[deep] != nil && explorer.selection == model[deep]?.node?.id,
                    "external shared selection is retained in the rendered hierarchy")
            explorer.select(root, through: []); state.camera = StructuredExplorerCamera(); await pump()
            require(state.drawn?.layout[deep] == nil, "clearing deep selection removes its extra spur from the rendered hierarchy")
            if let current = state.drawn, let target = current.layout[major] {
                let point = current.transform.apply(target.point)
                input.handle?(.down(point, clicks: 2, [])); input.handle?(.up(point, clicks: 2))
                require(browser.parentID == model[major]?.node?.id, "hosted double-click reaches the application's folder navigation")
                await browser.load(); await pump()
                require(await waitUntil { tree.model?.root.id == model[major]?.node?.id }, "hosted explored folder becomes the hierarchy centre")
            } else { require(false, "hosted double-click target is present") }
        } else { require(false, "production Structured Explorer input view is hosted") }
        inputWindow.contentView = nil
        browser.navigate(root); await browser.load(); tree.show(root: root, trail: browser.breadcrumbs)
        require(await waitUntil { tree.model?.root.id == root.id }, "input bridge restores the disposable root")
        explorer.show(root: root, trail: browser.breadcrumbs); explorer.select(root, through: [])
        state.camera = StructuredExplorerCamera()
        say("HOSTED INPUT bridge checks complete (\(failures.count) failures); desktop input and keyboard/VoiceOver are not tested")

        // Navigation/capture may rebuild the bounded model. Freeze the current root model for BOTH renderers'
        // comparative frame measurements instead of comparing a pre-navigation snapshot with the rebuilt controller.
        do {
        let model = tree.model!
        require(model.root.id == root.id, "comparative renderers measure the same restored root model")
        // MARK: Measurements — the same canvas and pipeline for both
        let canvas = CGSize(width: 1100, height: 600)
        func raster<V: View>(_ v: V) -> Double { let (_, s) = timed { let r = ImageRenderer(content: v.frame(width: canvas.width, height: canvas.height)); r.scale = 2; _ = r.cgImage }; return s }
        var results = [String: Any]()

        // Classic Living Tree (baseline).
        do {
            tree.viewportChanged(canvas); tree.setCamera(.fit, animated: false)
            var memory = LivingTreeMemory()
            let (arrangement, arrangeS) = timed { LivingTreeArranger.arrange(model, memory: &memory) }
            let (geometry, geomS) = timed { LivingTreeGeometer.layout(model, arrangement, in: canvas) }
            let (_, hitS) = timed { _ = LivingTreeHitIndex(geometry) }
            func frame() -> (Double, Int) {
                let t0 = Date()
                guard let projected = tree.projected(for: canvas) else { return (0, 0) }
                let labels = tree.labels(for: canvas, focus: nil, measure: LivingTreeLabelMetrics.measure)
                let model0 = Date().timeIntervalSince(t0)
                return (model0 + raster(ZStack {
                    LivingTreeBaseCanvas(revision: tree.revision, size: canvas, transform: projected.transform, zoom: tree.camera.zoom, geometry: projected.geometry, model: tree.model!)
                    LivingTreeLabelCanvas(labels: labels, tips: labels.map { projected.geometry[$0.key]?.end ?? projected.transform.apply($0.tip) }, size: canvas)
                }), labels.count)
            }
            let first = frame()
            var pans = [Double](), zooms = [Double]()
            for i in 0..<40 { tree.pan(by: CGVector(dx: i % 20 < 10 ? 9 : -9, dy: 4)); pans.append(frame().0) }
            tree.setCamera(.fit, animated: false)
            for i in 0..<40 { tree.zoom(by: i < 20 ? 1.08 : 1 / 1.08, at: CGPoint(x: canvas.width / 2, y: canvas.height / 2), animated: false); zooms.append(frame().0) }
            tree.setCamera(.fit, animated: false)
            let layoutMs = (arrangeS + geomS + hitS) * 1000
            results["classic"] = ["layoutMs": layoutMs, "firstFrameMs": layoutMs + first.0 * 1000, "panP50": pct(pans, 0.5) * 1000, "panP95": pct(pans, 0.95) * 1000,
                                  "zoomP50": pct(zooms, 0.5) * 1000, "zoomP95": pct(zooms, 0.95) * 1000, "labelsFit": first.1, "elements": geometry.branches.count]
            say("CLASSIC layout \(String(format: "%.2f", layoutMs))ms first useful frame \(String(format: "%.2f", layoutMs + first.0 * 1000))ms pan p50/p95 \(ms(pct(pans, 0.5)))/\(ms(pct(pans, 0.95))) zoom p50/p95 \(ms(pct(zooms, 0.5)))/\(ms(pct(zooms, 0.95))) labels \(first.1)")
        }

        // Structured Explorer (production types).
        let palette = StructuredExplorerPalette(dark: true)
        let before = footprint()
        var layoutTimes = [Double](), layout: StructuredExplorerLayout!
        for _ in 0..<7 { let (l, s) = timed { StructuredExplorerLayout(model: model, depth: 3) }; layout = l; layoutTimes.append(s) }
        var camera = StructuredExplorerCamera(), selected: LivingTreeKey? = nil
        func frame() -> (Double, Int) {
            let t0 = Date()
            let t = camera.transform(bounds: layout.bounds, size: canvas)
            let labels = layout.labels(model: model, transform: t, size: canvas, selected: selected, hovered: nil, detail: StructuredExplorerText.size, measure: StructuredExplorerPainter.measure)
            let model0 = Date().timeIntervalSince(t0)
            let painter = StructuredExplorerPainter(layout: layout, model: model, coloring: tree.coloring, palette: palette)
            return (model0 + raster(Canvas { ctx, _ in painter.paint(&ctx, transform: t, size: canvas, selected: selected, exact: true, hovered: nil, labels: labels) }), labels.count)
        }
        let first = frame()
        let after = footprint()
        var pans = [Double](), pans4 = [Double](), zooms = [Double]()
        for i in 0..<40 { camera.pan(by: CGVector(dx: i % 20 < 10 ? 9 : -9, dy: 4), bounds: layout.bounds, size: canvas); pans.append(frame().0) }
        camera = StructuredExplorerCamera()
        for i in 0..<40 { camera.zoom(by: i < 20 ? 1.08 : 1 / 1.08, at: CGPoint(x: canvas.width / 2, y: canvas.height / 2), bounds: layout.bounds, size: canvas); zooms.append(frame().0) }
        camera = StructuredExplorerCamera(); camera.zoom(by: 4, at: nil, bounds: layout.bounds, size: canvas)
        let labels4 = frame().1
        for i in 0..<40 { camera.pan(by: CGVector(dx: i % 20 < 10 ? 9 : -9, dy: 4), bounds: layout.bounds, size: canvas); pans4.append(frame().0) }
        camera = StructuredExplorerCamera()
        // Selection: select → (no relayout when shown) → labels and frame.
        var selectTimes = [Double](), relayouts = 0
        let cacheState = StructuredExplorerState()
        _ = cacheState.layout(model, revision: tree.revision, depth: 3, selection: nil)
        for key in layout.nodes.dropFirst().prefix(20).map(\.key) + [deep] {
            let (_, s) = timed { let count = cacheState.layouts; layout = cacheState.layout(model, revision: tree.revision, depth: 3, selection: key); relayouts += cacheState.layouts - count; selected = key; _ = frame() }
            selectTimes.append(s)
        }
        selected = nil; layout = StructuredExplorerLayout(model: model, depth: 3)
        // Click accuracy: every shown disc at its centre and every label, at the fit and 4×.
        func accuracy(_ zoom: Double) -> (Int, Int, Int, Int) {
            var discs = 0, labelHits = 0, labelTotal = 0
            for node in layout.nodes {
                var c = StructuredExplorerCamera(); c.zoom(by: zoom, at: nil, bounds: layout.bounds, size: canvas); if zoom > 1 { c.center = node.point }
                let t = c.transform(bounds: layout.bounds, size: canvas)
                if layout.hit(t.apply(node.point), transform: t, labels: []) == node.key { discs += 1 }
            }
            var c = StructuredExplorerCamera(); c.zoom(by: zoom, at: nil, bounds: layout.bounds, size: canvas)
            let t = c.transform(bounds: layout.bounds, size: canvas)
            let labels = layout.labels(model: model, transform: t, size: canvas, selected: nil, hovered: nil, detail: StructuredExplorerText.size, measure: StructuredExplorerPainter.measure)
            for label in labels {
                labelTotal += 1
                let local = CGPoint(x: label.rect.midX, y: label.rect.midY)
                let p: CGPoint
                if label.angle == 0 { p = local } else {
                    let d = CGPoint(x: local.x - label.anchor.x, y: local.y - label.anchor.y), a = label.angle
                    p = CGPoint(x: label.anchor.x + d.x * cos(a) - d.y * sin(a), y: label.anchor.y + d.x * sin(a) + d.y * cos(a))
                }
                if layout.hit(p, transform: t, labels: labels) == label.key { labelHits += 1 }
            }
            return (discs, layout.nodes.count, labelHits, labelTotal)
        }
        let a1 = accuracy(1), a4 = accuracy(4)
        // Recentre: Explore the large folder (the app's navigation, a catalog read off the main thread) and Up again.
        var recentre = [Double](), up = [Double]()
        for _ in 0..<3 {
            let t0 = Date()
            browser.navigate(model[major]!.node!); await browser.load(); tree.show(root: browser.directory!, trail: browser.breadcrumbs)
            _ = await waitUntil { tree.model?.root.id == model[major]!.node!.id }
            _ = StructuredExplorerLayout(model: tree.model!, depth: 3)
            recentre.append(Date().timeIntervalSince(t0))
            let t1 = Date()
            browser.navigate(root); await browser.load(); tree.show(root: browser.directory!, trail: browser.breadcrumbs)
            _ = await waitUntil { tree.model?.root.id == root.id }
            _ = StructuredExplorerLayout(model: tree.model!, depth: 3)
            up.append(Date().timeIntervalSince(t1))
        }
        // Offscreen page costs; capture reports host/initial layout + bitmap separately from its fixed settling waits.
        // Deferred work during those waits is excluded: this is NOT end-to-end section-switch latency.
        var pageNew = [Double](), pageOld = [Double]()
        for renderer in ["structured", "classic"] {
            prefer(["inventory.livingTree.renderer": renderer])
            for _ in 0..<3 {
                _ = await capture(InventoryExplorerView(browser: browser), page, dark: true, measured: { seconds in
                    if renderer == "structured" { pageNew.append(seconds) } else { pageOld.append(seconds) }
                })
            }
        }
        prefer(["inventory.livingTree.renderer": "structured"])
        let layoutMs = pct(layoutTimes, 0.5) * 1000
        results["structured"] = ["layoutMs": layoutMs, "firstFrameMs": layoutMs + first.0 * 1000, "panP50": pct(pans, 0.5) * 1000, "panP95": pct(pans, 0.95) * 1000,
                                 "pan4xP50": pct(pans4, 0.5) * 1000, "pan4xP95": pct(pans4, 0.95) * 1000, "zoomP50": pct(zooms, 0.5) * 1000, "zoomP95": pct(zooms, 0.95) * 1000,
                                 "labelsFit": first.1, "labels4x": labels4, "shown": layout.nodes.count, "selectP50": pct(selectTimes, 0.5) * 1000, "selectP95": pct(selectTimes, 0.95) * 1000,
                                 "relayoutsForSelections": relayouts, "memoryDeltaMB": Double(after - before) / 1_048_576,
                                 "discHitsFit": a1.0, "discHits4x": a4.0, "discs": a1.1, "labelHitsFit": a1.2, "labelsTestedFit": a1.3, "labelHits4x": a4.2, "labelsTested4x": a4.3,
                                 "recentreMs": recentre.map { $0 * 1000 }, "upMs": up.map { $0 * 1000 }, "pageStructuredHostAndBitmapMs": pageNew.map { $0 * 1000 }, "pageClassicHostAndBitmapMs": pageOld.map { $0 * 1000 }]
        say("STRUCTURED layout \(String(format: "%.2f", layoutMs))ms (shown \(layout.nodes.count)) first useful frame \(String(format: "%.2f", layoutMs + first.0 * 1000))ms pan p50/p95 \(ms(pct(pans, 0.5)))/\(ms(pct(pans, 0.95))) pan@4x \(ms(pct(pans4, 0.5)))/\(ms(pct(pans4, 0.95))) zoom p50/p95 \(ms(pct(zooms, 0.5)))/\(ms(pct(zooms, 0.95))) labels fit \(first.1) 4x \(labels4)")
        say("STRUCTURED select→frame p50/p95 \(ms(pct(selectTimes, 0.5)))/\(ms(pct(selectTimes, 0.95)))ms (re-layouts for \(selectTimes.count) selections: \(relayouts)); memory Δ \(String(format: "%.2f", Double(after - before) / 1_048_576))MB")
        say("STRUCTURED click accuracy discs fit \(a1.0)/\(a1.1) 4x \(a4.0)/\(a4.1); labels fit \(a1.2)/\(a1.3) 4x \(a4.2)/\(a4.3)")
        say("STRUCTURED recentre (Explore, catalog read + layout) \(recentre.map { ms($0) }.joined(separator: "/"))ms; Up \(up.map { ms($0) }.joined(separator: "/"))ms")
        say("PAGE (offscreen host + initial layout + bitmap; fixed settling waits excluded) structured \(pageNew.map { ms($0) }.joined(separator: "/"))ms classic \(pageOld.map { ms($0) }.joined(separator: "/"))ms")

        // MARK: Larger and unbalanced hierarchies
        var scaling = [[String: Any]]()
        for elements in [10_000, 20_000] {
            let controller = LivingTreeController(database: database, budget: LivingTreeBudget(elements: elements))
            controller.show(root: root, trail: [root])
            guard await waitUntil(seconds: 120, { controller.model != nil }) else { continue }
            let big = controller.model!
            let (l, s) = timed { StructuredExplorerLayout(model: big, depth: 3) }
            let (l6, s6) = timed { StructuredExplorerLayout(model: big, depth: 6) }
            scaling.append(["budget": elements, "elements": big.count, "truncated": big.truncated, "layout3Ms": s * 1000, "shown3": l.nodes.count, "layout6Ms": s6 * 1000, "shown6": l6.nodes.count])
            say("scale budget=\(elements) elements=\(big.count) truncated=\(big.truncated): layout L3 \(ms(s))ms (\(l.nodes.count) shown), L6 \(ms(s6))ms (\(l6.nodes.count) shown)")
        }
        let unbalanced = Unbalanced()
        let skew = LivingTreeBuilder.build(root: unbalanced.nodes[1]!, budget: LivingTreeBudget(elements: 20_000, perFolder: 2_000, minimumShare: 0)) { unbalanced.span($0, $1) }
        let deepest = skew.order.max { skew[$0]!.depth < skew[$1]!.depth }!
        let (sk, skS) = timed { StructuredExplorerLayout(model: skew, depth: 6, keep: deepest) }
        let skT = StructuredExplorerCamera().transform(bounds: sk.bounds, size: canvas)
        let skLabels = sk.labels(model: skew, transform: skT, size: canvas, selected: deepest, hovered: nil, detail: StructuredExplorerText.size, measure: StructuredExplorerPainter.measure)
        let skFrame = raster(Canvas { ctx, _ in StructuredExplorerPainter(layout: sk, model: skew, coloring: .empty, palette: palette).paint(&ctx, transform: skT, size: canvas, selected: deepest, exact: true, hovered: nil, labels: skLabels) })
        scaling.append(["unbalancedElements": skew.count, "layoutMs": skS * 1000, "shown": sk.nodes.count, "frameMs": skFrame * 1000, "spurLevels": sk[deepest]?.elided ?? -1])
        say("unbalanced synthetic elements=\(skew.count) (one folder 95%, 1,500 tiny folders, 40-level chain): layout L6 with deepest selected \(ms(skS))ms, \(sk.nodes.count) shown, frame \(ms(skFrame))ms, spur skips \(sk[deepest]?.elided ?? -1) levels, labels \(skLabels.count)")

        require(a1.0 == a1.1 && a4.0 == a4.1, "every disc centre hits at fit and 4x")
        require(a1.2 == a1.3 && a4.2 == a4.3, "every horizontal/rotated label centre hits its element")
        require(pct(pans, 0.95) < 1.0 / 60 && pct(zooms, 0.95) < 1.0 / 60, "structured pan/zoom p95 fits the 16.67ms offscreen 60Hz frame budget")
        require((sk[deepest]?.elided ?? 0) > 0, "deepest synthetic selection has a counted spur")
        json["scope"] = "Headless model/layout and offscreen raster costs on the current Mac. Warm caches; not physical input, display pacing, cold launch, or Mac mini acceptance. Page timings exclude fixed settling and deferred work during settling. Memory delta is warmed incremental allocation, not total app footprint."
        json["frameBudgetMs"] = 1000.0 / 60
        json["failures"] = failures
        json["checks"] = checks
        json["results"] = results; json["scaling"] = scaling
        if let data = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]) { try? data.write(to: out.appendingPathComponent("measurements.json")) }
        try? lines.joined(separator: "\n").write(to: out.appendingPathComponent("measurements.log"), atomically: true, encoding: .utf8)
        exit(failures.isEmpty ? 0 : 1)
        }
    }
}
