import SwiftUI
import AppKit
import ImageIO
import UniformTypeIdentifiers
import SQLite3

// Offscreen renders of the Living Tree for visual review, and render timing. Run through
// scripts/benchmark-living-tree.sh on a prepared APFS clone under /private/tmp. Nothing is shown on screen: the
// process may not activate (activation policy .prohibited), the tree panel is drawn by ImageRenderer, and the full
// page is drawn by an NSHostingView in a borderless window that is never ordered in. Size signals are produced by
// committing worker-shaped size changes to the clone, then read through the real controller.

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

@main struct LivingTreeRenderHarness {
    @MainActor static func main() async {
        _ = NSApplication.shared
        NSApplication.shared.setActivationPolicy(.prohibited)
        let arguments = CommandLine.arguments
        guard arguments.count == 3 else { fputs("usage: render <prepared catalog clone> <output folder>\n", stderr); exit(2) }
        let database = arguments[1], output = URL(fileURLWithPath: arguments[2], isDirectory: true)
        try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        // Registered (in-memory) defaults only: nothing is written to any preferences file.
        UserDefaults.standard.register(defaults: ["inventory.explorer.visualization": "tree", "inventory.explorer.mapHeight": 560.0, "inventory.explorer.inspector": true])

        let panel = CGSize(width: 1400, height: 860)
        // 0. The catalog as preserved: a reconciliation rooted at the volume was pending, so every size beneath it is
        //    an earlier size (drawn quieter). Then the pending work is cleared on the clone, as a finished
        //    reconciliation would, and every later render shows the settled state.
        do {
            let preserved = InventoryBrowserModel(database: database, readiness: ViewerReadiness(output: nil))
            await preserved.load()
            if let root = preserved.directory {
                preserved.explorer.show(root: root, trail: preserved.breadcrumbs)
                preserved.livingTree.show(root: root, trail: preserved.breadcrumbs)
                if await waitUntil({ preserved.livingTree.model != nil }) {
                    let renderer = ImageRenderer(content: LivingTreeView(browser: preserved, explorer: preserved.explorer, tree: preserved.livingTree).frame(width: panel.width, height: panel.height).environment(\.colorScheme, .dark).environment(\.livingTreeInteractive, false))
                    renderer.scale = 2
                    if let image = renderer.cgImage { writePNG(image, to: output.appendingPathComponent("living-tree-volume-earlier-sizes.png")); print("render living-tree-volume-earlier-sizes (as preserved)") }
                }
            }
            var db: OpaquePointer?
            if sqlite3_open(database, &db) == SQLITE_OK {
                sqlite3_busy_timeout(db, 30_000)
                sqlite3_exec(db, "DELETE FROM inventory_reconcile; DELETE FROM inventory_prune_jobs;", nil, nil, nil)
                sqlite3_close(db)
            }
        }

        let browser = InventoryBrowserModel(database: database, readiness: ViewerReadiness(output: nil))
        await browser.load()
        guard let root = browser.directory else { fputs("no inventory root\n", stderr); exit(1) }
        let explorer = browser.explorer, tree = browser.livingTree
        explorer.show(root: root, trail: browser.breadcrumbs)
        tree.show(root: root, trail: browser.breadcrumbs)
        guard await waitUntil({ tree.model != nil && explorer.state.children[root.id] != nil }) else { fputs("tree did not build\n", stderr); exit(1) }
        print("tree elements=\(tree.model!.count) reads=\(tree.statistics.lastReads) build=\(String(format: "%.1f", tree.statistics.lastBuildSeconds * 1000))ms truncated=\(tree.model!.truncated)")

        func render<V: View>(_ name: String, size: CGSize, scheme: ColorScheme = .dark, _ view: V) -> Double {
            let renderer = ImageRenderer(content: view.frame(width: size.width, height: size.height).environment(\.colorScheme, scheme).environment(\.livingTreeInteractive, false))
            renderer.scale = 2
            let started = Date()
            guard let image = renderer.cgImage else { print("render \(name) failed"); return 0 }
            let seconds = Date().timeIntervalSince(started)
            writePNG(image, to: output.appendingPathComponent(name + ".png"))
            print("render \(name) \(Int(size.width))x\(Int(size.height))@2x \(String(format: "%.1f", seconds * 1000))ms")
            return seconds
        }
        /// The whole Disk Inventory explorer (tree, Navigator, Inspector) in a window that is never shown.
        func page(_ name: String, scheme: NSAppearance.Name) {
            let host = NSHostingView(rootView: InventoryExplorerView(browser: browser).frame(width: 1440, height: 1000))
            host.frame = NSRect(x: 0, y: 0, width: 1440, height: 1000)
            let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 1440, height: 1000), styleMask: [.borderless], backing: .buffered, defer: true)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: scheme)
            window.contentView = host
            host.appearance = NSAppearance(named: scheme)
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(1.2))
            host.layoutSubtreeIfNeeded()
            guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
            host.appearance!.performAsCurrentDrawingAppearance { host.cacheDisplay(in: host.bounds, to: bitmap) }
            if let image = bitmap.cgImage { writePNG(image, to: output.appendingPathComponent(name + ".png")); print("render \(name) 1440x1000 (window never ordered in)") }
            window.contentView = nil
        }

        // 1. The volume.
        _ = render("living-tree-volume", size: panel, LivingTreeView(browser: browser, explorer: explorer, tree: tree))

        // 2. Draw timing of the static tree alone, and memory across repeated renders.
        tree.viewportChanged(panel)
        let model = tree.model!, layout = tree.projected(for: panel)!
        var draws = [Double]()
        let before = footprint()
        for _ in 0..<20 {
            let renderer = ImageRenderer(content: LivingTreeBaseCanvas(revision: tree.revision, size: panel, transform: layout.transform, zoom: 1, geometry: layout.geometry, model: model).frame(width: panel.width, height: panel.height))
            renderer.scale = 2
            let started = Date(); _ = renderer.cgImage; draws.append(Date().timeIntervalSince(started))
        }
        draws.sort()
        print("draw static tree (\(layout.geometry.branches.count) elements, 1400x860@2x) p50=\(String(format: "%.1f", draws[draws.count / 2] * 1000))ms max=\(String(format: "%.1f", draws.last! * 1000))ms footprint_before=\(before / 1024)KB footprint_after=\(footprint() / 1024)KB")

        // 3. A selection deep in the tree: its path back to the trunk is lit and the Navigator opens to it.
        if let key = model.order.filter({ model[$0]!.depth == 3 && model[$0]!.node != nil }).max(by: { (model[$0]!.bytes ?? 0, $1) < (model[$1]!.bytes ?? 0, $0) }), let node = model[key]!.node {
            let chain = model.ancestry(of: key).dropFirst().dropLast().compactMap { model[$0]?.node }
            explorer.select(node, through: Array(chain))
            _ = render("living-tree-selection", size: panel, LivingTreeView(browser: browser, explorer: explorer, tree: tree))
        }

        // 4. Measured changes: growth in three drawn folders, reduction in two, committed to the clone and read
        //    through the controller (change feed, rebuild, size signals).
        tree.inventoryChanged()
        _ = await waitUntil { tree.illumination.cursor != nil }
        // Folders whose stored measurement is settled (a folder mid-reconciliation is not compared, by design).
        func settled(_ id: Int64) -> Bool {
            var db: OpaquePointer?, statement: OpaquePointer?
            guard sqlite3_open_v2(database, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return false }
            defer { sqlite3_finalize(statement); sqlite3_close(db) }
            sqlite3_prepare_v2(db, "SELECT status='complete' FROM inventory_nodes WHERE id=?", -1, &statement, nil)
            sqlite3_bind_int64(statement, 1, id)
            return sqlite3_step(statement) == SQLITE_ROW && sqlite3_column_int(statement, 0) == 1
        }
        let folders = model.order.filter { key in
            guard let element = model[key], element.role == .branch, element.depth >= 2, element.depth <= 4, let bytes = element.bytes, bytes > 50_000_000 else { return false }
            return settled(key.nodeID!)
        }.sorted { (model[$0]!.bytes ?? 0, $1) > (model[$1]!.bytes ?? 0, $0) }
        let grow = Array(folders.prefix(9).enumerated().filter { $0.offset % 3 == 0 }.map(\.element))
        let shrink = Array(folders.dropFirst(9).prefix(6).enumerated().filter { $0.offset % 3 == 1 }.map(\.element))
        try? await Task.sleep(for: .milliseconds(1_100))
        for key in grow { commitSizeChange(database, folder: key.nodeID!, delta: (model[key]!.bytes ?? 0) / 8) }
        for key in shrink { commitSizeChange(database, folder: key.nodeID!, delta: -(model[key]!.bytes ?? 0) / 10) }
        let revision = tree.revision
        tree.inventoryChanged()
        let lit = await waitUntil { !tree.illumination.glows.isEmpty && tree.revision > revision }
        let names = tree.illumination.glows.map { id, glow in "\(tree.model?[.node(id)]?.name ?? "#\(id)")=\(glow.trend.rawValue)/\(String(format: "%.2f", glow.strength))" }.sorted()
        let feed = try? await InventoryReader(path: database).sizeSignals(nodeIDs: (grow + shrink).compactMap(\.nodeID))
        print("glow detail \(names) direct-signals=\(feed?.count ?? -1)")
        print("signals committed growth=\(grow.count) reduction=\(shrink.count) lit=\(lit) glows=\(tree.illumination.glows.count) rebuilds=\(tree.statistics.rebuildsForChanges)")
        try? await Task.sleep(for: .milliseconds(900))
        _ = render("living-tree-signals", size: panel, LivingTreeView(browser: browser, explorer: explorer, tree: tree))
        var overlay = [Double]()
        for _ in 0..<10 {
            let geometry = tree.projected(for: panel)!.geometry, current = tree.model!, light = tree.illumination
            let renderer = ImageRenderer(content: Canvas { context, _ in
                LivingTreePainter(geometry: geometry, model: current).paintOverlay(&context, now: Date(), illumination: light, reduceMotion: false, hovered: nil, chain: [], focus: nil)
            }.frame(width: panel.width, height: panel.height))
            let started = Date(); _ = renderer.cgImage; overlay.append(Date().timeIntervalSince(started))
        }
        overlay.sort()
        print("draw illumination overlay (one animation frame, \(tree.illumination.glows.count) glows) p50=\(String(format: "%.2f", overlay[overlay.count / 2] * 1000))ms")
        try? await Task.sleep(for: .seconds(20))
        _ = render("living-tree-signals-fading", size: panel, LivingTreeView(browser: browser, explorer: explorer, tree: tree))

        // 5. The whole page, dark and light (the tree keeps its charcoal ground in both).
        page("living-tree-page-dark", scheme: .darkAqua)
        page("living-tree-page-light", scheme: .aqua)

        // 6. Into the largest folder: a new trunk.
        if let largest = model[model.rootKey]!.children.compactMap({ model[$0]?.node }).filter({ $0.kind == .directory }).max(by: { ($0.allocatedBytes ?? 0) < ($1.allocatedBytes ?? 0) }) {
            browser.navigate(largest)
            await browser.load()
            explorer.show(root: browser.directory ?? largest, trail: browser.breadcrumbs)
            tree.show(root: browser.directory ?? largest, trail: browser.breadcrumbs)
            _ = await waitUntil { tree.model?.root.id == largest.id }
            _ = render("living-tree-folder", size: panel, LivingTreeView(browser: browser, explorer: explorer, tree: tree))
            print("folder \(largest.name) elements=\(tree.model?.count ?? 0)")
        }
        print("footprint_end=\(footprint() / 1024)KB")
    }
}
