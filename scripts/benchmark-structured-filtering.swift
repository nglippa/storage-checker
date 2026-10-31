import SwiftUI
import AppKit
import SQLite3
import ImageIO
import UniformTypeIdentifiers

// All pointer/menu calls stay inside this process. No events posted, no AX actions, cursor operations,
// ordered windows, app activation, or preference writes. PNGs are offscreen implementation evidence.
@MainActor private func until(_ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(40)
    while !condition() {
        if Date() > deadline { return false }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return true
}

private func milliseconds<T>(_ action: () -> T) -> (T, Double) {
    let start = DispatchTime.now().uptimeNanoseconds
    let result = action()
    return (result, Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6)
}

private func memoryMiB() -> Double {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let status = withUnsafeMutablePointer(to: &info) { ptr in
        ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    return status == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : -1
}

/// Clearly labelled synthetic QA fixture: 14-way hierarchy, repeated names, and a 40-level selection chain.
private struct DenseFixture {
    let model: LivingTreeModel
    let deepest: LivingTreeKey
    init() {
        var parents = [Int64: Int64](), names = [Int64: String](), children = [Int64: [Int64]](), own = [Int64: Int64]()
        var next: Int64 = 1
        func add(_ parent: Int64?, _ name: String, _ bytes: Int64) -> Int64 {
            let id = next; next += 1
            names[id] = name; own[id] = bytes
            if let parent { parents[id] = parent; children[parent, default: []].append(id) }
            return id
        }
        let root = add(nil, "Dense QA fixture", 0)
        for i in 0..<14 {
            let branch = add(root, "Branch \(i)", 0)
            for j in 0..<14 {
                let folder = add(branch, "cache", 0)
                for k in 0..<14 { _ = add(folder, "Folder \(k)", Int64((i + j + k) % 20 + 1) * 100_000_000) }
            }
        }
        var deep: Int64 = 4
        for level in 0..<40 { deep = add(deep, "Level \(level)", 1_000_000) }
        func path(_ id: Int64) -> String { (parents[id].map(path) ?? "/QA") + "/" + names[id]! }
        var totals = [Int64: Int64]()
        func total(_ id: Int64) -> Int64 {
            if let value = totals[id] { return value }
            let value = (children[id] ?? []).reduce(own[id]!) { $0 + total($1) }; totals[id] = value; return value
        }
        var nodes = [Int64: InventoryNode]()
        for id in 1..<next {
            let bytes = total(id)
            nodes[id] = InventoryNode(id: id, parentID: parents[id], identity: .init(device: 1, inode: UInt64(id), birthNanoseconds: 1),
                path: path(id), name: names[id]!, kind: .directory, logicalBytes: bytes, allocatedBytes: bytes,
                previousLogicalBytes: nil, previousAllocatedBytes: nil, objectLogicalBytes: nil, objectAllocatedBytes: nil,
                directLogicalBytes: own[id]!, directAllocatedBytes: own[id]!, childCount: Int64(children[id]?.count ?? 0),
                descendantFiles: 0, descendantDirectories: 0, status: .complete, coverageState: "complete", listingState: nil,
                statusReason: nil, measuredAt: nil, modifiedAt: nil, generation: 1, isHardlinkAlias: false, historicalGrowthBytes: nil)
        }
        model = LivingTreeBuilder.build(root: nodes[root]!, budget: .init(elements: 6000, perFolder: 20, slack: 0, maxDepth: 80, minimumShare: 0)) { parent, _ in
            (InventoryChildPage(items: (children[parent] ?? []).map { nodes[$0]! }, next: nil), nil)
        }
        deepest = .node(deep)
    }
}

@main private struct FilteringBenchmark {
    @MainActor static func main() async {
        setvbuf(stdout, nil, _IOLBF, 0)
        _ = NSApplication.shared
        NSApplication.shared.setActivationPolicy(.prohibited)
        guard CommandLine.arguments.count == 3 else { exit(2) }
        let database = CommandLine.arguments[1], out = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
        let renders = out.appendingPathComponent("headless-renders", isDirectory: true)
        try! FileManager.default.createDirectory(at: renders, withIntermediateDirectories: true)
        var preferences: [String: Any] = ["inventory.explorer.visualization": "tree", "inventory.explorer.mapHeight": 560.0,
            "inventory.explorer.inspector": true, "inventory.explorer.showMap": true, "inventory.explorer.treeNavigatorExpanded": true,
            "inventory.livingTree.renderer": "structured", "inventory.structuredExplorer.depth": 3]
        func prefer(_ key: String, _ value: Any) {
            preferences[key] = value
            UserDefaults.standard.setVolatileDomain(preferences, forName: UserDefaults.argumentDomain)
            ViewerStore.viewPreferences.setVolatileDomain(preferences, forName: UserDefaults.argumentDomain)
        }
        prefer("inventory.livingTree.renderer", "structured")
        var failures = [String](), checks = 0
        func require(_ passed: Bool, _ message: String) {
            checks += 1; print("\(passed ? "PASS" : "FAIL") \(message)")
            if !passed { failures.append(message) }
        }
        var db: OpaquePointer?, catalogCount: Int64 = -1
        if sqlite3_open(database, &db) == SQLITE_OK {
            // Settled-size comparison on this disposable clone only, as in the existing explorer benchmark.
            sqlite3_exec(db, "DELETE FROM inventory_reconcile; DELETE FROM inventory_prune_jobs;", nil, nil, nil)
            var statement: OpaquePointer?
            if sqlite3_prepare_v2(db, "SELECT count(*) FROM inventory_nodes", -1, &statement, nil) == SQLITE_OK, sqlite3_step(statement) == SQLITE_ROW {
                catalogCount = sqlite3_column_int64(statement, 0)
            }
            sqlite3_finalize(statement); sqlite3_close(db)
        }
        let browser = InventoryBrowserModel(database: database, readiness: ViewerReadiness(output: nil))
        await browser.load()
        guard let root = browser.directory else { fputs("No catalog root\n", stderr); exit(1) }
        let tree = browser.livingTree, state = browser.structuredExplorer, explorer = browser.explorer
        explorer.show(root: root, trail: browser.breadcrumbs); tree.show(root: root, trail: browser.breadcrumbs)
        guard await until({ tree.model != nil }) else { fputs("Tree load timeout\n", stderr); exit(1) }
        let model = tree.model!, revision = tree.revision
        let layout = state.layout(model, revision: revision, depth: 3, selection: nil)
        let folders = layout.nodes.dropFirst().map(\.key).filter { model[$0]?.isFolder == true && $0.nodeID != nil }
        guard let target = folders.first(where: { (model[$0]?.bytes ?? 0) > 1_000_000_000 }) ?? folders.first else { exit(1) }
        let tiny = folders.last(where: { (model[$0]?.bytes ?? Int64.max) < 1_000_000_000 }) ?? target
        print("REAL CATALOG nodes=\(catalogCount), bounded model=\(model.count), placed=\(layout.nodes.count), target=\(model[target]!.node!.path)")

        func select(_ key: LivingTreeKey) {
            if let node = model[key]?.node {
                explorer.select(node, through: model.ancestry(of: key).dropFirst().dropLast().compactMap { model[$0]?.node })
            }
        }
        func save(_ image: CGImage?, _ name: String) {
            guard let image, let destination = CGImageDestinationCreateWithURL(renders.appendingPathComponent(name + ".png") as CFURL, UTType.png.identifier as CFString, 1, nil) else {
                require(false, "render \(name)"); return
            }
            CGImageDestinationAddImage(destination, image, nil)
            require(CGImageDestinationFinalize(destination), "offscreen PNG \(name) (\(image.width)×\(image.height))")
        }
        func screenshot(_ name: String, size: CGSize = .init(width: 1440, height: 900), dark: Bool = true, after: (() -> Void)? = nil) async {
            let window = NSWindow(contentRect: CGRect(x: -20000, y: -20000, width: size.width, height: size.height), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            let host = NSHostingView(rootView: InventoryExplorerView(browser: browser).frame(width: size.width, height: size.height))
            window.contentView = host
            for _ in 0..<6 { host.layoutSubtreeIfNeeded(); try? await Task.sleep(for: .milliseconds(40)) }
            after?()
            for _ in 0..<10 { host.layoutSubtreeIfNeeded(); try? await Task.sleep(for: .milliseconds(40)) }
            if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.cacheDisplay(in: host.bounds, to: rep); save(rep.cgImage, name)
            } else { require(false, "host bitmap \(name)") }
            window.contentView = nil
            // A separate real explorer-panel render avoids the offscreen AppKit List bitmap limitations in
            // full-page evidence. These are rendered views, not crops, mockups, or native desktop screenshots.
            let panel = CGSize(width: size.width > 1000 ? 1100 : 650, height: size.width > 1000 ? 720 : 430)
            let panelWindow = NSWindow(contentRect: CGRect(x: -20000, y: -20000, width: panel.width, height: panel.height), styleMask: [.borderless], backing: .buffered, defer: false)
            panelWindow.isReleasedWhenClosed = false
            panelWindow.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            let panelView: AnyView
            if preferences["inventory.livingTree.renderer"] as? String == "classic" {
                panelView = AnyView(LivingTreeView(browser: browser, explorer: explorer, tree: tree))
            } else { panelView = AnyView(StructuredExplorerView(browser: browser, explorer: explorer, tree: tree)) }
            let panelHost = NSHostingView(rootView: panelView.frame(width: panel.width, height: panel.height))
            panelWindow.contentView = panelHost
            for _ in 0..<8 { panelHost.layoutSubtreeIfNeeded(); try? await Task.sleep(for: .milliseconds(40)) }
            if let rep = panelHost.bitmapImageRepForCachingDisplay(in: panelHost.bounds) {
                panelHost.cacheDisplay(in: panelHost.bounds, to: rep); save(rep.cgImage, "explorer-" + name)
            } else { require(false, "explorer panel bitmap \(name)") }
            panelWindow.contentView = nil
        }

        // One full-page comparison per requested state, using the preserved real catalog clone.
        explorer.select(root, through: [])
        await screenshot("01-all-nodes")
        state.filter.minimumBytes = 500_000_000
        await screenshot("02-at-least-500-MB-dim")
        state.filter.minimumBytes = 1_000_000_000
        await screenshot("03-at-least-1-GB-dim")
        state.filter.presentation = .hide
        await screenshot("04-at-least-1-GB-hide")
        select(tiny)
        await screenshot("05-selected-below-filter")
        _ = state.resetFilters(); select(target)
        _ = state.isolate(target, model: model, selection: root.id)
        await screenshot("06-isolated-folder")
        _ = state.exitIsolation(); select(tiny); state.filter.focus = .path
        await screenshot("07-path-to-root")
        select(target); state.filter.focus = .subtree
        await screenshot("08-focus-subtree")
        await screenshot("09-minimum-window-dark", size: .init(width: 1000, height: 640))
        await screenshot("10-minimum-window-light", size: .init(width: 1000, height: 640), dark: false)
        state.filter = .init(minimumBytes: 500_000_000, presentation: .hide)
        await screenshot("11-minimum-window-hide-light", size: .init(width: 1000, height: 640), dark: false)
        prefer("inventory.livingTree.renderer", "classic")
        await screenshot("12-classic-fallback")
        prefer("inventory.livingTree.renderer", "structured")
        _ = state.resetFilters(); explorer.select(root, through: [])

        // Production canvas input/menu closures, with no desktop input or displayed menus.
        let size = CGSize(width: 1440, height: 900)
        let window = NSWindow(contentRect: CGRect(x: -20000, y: -20000, width: size.width, height: size.height), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: InventoryExplorerView(browser: browser).frame(width: size.width, height: size.height))
        window.contentView = host
        func pump() async { for _ in 0..<10 { host.layoutSubtreeIfNeeded(); try? await Task.sleep(for: .milliseconds(30)) } }
        func findInput(_ view: NSView) -> LivingTreeInputView? {
            if let input = view as? LivingTreeInputView { return input }
            return view.subviews.lazy.compactMap(findInput).first
        }
        await pump()
        if let input = findInput(host) {
            func point(_ key: LivingTreeKey) -> CGPoint? { state.drawn.flatMap { drawn in drawn.layout[key].map { drawn.transform.apply($0.point) } } }
            func invoke(_ title: String, at key: LivingTreeKey) -> Bool {
                guard let p = point(key), let menu = input.contextMenu?(p), let item = menu.items.first(where: { $0.title == title }),
                      item.isEnabled, let callback = item.representedObject as? StructuredExplorerMenuAction else { return false }
                callback.invoke(item); return true
            }
            if let p = point(target) {
                input.handle?(.down(p, clicks: 1, [])); input.handle?(.up(p, clicks: 1)); await pump()
                require(explorer.selection == target.nodeID && explorer.state.node(target.nodeID!)?.path == model[target]?.node?.path,
                        "filtered canvas click shares exact selection/path with Inspector and Navigator")
                state.filter = .init(minimumBytes: Int64.max, presentation: .hide); await pump()
                require(state.drawn?.layout[target] != nil && explorer.selection == target.nodeID,
                        "raising threshold retains selected node in real rendered hierarchy")
                let stats = tree.statistics, builds = state.layouts
                state.filter.minimumBytes = 500_000_000; state.filter.presentation = .dim; state.filter.focus = .subtree; await pump()
                require(state.layouts == builds && tree.statistics.builds == stats.builds && tree.statistics.polls == stats.polls,
                        "hosted threshold, Dim and Focus changes cause no tree catalog rebuild/read poll or radial rebuild")
                require(invoke("Show Path to Root", at: target), "production context menu path action invokes in process")
                await pump(); require(state.filter.focus == .path, "context menu highlights real ancestor path")
                require(invoke("Isolate This Path", at: target), "production context menu isolation action invokes in process")
                await pump()
                require(state.isolatedRoot == target && state.drawn?.layout.rootKey == target
                        && explorer.state.node(target.nodeID!)?.allocatedBytes == model[target]?.node?.allocatedBytes,
                        "isolated root keeps exact identity, true size and Inspector subject")
                let nested = state.drawn?.layout.nodes.dropFirst().first { model[$0.key]?.isFolder == true && $0.key.nodeID != nil }?.key
                if let nested, let p = point(nested) {
                    input.handle?(.down(p, clicks: 2, [])); input.handle?(.up(p, clicks: 2)); await pump()
                    require(state.isolatedRoot == nested && state.isolationSelection == target.nodeID && browser.directory?.id == root.id,
                            "double-click in isolation nests the visual root without browser navigation")
                } else { require(false, "nested isolation fixture target is available") }
                require(invoke("Clear Focus / Isolation", at: state.isolatedRoot ?? target), "clear isolation context action invokes")
                let initialRestorationRouted = explorer.scrollRequest == target.nodeID
                await pump()
                require(state.isolatedRoot == nil && state.filter.focus == .off && explorer.selection == target.nodeID
                        && explorer.rows.contains(where: { $0.id == target.nodeID }) && initialRestorationRouted,
                        "clear isolation restores original shared selection and Navigator context")
                if let entry = folders.first(where: { (model[$0]?.depth ?? 0) >= (model[model.rootKey]?.depth ?? 0) + 3 }) {
                    select(entry); await pump()
                    require(invoke("Isolate This Path", at: target), "isolate another folder while a deep entry is selected")
                    await pump()
                    require(invoke("Clear Focus / Isolation", at: target), "exit isolation after the entry chain collapsed")
                    let deepRestorationRouted = explorer.scrollRequest == entry.nodeID
                    await pump()
                    let chain = model.ancestry(of: entry).dropFirst().dropLast()
                    require(explorer.selection == entry.nodeID && deepRestorationRouted
                            && chain.allSatisfy { explorer.state.isExpanded($0.nodeID!) }
                            && explorer.rows.contains(where: { $0.id == entry.nodeID }),
                            "exit restores deep entry selection, actual ancestor expansions, visible Navigator row and scroll routing")
                } else { require(false, "deep restoration fixture target is available (required coverage)") }
                select(tiny); await pump()
                require(explorer.selection == tiny.nodeID && explorer.state.node(tiny.nodeID!)?.path == model[tiny]?.node?.path,
                        "selection after filtering keeps true Inspector path")
                _ = state.isolate(target, model: model, selection: tiny.nodeID); select(target); await pump()
                browser.navigate(model[target]!.node!); await browser.load(); await pump()
                require(await until({ tree.model?.root.id == target.nodeID }), "ordinary browser navigation remains available during filtering")
                await pump()
                require(state.isolatedRoot == nil && state.filter.minimumBytes == 500_000_000,
                        "browser root change clears stale isolation while preserving size setting")
            } else { require(false, "production input target placed") }
        } else { require(false, "production input view hosted") }
        window.contentView = nil

        // Measurements separate computation + label placement + offscreen canvas raster from native display latency.
        var metrics = [String: Any]()
        let dense = DenseFixture()
        func measure(_ name: String, _ current: LivingTreeModel, selected: LivingTreeKey?, levels: Int, canvas: CGSize) {
            let state = StructuredExplorerState(), palette = StructuredExplorerPalette(dark: true)
            let statsBefore = tree.statistics
            let originalSizes = current.order.map { current[$0]?.bytes }
            var samples = [String: [Double]](), memory = [Double]()
            func frame() -> StructuredExplorerLayout {
                let l = state.layout(current, revision: 1, depth: levels, selection: selected)
                let v = state.visibility(l, model: current, selection: selected)
                let t = state.camera.transform(bounds: l.bounds, size: canvas)
                let labels = state.labels(l, model: current, transform: t, size: canvas, selected: selected, hovered: nil, visibility: v)
                let renderer = ImageRenderer(content: Canvas { ctx, _ in
                    StructuredExplorerPainter(layout: l, model: current, coloring: .empty, palette: palette)
                        .paint(&ctx, transform: t, size: canvas, selected: selected, exact: true, hovered: nil, labels: labels, visibility: v)
                }.frame(width: canvas.width, height: canvas.height))
                renderer.scale = 2; _ = renderer.cgImage
                return l
            }
            let baseline = frame(), radialBuilds = state.layouts
            for i in 0..<24 {
                for action in ["threshold", "presentation", "focus", "isolate", "exit", "reset", "selection"] {
                    let (_, elapsed) = milliseconds {
                        autoreleasepool {
                            switch action {
                            case "threshold": state.filter.minimumBytes = i.isMultiple(of: 2) ? 500_000_000 : 1_000_000_000
                            case "presentation": state.filter.presentation = i.isMultiple(of: 2) ? .hide : .dim
                            case "focus": state.filter.focus = i.isMultiple(of: 2) ? .subtree : .path
                            case "isolate":
                                if let key = baseline.nodes.dropFirst().first(where: { current[$0.key]?.isFolder == true && $0.key.nodeID != nil })?.key {
                                    _ = state.isolate(key, model: current, selection: selected?.nodeID)
                                }
                            case "exit": _ = state.exitIsolation()
                            case "reset": _ = state.resetFilters()
                            default: break
                            }
                            if action == "selection" {
                                state.filter = .init(minimumBytes: 1_000_000_000, presentation: .hide)
                                let key = baseline.nodes.dropFirst().last(where: { $0.key.nodeID != nil })?.key
                                let l = state.layout(current, revision: 1, depth: levels, selection: key)
                                _ = state.visibility(l, model: current, selection: key)
                                // Complete frame for the changed selection through a separate state-key evaluation.
                                let t = state.camera.transform(bounds: l.bounds, size: canvas)
                                let v = state.visibility(l, model: current, selection: key)
                                let labels = state.labels(l, model: current, transform: t, size: canvas, selected: key, hovered: nil, visibility: v)
                                let renderer = ImageRenderer(content: Canvas { ctx, _ in
                                    StructuredExplorerPainter(layout: l, model: current, coloring: .empty, palette: palette)
                                        .paint(&ctx, transform: t, size: canvas, selected: key, exact: true, hovered: nil, labels: labels, visibility: v)
                                }.frame(width: canvas.width, height: canvas.height))
                                renderer.scale = 2; _ = renderer.cgImage
                            } else { _ = frame() }
                        }
                    }
                    samples[action, default: []].append(elapsed)
                }
                if [0, 5, 11, 17, 23].contains(i) { memory.append(memoryMiB()) }
            }
            var results = [String: Any]()
            for (action, times) in samples.sorted(by: { $0.key < $1.key }) {
                let sorted = times.sorted(), p50 = sorted[sorted.count / 2], p95 = sorted[Int((Double(sorted.count - 1) * 0.95).rounded())]
                results[action] = ["samplesMs": times, "p50Ms": p50, "p95Ms": p95, "maxMs": sorted.last!]
                print("MEASURE \(name) \(action) p50=\(String(format: "%.2f", p50)) p95=\(String(format: "%.2f", p95)) max=\(String(format: "%.2f", sorted.last!)) ms")
            }
            results["elements"] = current.count; results["placed"] = baseline.nodes.count
            results["viewport"] = "\(Int(canvas.width))×\(Int(canvas.height))@2x"
            results["footprintMiB"] = memory; results["initialRadialBuilds"] = radialBuilds
            metrics[name] = results
            require(current.order.map { current[$0]?.bytes } == originalSizes && tree.statistics == statsBefore,
                    "\(name): repeated filtering leaves all original totals and catalog controller statistics unchanged")
            print("MEMORY \(name) MiB samples=\(memory)")
        }
        measure("real-standard", model, selected: target, levels: 3, canvas: .init(width: 1100, height: 560))
        measure("real-minimum", model, selected: tiny, levels: 3, canvas: .init(width: 600, height: 300))
        measure("dense-QA", dense.model, selected: .node(2), levels: 6, canvas: .init(width: 1100, height: 560))
        measure("deep-QA", dense.model, selected: dense.deepest, levels: 2, canvas: .init(width: 600, height: 300))
        // Deep isolation/full-chain identity invariant is also checked on the dense fixture.
        let deepState = StructuredExplorerState(); deepState.filter.minimumBytes = Int64.max
        let full = deepState.layout(dense.model, revision: 1, depth: 1, selection: dense.deepest)
        require(dense.model.ancestry(of: dense.deepest).allSatisfy { full[$0] != nil }
                && full.nodes.allSatisfy { n in n.parent < 0 || dense.model[n.key]?.parent == full.nodes[n.parent].key },
                "40-level selected exception keeps every true direct parent with stable IDs")
        let json: [String: Any] = ["catalogNodes": catalogCount, "checks": checks, "failures": failures, "measurements": metrics,
            "scope": "Warm in-process derived state + label layout + 2x offscreen canvas raster; not display pacing, physical input, native accessibility, or release acceptance. Memory is process physical footprint sampled after render cycles, not a leak proof."]
        try! JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]).write(to: out.appendingPathComponent("measurements.json"))
        print("RESULT \(checks - failures.count)/\(checks) checks; native physical input/VoiceOver NOT VERIFIED")
        exit(failures.isEmpty ? 0 : 1)
    }
}
