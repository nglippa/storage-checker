import SwiftUI
import AppKit
import ImageIO
import UniformTypeIdentifiers
import SQLite3

// Headless evaluation of the current Living Tree and the two prototypes on one catalog clone: the same model (the
// production controller's bounded read), the same canvas sizes, the same frame pipeline (model work, then the canvas
// rasterized by ImageRenderer at 2×) and the same camera sequences. Writes screenshots, a comparison board and
// measurements. Nothing is shown on screen: activation policy .prohibited, windows never ordered in. The only write
// is to the disposable clone (pending reconciliation cleared, as the camera benchmark does).

@MainActor func waitUntil(seconds: Double = 30, _ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while !condition() { if Date() > deadline { return false }; try? await Task.sleep(for: .milliseconds(25)) }
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

@MainActor final class Report {
    var lines = [String](), json = [String: Any]()
    func say(_ s: String) { print(s); lines.append(s) }
    func record(_ key: String, _ value: Any) { json[key] = value }
}

@main struct PrototypeHarness {
    @MainActor static func main() async {
        setvbuf(stdout, nil, _IOLBF, 0)
        _ = NSApplication.shared
        NSApplication.shared.setActivationPolicy(.prohibited)
        let args = CommandLine.arguments
        guard args.count == 3 else { fputs("usage: harness <catalog clone> <output folder>\n", stderr); exit(2) }
        let database = args[1], out = URL(fileURLWithPath: args[2], isDirectory: true)
        let shots = out.appendingPathComponent("screens", isDirectory: true)
        try? FileManager.default.createDirectory(at: shots, withIntermediateDirectories: true)
        UserDefaults.standard.register(defaults: ["inventory.explorer.visualization": "tree", "inventory.explorer.mapHeight": 560.0, "inventory.explorer.inspector": true])
        let report = Report()
        var db: OpaquePointer?
        if sqlite3_open(database, &db) == SQLITE_OK { sqlite3_exec(db, "DELETE FROM inventory_reconcile; DELETE FROM inventory_prune_jobs;", nil, nil, nil); sqlite3_close(db) }

        // MARK: Data — the production controller's model
        let browser = InventoryBrowserModel(database: database, readiness: ViewerReadiness(output: nil))
        await browser.load()
        guard let root = browser.directory else { fputs("no inventory root\n", stderr); exit(1) }
        let explorerModel = browser.explorer, tree = browser.livingTree
        explorerModel.show(root: root, trail: browser.breadcrumbs)
        tree.show(root: root, trail: browser.breadcrumbs)
        guard await waitUntil({ tree.model != nil }) else { fputs("tree did not build\n", stderr); exit(1) }
        // Warm: into the largest folder and back, so the measured tree is the full, settled one (as the camera benchmark).
        if let largest = tree.model![tree.model!.rootKey]!.children.compactMap({ tree.model![$0]?.node }).filter({ $0.kind == .directory }).max(by: { ($0.allocatedBytes ?? 0) < ($1.allocatedBytes ?? 0) }) {
            for target in [largest, root] {
                browser.navigate(target); await browser.load(); tree.show(root: browser.directory ?? target, trail: browser.breadcrumbs)
                _ = await waitUntil { tree.model?.root.id == target.id }
            }
            explorerModel.show(root: browser.directory ?? root, trail: browser.breadcrumbs)
        }
        let model = tree.model!
        let proto = ProtoTree(model)
        let trail = browser.breadcrumbs.map { $0.parentID == nil ? "Startup Data" : $0.name }
        let depthMax = proto.nodes.map(\.depth).max() ?? 0
        report.say("model elements=\(model.count) folders expanded=\(model.expandedFolders.count) max depth=\(depthMax) trunk=\(ProtoFormat.bytes(model.trunkBytes)) truncated=\(model.truncated)")
        report.record("model", ["elements": model.count, "maxDepth": depthMax, "trunkBytes": model.trunkBytes ?? 0])

        // Targets: the largest top-level folder; a deep folder; a repeated name.
        let major = proto.root.children.filter { proto[$0].role == .branch }.max { proto[$0].weight < proto[$1].weight }!
        let deep = proto.nodes.indices.filter { proto[$0].isFolder && proto[$0].role == .branch && proto[$0].depth >= 5 && proto[$0].weight >= proto.root.weight * 0.0005 }
            .max { (proto[$0].depth, proto[$0].weight) < (proto[$1].depth, proto[$1].weight) } ?? major
        var byName = [String: [Int]]()
        for i in proto.nodes.indices where proto[i].isFolder && proto[i].role == .branch { byName[proto[i].name, default: []].append(i) }
        let repeated = byName.filter { $0.value.count > 1 }.max { $0.value.count < $1.value.count }
        report.say("targets major=\(proto[major].path) (\(ProtoFormat.bytes(proto[major].bytes))) deep=\(proto[deep].path) depth \(proto[deep].depth) (\(ProtoFormat.bytes(proto[deep].bytes)))")
        if let repeated { report.say("repeated name \"\(repeated.key)\" ×\(repeated.value.count): " + repeated.value.prefix(4).map { proto[$0].path }.joined(separator: " | ")) }
        let roles = Dictionary(grouping: proto.nodes, by: { $0.role }).mapValues(\.count)
        report.say("roles: " + roles.map { "\($0.key.rawValue)=\($0.value)" }.sorted().joined(separator: " "))

        // MARK: Screens (pages hosted offscreen; 1440×900 like a normal window)
        let page = CGSize(width: 1440, height: 900)
        func capture<V: View>(_ view: V, _ size: CGSize, dark: Bool, settle: (() -> Void)? = nil) -> CGImage? {
            let window = NSWindow(contentRect: CGRect(x: -20000, y: -20000, width: size.width, height: size.height), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height).background(Color(nsColor: .windowBackgroundColor)).environment(\.colorScheme, dark ? .dark : .light))
            window.contentView = host
            for _ in 0..<5 { host.layoutSubtreeIfNeeded(); RunLoop.main.run(until: Date().addingTimeInterval(0.04)) }
            if let settle { settle(); for _ in 0..<5 { host.layoutSubtreeIfNeeded(); RunLoop.main.run(until: Date().addingTimeInterval(0.04)) } }
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
            host.cacheDisplay(in: host.bounds, to: rep)
            window.contentView = nil
            return rep.cgImage
        }
        var board = [String: CGImage]()
        func save(_ name: String, _ image: CGImage?) { if let image { writePNG(image, to: shots.appendingPathComponent(name + ".png")); board[name] = image; report.say("screen \(name) \(image.width)x\(image.height)") } }

        let organic = ProtoExplorer(kind: .organic), structured = ProtoExplorer(kind: .structured)
        for explorer in [organic, structured] {
            explorer.load(model)
            let tag = explorer.kind == .organic ? "A-organic" : "B-structured"
            let view = ProtoExplorerView(explorer: explorer, trail: trail)
            for dark in [true, false] {
                let suffix = dark ? "dark" : "light"
                explorer.select(nil); explorer.reset()
                save("\(tag)-1-overview-\(suffix)", capture(view, page, dark: dark))
                save("\(tag)-2-large-selection-\(suffix)", capture(view, page, dark: dark) { explorer.reset(); explorer.select(major) })
                save("\(tag)-3-deep-selection-\(suffix)", capture(view, page, dark: dark) { explorer.reset(); explorer.select(deep); if explorer.kind == .organic { explorer.fit() } })
                save("\(tag)-4-zoomed-in-\(suffix)", capture(view, page, dark: dark) { explorer.reset(); explorer.select(major); explorer.zoom(by: 4, at: nil); if let s = explorer.scene, let r = s.focusRect(major) { explorer.camera.center = CGPoint(x: r.midX, y: r.midY) } })
                save("\(tag)-5-zoomed-out-\(suffix)", capture(view, page, dark: dark) { explorer.reset(); explorer.select(nil); explorer.zoom(by: 0.5, at: nil) })
                if explorer.kind == .structured { save("\(tag)-6-explored-\(suffix)", capture(view, page, dark: dark) { explorer.reset(); explorer.explore(major) }) }
                if let repeated, dark { save("\(tag)-7-repeated-name-\(suffix)", capture(view, page, dark: dark) { explorer.reset(); explorer.select(repeated.value[1]); explorer.fit() }) }
            }
            explorer.reset(); explorer.select(nil)
        }
        // The current Living Tree panel at the same canvas width as the prototypes' canvases.
        let currentSize = CGSize(width: 1140, height: 900)
        let currentPanel = LivingTreeView(browser: browser, explorer: explorerModel, tree: tree).environment(\.livingTreeInteractive, false)
        func selectCurrent(_ i: Int) { let key = proto[i].key; if let node = model[key]?.node { explorerModel.select(node, through: model.ancestry(of: key).dropFirst().dropLast().compactMap { model[$0]?.node }) } }
        for dark in [true, false] {
            let suffix = dark ? "dark" : "light"
            explorerModel.select(root, through: [])
            save("C-current-1-overview-\(suffix)", capture(currentPanel, currentSize, dark: dark) { tree.setCamera(.fit, animated: false) })
            save("C-current-2-large-selection-\(suffix)", capture(currentPanel, currentSize, dark: dark) { tree.setCamera(.fit, animated: false); selectCurrent(major) })
            save("C-current-3-deep-selection-\(suffix)", capture(currentPanel, currentSize, dark: dark) { selectCurrent(deep); tree.focus(on: proto[deep].key, animated: false) })
            save("C-current-4-zoomed-in-\(suffix)", capture(currentPanel, currentSize, dark: dark) { tree.setCamera(.fit, animated: false); selectCurrent(major); tree.focus(on: proto[major].key, animated: false) })
            save("C-current-5-zoomed-out-\(suffix)", capture(currentPanel, currentSize, dark: dark) { explorerModel.select(root, through: []); tree.setCamera(.fit, animated: false); tree.zoom(by: 0.5, at: nil, animated: false) })
        }
        explorerModel.select(root, through: []); tree.setCamera(.fit, animated: false)

        // MARK: Measurements — same canvas, same pipeline, same camera sequences
        let canvas = CGSize(width: 1140, height: 780)
        func raster<V: View>(_ v: V) -> Double { let (_, s) = timed { let r = ImageRenderer(content: v.frame(width: canvas.width, height: canvas.height)); r.scale = 2; _ = r.cgImage }; return s }
        let palette = ProtoPalette(dark: true)
        var results = [String: [String: Any]]()

        // Current Living Tree.
        do {
            var memory = LivingTreeMemory()
            let (arrangement, arrangeS) = timed { LivingTreeArranger.arrange(model, memory: &memory) }
            let (geometry, geomS) = timed { LivingTreeGeometer.layout(model, arrangement, in: canvas) }
            let (_, hitIndexS) = timed { _ = LivingTreeHitIndex(geometry) }
            tree.viewportChanged(canvas)
            tree.setCamera(.fit, animated: false)
            func frame() -> (Double, Double, Int) {
                let t0 = Date()
                guard let projected = tree.projected(for: canvas) else { return (0, 0, 0) }
                let labels = tree.labels(for: canvas, focus: nil, measure: LivingTreeLabelMetrics.measure)
                let model0 = Date().timeIntervalSince(t0)
                let view = ZStack {
                    LivingTreeBaseCanvas(revision: tree.revision, size: canvas, transform: projected.transform, zoom: tree.camera.zoom, geometry: projected.geometry, model: tree.model!)
                    LivingTreeLabelCanvas(labels: labels, tips: labels.map { projected.geometry[$0.key]?.end ?? projected.transform.apply($0.tip) }, size: canvas)
                }
                return (model0, model0 + raster(view), labels.count)
            }
            let first = frame()
            var pans = [(Double, Double, Int)](), zooms = [(Double, Double, Int)](), pans4 = [(Double, Double, Int)]()
            for i in 0..<40 { tree.pan(by: CGVector(dx: i % 20 < 10 ? 9 : -9, dy: 4)); pans.append(frame()) }
            tree.setCamera(.fit, animated: false)
            for i in 0..<40 { tree.zoom(by: i < 20 ? 1.08 : 1 / 1.08, at: CGPoint(x: canvas.width / 2, y: canvas.height / 2), animated: false); zooms.append(frame()) }
            tree.setCamera(.fit, animated: false); tree.zoom(by: 4, at: nil, animated: false)
            let labels4 = frame().2
            for i in 0..<40 { tree.pan(by: CGVector(dx: i % 20 < 10 ? 9 : -9, dy: 4)); pans4.append(frame()) }
            tree.setCamera(.fit, animated: false)
            guard let projected = tree.projected(for: canvas), let hits = tree.hitIndex() else { fatalError("no projection") }
            var hitTimes = [Double](), found = 0
            var rng = SystemRandomNumberGenerator()
            for _ in 0..<2000 {
                let p = CGPoint(x: Double.random(in: 0..<canvas.width, using: &rng), y: Double.random(in: 0..<canvas.height, using: &rng))
                let (h, s) = timed { hits.hit(p, transform: projected.transform) }
                hitTimes.append(s); if h != nil { found += 1 }
            }
            // Click accuracy, the same method as the prototypes: a point three quarters along each sampled branch, at the
            // fit and (zoomed 4× about that point) at 4×.
            let sampleBranches = Array(projected.geometry.branches.filter { $0.sizeKnown && $0.role != .trunk }.shuffled(using: &rng).prefix(600))
            // (The projected geometry is already in view coordinates.)
            let accuracyFit = sampleBranches.filter { hits.hit($0.point(at: 0.75), transform: projected.transform) == $0.key }.count
            var accuracy4 = 0
            for branch in sampleBranches {
                tree.setCamera(.fit, animated: false)
                tree.zoom(by: 4, at: branch.point(at: 0.75), animated: false)
                if let p4 = tree.projected(for: canvas), let h4 = tree.hitIndex(), let moved = p4.geometry[branch.key], h4.hit(moved.point(at: 0.75), transform: p4.transform) == branch.key { accuracy4 += 1 }
            }
            tree.setCamera(.fit, animated: false)
            report.say("CURRENT click accuracy fit \(accuracyFit)/\(sampleBranches.count) 4x \(accuracy4)/\(sampleBranches.count)")
            let geometryCount = geometry.branches.count
            results["current"] = ["layoutMs": (arrangeS + geomS + hitIndexS) * 1000, "arrangeMs": arrangeS * 1000, "geometryMs": geomS * 1000, "hitIndexMs": hitIndexS * 1000,
                                  "firstFrameMs": first.1 * 1000, "panP50": pct(pans.map(\.1), 0.5) * 1000, "panP95": pct(pans.map(\.1), 0.95) * 1000,
                                  "pan4xP50": pct(pans4.map(\.1), 0.5) * 1000, "pan4xP95": pct(pans4.map(\.1), 0.95) * 1000,
                                  "zoomP50": pct(zooms.map(\.1), 0.5) * 1000, "zoomP95": pct(zooms.map(\.1), 0.95) * 1000,
                                  "hitP50us": pct(hitTimes, 0.5) * 1e6, "hitP95us": pct(hitTimes, 0.95) * 1e6, "hitRate": Double(found) / 2000,
                                  "geometry": geometryCount, "labelsFit": first.2, "labels4x": labels4,
                                  "accuracyFit": accuracyFit, "accuracy4x": accuracy4, "accuracyTested": sampleBranches.count]
            _ = arrangement
            report.say("CURRENT layout=\(ms(arrangeS + geomS + hitIndexS))ms (arrange \(ms(arrangeS)) geometry \(ms(geomS)) hit index \(ms(hitIndexS))) branches=\(geometryCount) first frame=\(ms(first.1))ms labels fit=\(first.2) 4x=\(labels4)")
            report.say("CURRENT pan@1x p50=\(ms(pct(pans.map(\.1), 0.5))) p95=\(ms(pct(pans.map(\.1), 0.95))) | pan@4x p50=\(ms(pct(pans4.map(\.1), 0.5))) p95=\(ms(pct(pans4.map(\.1), 0.95))) | zoom p50=\(ms(pct(zooms.map(\.1), 0.5))) p95=\(ms(pct(zooms.map(\.1), 0.95))) ms; hit p50=\(String(format: "%.1f", pct(hitTimes, 0.5) * 1e6))µs p95=\(String(format: "%.1f", pct(hitTimes, 0.95) * 1e6))µs hits=\(found)/2000")
        }

        // Prototypes.
        for kind in ProtoExplorer.Kind.allCases {
            let name = kind == .organic ? "A" : "B"
            let before = footprint()
            var layoutTimes = [Double]()
            var scene: (any ProtoScene)!
            for _ in 0..<5 { let (s, t) = timed { kind == .organic ? OrganicTreeScene(tree: proto) as any ProtoScene : StructuredExplorerScene(tree: proto, focus: 0, depth: 3) }; scene = s; layoutTimes.append(t) }
            let (_, adapterS) = timed { _ = ProtoTree(model) }
            var camera = ProtoCamera(), state = ProtoViewState()
            func frame() -> (Double, Double, Int, Int) {
                let t0 = Date()
                let t = camera.transform(bounds: scene.bounds, size: canvas)
                let labels = scene.labels(t, size: canvas, state: state)
                let model0 = Date().timeIntervalSince(t0)
                var stats = ProtoDrawStats()
                let total = model0 + raster(Canvas { ctx, _ in stats = scene.draw(&ctx, t, size: canvas, state: state, labels: labels, palette: palette) })
                return (model0, total, labels.count, stats.primitives)
            }
            let first = frame()
            let after = footprint()
            var pans = [(Double, Double, Int, Int)](), zooms = [(Double, Double, Int, Int)](), pans4 = [(Double, Double, Int, Int)]()
            for i in 0..<40 { camera.pan(by: CGVector(dx: i % 20 < 10 ? 9 : -9, dy: 4), bounds: scene.bounds, size: canvas); pans.append(frame()) }
            camera = ProtoCamera()
            for i in 0..<40 { camera.zoom(by: i < 20 ? 1.08 : 1 / 1.08, at: CGPoint(x: canvas.width / 2, y: canvas.height / 2), bounds: scene.bounds, size: canvas); zooms.append(frame()) }
            camera = ProtoCamera(); camera.zoom(by: 4, at: nil, bounds: scene.bounds, size: canvas)
            let at4 = frame()
            for i in 0..<40 { camera.pan(by: CGVector(dx: i % 20 < 10 ? 9 : -9, dy: 4), bounds: scene.bounds, size: canvas); pans4.append(frame()) }
            camera = ProtoCamera()
            let t = camera.transform(bounds: scene.bounds, size: canvas), labels = scene.labels(t, size: canvas, state: state)
            var hitTimes = [Double](), found = 0
            var rng = SystemRandomNumberGenerator()
            for _ in 0..<2000 {
                let p = CGPoint(x: Double.random(in: 0..<canvas.width, using: &rng), y: Double.random(in: 0..<canvas.height, using: &rng))
                let (h, s) = timed { scene.hit(p, t, labels: labels) }
                hitTimes.append(s); if h != nil { found += 1 }
            }
            var selectionLatency = [Double]()
            for i in [major, deep] { state.selected = nil; let (_, s) = timed { state.selected = i; _ = frame() }; selectionLatency.append(s) }
            state.selected = nil
            let accuracy = selectionAccuracy(scene, canvas: canvas)
            results[name] = ["layoutMs": pct(layoutTimes, 0.5) * 1000, "adapterMs": adapterS * 1000, "laidOut": scene.laidOut, "firstFrameMs": (pct(layoutTimes, 0.5) + first.1) * 1000,
                             "panP50": pct(pans.map(\.1), 0.5) * 1000, "panP95": pct(pans.map(\.1), 0.95) * 1000, "pan4xP50": pct(pans4.map(\.1), 0.5) * 1000, "pan4xP95": pct(pans4.map(\.1), 0.95) * 1000,
                             "zoomP50": pct(zooms.map(\.1), 0.5) * 1000, "zoomP95": pct(zooms.map(\.1), 0.95) * 1000,
                             "hitP50us": pct(hitTimes, 0.5) * 1e6, "hitP95us": pct(hitTimes, 0.95) * 1e6, "hitRate": Double(found) / 2000,
                             "primitivesFit": first.3, "primitives4x": at4.3, "labelsFit": first.2, "labels4x": at4.2,
                             "selectionLatencyMs": selectionLatency.map { $0 * 1000 }, "memoryDeltaMB": Double(after - before) / 1_048_576,
                             "accuracyFit": accuracy.fit, "accuracy4x": accuracy.zoomed, "accuracyTested": accuracy.tested]
            report.say("\(name) \(kind.rawValue): layout p50=\(ms(pct(layoutTimes, 0.5)))ms (+adapter \(ms(adapterS))ms) laid out=\(scene.laidOut) first frame=\(ms(pct(layoutTimes, 0.5) + first.1))ms primitives fit=\(first.3) 4x=\(at4.3) labels fit=\(first.2) 4x=\(at4.2) memory Δ=\(String(format: "%.1f", Double(after - before) / 1_048_576))MB")
            report.say("\(name) pan@1x p50=\(ms(pct(pans.map(\.1), 0.5))) p95=\(ms(pct(pans.map(\.1), 0.95))) | pan@4x p50=\(ms(pct(pans4.map(\.1), 0.5))) p95=\(ms(pct(pans4.map(\.1), 0.95))) | zoom p50=\(ms(pct(zooms.map(\.1), 0.5))) p95=\(ms(pct(zooms.map(\.1), 0.95))) ms; hit p50=\(String(format: "%.1f", pct(hitTimes, 0.5) * 1e6))µs p95=\(String(format: "%.1f", pct(hitTimes, 0.95) * 1e6))µs hits=\(found)/2000; select+frame \(selectionLatency.map { ms($0) }.joined(separator: "/"))ms; click accuracy fit \(accuracy.fit)/\(accuracy.tested) 4x \(accuracy.zoomed)/\(accuracy.tested)")
        }

        // MARK: Large hierarchies — the same builder with larger element budgets
        var scaling = [[String: Any]]()
        for elements in [3_000, 10_000, 20_000] {
            let controller = LivingTreeController(database: database, budget: LivingTreeBudget(elements: elements))
            controller.show(root: root, trail: [root])
            guard await waitUntil(seconds: 120, { controller.model != nil }) else { report.say("scale \(elements): model did not build"); continue }
            let big = controller.model!
            var memory = LivingTreeMemory()
            let (arrangement, arrangeS) = timed { LivingTreeArranger.arrange(big, memory: &memory) }
            let (geometry, geomS) = timed { LivingTreeGeometer.layout(big, arrangement, in: canvas) }
            let (_, hitS) = timed { _ = LivingTreeHitIndex(geometry) }
            let bigTree = ProtoTree(big)
            let (a, aS) = timed { OrganicTreeScene(tree: bigTree) }
            let (b, bS) = timed { StructuredExplorerScene(tree: bigTree, focus: 0, depth: 3) }
            func protoFrame(_ s: any ProtoScene) -> Double {
                let t = ProtoCamera().transform(bounds: s.bounds, size: canvas)
                let (labels, ls) = timed { s.labels(t, size: canvas, state: ProtoViewState()) }
                return ls + raster(Canvas { ctx, _ in _ = s.draw(&ctx, t, size: canvas, state: ProtoViewState(), labels: labels, palette: palette) })
            }
            let aFrame = protoFrame(a), bFrame = protoFrame(b)
            scaling.append(["budget": elements, "elements": big.count, "truncated": big.truncated, "currentLayoutMs": (arrangeS + geomS + hitS) * 1000, "aLayoutMs": aS * 1000, "bLayoutMs": bS * 1000,
                            "aFrameMs": aFrame * 1000, "bFrameMs": bFrame * 1000, "aLaidOut": a.laidOut, "bLaidOut": b.laidOut])
            report.say("scale budget=\(elements) elements=\(big.count) truncated=\(big.truncated): current layout \(ms(arrangeS + geomS + hitS))ms | A layout \(ms(aS))ms frame \(ms(aFrame))ms | B layout \(ms(bS))ms frame \(ms(bFrame))ms (B shows \(b.laidOut) at depth 3)")
        }
        report.record("results", results); report.record("scaling", scaling)
        report.record("footprintMB", Double(footprint()) / 1_048_576)
        report.say("process footprint at end: \(String(format: "%.0f", Double(footprint()) / 1_048_576)) MB")

        // MARK: Comparison board
        makeBoard(board, to: out.appendingPathComponent("comparison-board.png"), closeups: out.appendingPathComponent("comparison-closeups.png"))
        if let data = try? JSONSerialization.data(withJSONObject: report.json, options: [.prettyPrinted, .sortedKeys]) { try? data.write(to: out.appendingPathComponent("measurements.json")) }
        try? report.lines.joined(separator: "\n").write(to: out.appendingPathComponent("measurements.log"), atomically: true, encoding: .utf8)
        exit(0)
    }

    /// Clicks laid-out elements at their own anchors (a point three quarters along a limb; a leaf's or disc's centre)
    /// at the fit, and centred at 4×, and counts how many hits return that element.
    @MainActor static func selectionAccuracy(_ scene: any ProtoScene, canvas: CGSize) -> (fit: Int, zoomed: Int, tested: Int) {
        var anchors = [(Int, CGPoint)]()
        if let a = scene as? OrganicTreeScene {
            for limb in a.limbs where !limb.unmeasured { anchors.append((limb.node, limb.samples[limb.samples.count * 3 / 4])) }
            for leaf in a.leaves where leaf.kind == .file { anchors.append((leaf.node, leaf.center)) }
        } else if let b = scene as? StructuredExplorerScene {
            for p in b.placed { anchors.append((p.node, p.point)) }
        }
        var rng = SystemRandomNumberGenerator()
        let sample = anchors.count > 600 ? Array(anchors.shuffled(using: &rng).prefix(600)) : anchors
        let fit = ProtoCamera().transform(bounds: scene.bounds, size: canvas)
        let atFit = sample.filter { node, point in scene.hit(fit.apply(point), fit, labels: []) == node }.count
        var zoomed = ProtoCamera()
        zoomed.zoom(by: 4, at: nil, bounds: scene.bounds, size: canvas)
        let at4 = sample.filter { node, point in
            var c = zoomed; c.center = point
            let t = c.transform(bounds: scene.bounds, size: canvas)
            return scene.hit(t.apply(point), t, labels: []) == node
        }.count
        return (atFit, at4, sample.count)
    }

    /// One board: three columns (current, A, B) × three rows (overview, large selection, deep selection), each cell a
    /// downscaled full capture; and a close-up board of the large-selection captures at full resolution.
    @MainActor static func makeBoard(_ shots: [String: CGImage], to url: URL, closeups: URL) {
        let columns = [("Current Living Tree", "C-current"), ("A · Organic Storage Tree", "A-organic"), ("B · Structured Explorer", "B-structured")]
        let rows = [("Overview", "1-overview"), ("Large folder selected", "2-large-selection"), ("Deep folder selected", "3-deep-selection")]
        let cellW: CGFloat = 900, cellH: CGFloat = 563, gap: CGFloat = 24, header: CGFloat = 90, rowLabel: CGFloat = 46
        let width = gap + CGFloat(columns.count) * (cellW + gap), height = header + CGFloat(rows.count) * (cellH + rowLabel + gap)
        guard let ctx = CGContext(data: nil, width: Int(width), height: Int(height), bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        ctx.setFillColor(CGColor(gray: 0.08, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        func text(_ s: String, _ x: CGFloat, _ yTop: CGFloat, size: CGFloat, weight: NSFont.Weight = .semibold, alpha: CGFloat = 1) {
            (s as NSString).draw(at: CGPoint(x: x, y: height - yTop - size * 1.25), withAttributes: [.font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: NSColor(white: 1, alpha: alpha)])
        }
        text("Living Tree — current vs. two prototypes (same catalog model, dark appearance)", gap, 22, size: 30)
        for (c, column) in columns.enumerated() {
            let x = gap + CGFloat(c) * (cellW + gap)
            for (r, row) in rows.enumerated() {
                let yTop = header + CGFloat(r) * (cellH + rowLabel + gap)
                text("\(column.0) — \(row.0)", x, yTop + 8, size: 20, weight: .medium, alpha: 0.85)
                guard let image = shots["\(column.1)-\(row.1)-dark"] else { continue }
                let aspect = CGFloat(image.width) / CGFloat(image.height)
                let w = min(cellW, cellH * aspect), h = w / aspect
                ctx.draw(image, in: CGRect(x: x, y: height - (yTop + rowLabel) - h, width: w, height: h))
            }
        }
        NSGraphicsContext.restoreGraphicsState()
        if let image = ctx.makeImage() { writePNG(image, to: url) }

        // Close-ups: the central 1100×760 px of each large-selection capture at full resolution, side by side.
        let crop = CGSize(width: 1100, height: 760)
        guard let cc = CGContext(data: nil, width: Int(gap + 3 * (crop.width + gap)), height: Int(crop.height + 2 * gap + 50), bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        cc.setFillColor(CGColor(gray: 0.08, alpha: 1)); cc.fill(CGRect(x: 0, y: 0, width: cc.width, height: cc.height))
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(cgContext: cc, flipped: false)
        for (c, column) in columns.enumerated() {
            let x = gap + CGFloat(c) * (crop.width + gap)
            ("\(column.0) — close-up, large folder selected" as NSString).draw(at: CGPoint(x: x, y: CGFloat(cc.height) - 44), withAttributes: [.font: NSFont.systemFont(ofSize: 22, weight: .semibold), .foregroundColor: NSColor.white])
            guard let image = shots["\(column.1)-2-large-selection-dark"] else { continue }
            let canvasWidth = c == 0 ? CGFloat(image.width) : CGFloat(image.width) - 600   // prototypes: leave out the 300 pt inspector
            let rect = CGRect(x: max(0, (canvasWidth - crop.width) / 2), y: max(0, (CGFloat(image.height) - crop.height) / 2), width: crop.width, height: crop.height)
            if let part = image.cropping(to: rect) { cc.draw(part, in: CGRect(x: x, y: gap, width: crop.width, height: crop.height)) }
        }
        NSGraphicsContext.restoreGraphicsState()
        if let image = cc.makeImage() { writePNG(image, to: closeups) }
    }
}
