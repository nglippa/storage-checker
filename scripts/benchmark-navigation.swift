import AppKit
import SwiftUI
import SQLite3

// Structured Explorer navigation, end to end: from the navigation request (the app's `browser.navigate`, as a
// double-click, Return, Up or breadcrumb issues it) to interaction readiness (the new folder's tree read, laid out and
// labelled for the canvas). Unlike benchmark-structured-explorer.swift, the clone keeps its pending reconciliation work
// and the inventory refreshes every 2 s, as in the native QA session whose navigation took 1.5–2.7 s. Offscreen only;
// preferences are registered in memory. Run through scripts/benchmark-navigation.sh on an APFS clone.

@MainActor func waitUntil(timeout: Double = 8, _ condition: @MainActor () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() { if Date() > deadline { return false }; try? await Task.sleep(for: .milliseconds(2)) }
    return true
}

func footprintMiB() -> Double {
    var info = task_vm_info_data_t(), count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
    let result = withUnsafeMutablePointer(to: &info) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) } }
    return result == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : -1
}

struct Stats {
    var samples = [Double]()
    func percentile(_ p: Double) -> Double {
        let s = samples.sorted(); guard !s.isEmpty else { return .nan }
        return s[min(s.count - 1, Int((Double(s.count - 1) * p).rounded()))]
    }
    var json: [String: Any] { ["n": samples.count, "p50_ms": percentile(0.5), "p95_ms": samples.count >= 10 ? percentile(0.95) : NSNull(), "max_ms": samples.max() ?? .nan, "samples_ms": samples] }
}

@main struct NavigationBenchmark {
    @MainActor static func main() async {
        setvbuf(stdout, nil, _IOLBF, 0)
        _ = NSApplication.shared
        NSApplication.shared.setActivationPolicy(.prohibited)
        let args = CommandLine.arguments
        guard args.count == 4 else { fputs("usage: benchmark <catalog clone> <output.json> <label>\n", stderr); exit(2) }
        let database = args[1], output = URL(fileURLWithPath: args[2]), label = args[3]
        // In memory only (registration domain): nothing is written to any preference domain.
        let registered: [String: Any] = ["inventory.explorer.visualization": "tree", "inventory.livingTree.renderer": "structured", "inventory.structuredExplorer.depth": 3]
        UserDefaults.standard.register(defaults: registered); ViewerStore.viewPreferences.register(defaults: registered)
        var pending = 0
        var db: OpaquePointer?
        if sqlite3_open_v2(database, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK {
            var statement: OpaquePointer?
            if sqlite3_prepare_v2(db, "SELECT count(*) FROM inventory_reconcile", -1, &statement, nil) == SQLITE_OK, sqlite3_step(statement) == SQLITE_ROW { pending = Int(sqlite3_column_int64(statement, 0)) }
            sqlite3_finalize(statement); sqlite3_close(db)
        }
        let memoryStart = footprintMiB()
        let browser = InventoryBrowserModel(database: database, readiness: ViewerReadiness(output: nil))
        await browser.load()
        guard let root = browser.directory else { fputs("no inventory root\n", stderr); exit(1) }
        let tree = browser.livingTree, state = browser.structuredExplorer, explorer = browser.explorer
        let viewport = CGSize(width: 900, height: 520)
        state.viewport = viewport
        explorer.show(root: root, trail: browser.breadcrumbs)
        tree.show(root: root, trail: browser.breadcrumbs)
        guard await waitUntil({ tree.model != nil }) else { fputs("tree did not build\n", stderr); exit(1) }
        let journalless = tree.model?.journalCursor == nil

        // The inventory refreshes every 2 s while reconciliation is pending (native log: inventory.load every ~2 s).
        let churn = Task { @MainActor in
            while !Task.isCancelled { try? await Task.sleep(for: .seconds(2)); await browser.load(); tree.inventoryChanged() }
        }

        /// The app's order of events for a folder change: navigate → page load → the view's onChange shows the tree →
        /// the tree read → layout and labels for the first frame. Returns (total, read wait, layout + labels) in ms.
        func navigate(to folder: InventoryNode) async -> (Double, Double, Double)? {
            let started = DispatchTime.now().uptimeNanoseconds
            func ms(_ since: UInt64) -> Double { Double(DispatchTime.now().uptimeNanoseconds - since) / 1e6 }
            browser.navigate(folder)
            await browser.load()
            guard let directory = browser.directory, directory.id == folder.id else { return nil }
            tree.show(root: directory, trail: browser.breadcrumbs)
            let shown = DispatchTime.now().uptimeNanoseconds
            guard await waitUntil({ tree.model?.root.id == folder.id }) else { return nil }
            let read = ms(shown)
            let framed = DispatchTime.now().uptimeNanoseconds
            let model = tree.model!
            let layout = state.layout(model, revision: tree.revision, depth: 3, selection: nil)
            let t = StructuredExplorerCamera().transform(bounds: layout.bounds, size: viewport)
            let labels = state.labels(layout, model: model, transform: t, size: viewport, selected: nil, hovered: nil)
            _ = layout.ringCaptions(transform: t, size: viewport, labels: labels, measure: StructuredExplorerPainter.captionSize)
            return (ms(started), read, ms(framed))
        }

        let model = tree.model!
        let folders = model[model.rootKey]!.children.compactMap { model[$0]?.node }.filter { $0.kind == .directory && $0.childCount > 0 }
            .sorted { ($0.allocatedBytes ?? 0) > ($1.allocatedBytes ?? 0) }
        guard folders.count >= 3 else { fputs("too few folders\n", stderr); exit(1) }
        var cold = Stats(), enter = Stats(), parent = Stats(), revisit = Stats(), readWait = Stats(), frame = Stats()
        var failures = 0
        let throttledBefore = tree.statistics.throttledRebuilds
        // Cold: the first visit to each of the largest folders (and back), at varied phases of the refresh cycle.
        for (i, folder) in folders.prefix(8).enumerated() {
            try? await Task.sleep(for: .milliseconds(150 + 230 * (i % 8)))
            if let r = await navigate(to: folder) { cold.samples.append(r.0); readWait.samples.append(r.1); frame.samples.append(r.2) } else { failures += 1 }
            try? await Task.sleep(for: .milliseconds(120 + 170 * (i % 5)))
            if let r = await navigate(to: root) { parent.samples.append(r.0) } else { failures += 1 }
        }
        // Warm: entering folders already visited, then revisiting them (the controller keeps reading memory and cameras).
        for i in 0..<16 {
            let folder = folders[i % 3]
            try? await Task.sleep(for: .milliseconds(90 + 260 * (i % 7)))
            if let r = await navigate(to: folder) { if i < 8 { enter.samples.append(r.0) } else { revisit.samples.append(r.0) }; readWait.samples.append(r.1); frame.samples.append(r.2) } else { failures += 1 }
            try? await Task.sleep(for: .milliseconds(110 + 190 * (i % 6)))
            if let r = await navigate(to: root) { parent.samples.append(r.0) } else { failures += 1 }
        }
        let throttled = tree.statistics.throttledRebuilds - throttledBefore

        // Selection: the shared selection changes and the canvas's next frame is laid out and labelled.
        var selection = Stats(), depthChange = Stats()
        let current = tree.model!
        for key in current.order.filter({ current[$0]?.node != nil && $0 != current.rootKey }).prefix(24) {
            let started = DispatchTime.now().uptimeNanoseconds
            explorer.select(current[key]!.node!, through: current.ancestry(of: key).dropFirst().dropLast().compactMap { current[$0]?.node })
            let layout = state.layout(current, revision: tree.revision, depth: 3, selection: key)
            let t = StructuredExplorerCamera().transform(bounds: layout.bounds, size: viewport)
            _ = state.labels(layout, model: current, transform: t, size: viewport, selected: layout.shownKey(for: key, in: current), hovered: nil)
            selection.samples.append(Double(DispatchTime.now().uptimeNanoseconds - started) / 1e6)
            try? await Task.sleep(for: .milliseconds(5))
        }
        for depth in [1, 2, 4, 6, 5, 3, 2, 6, 4, 3, 1, 5] {
            let started = DispatchTime.now().uptimeNanoseconds
            let layout = state.layout(current, revision: tree.revision, depth: depth, selection: nil)
            let t = StructuredExplorerCamera().transform(bounds: layout.bounds, size: viewport)
            _ = state.labels(layout, model: current, transform: t, size: viewport, selected: nil, hovered: nil)
            depthChange.samples.append(Double(DispatchTime.now().uptimeNanoseconds - started) / 1e6)
        }

        // Renderer switches: mount the classic tree and the Structured Explorer over the same loaded controller and render
        // one offscreen frame each. Switching must not re-read the catalog (refreshes are paused for this part).
        churn.cancel()
        try? await Task.sleep(for: .milliseconds(600))
        var toClassic = Stats(), toStructured = Stats()
        let buildsBefore = tree.statistics.builds
        for _ in 0..<6 {
            for structured in [false, true] {
                let started = DispatchTime.now().uptimeNanoseconds
                let window = NSWindow(contentRect: CGRect(x: -10000, y: -10000, width: viewport.width, height: viewport.height), styleMask: [.borderless], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                let content = structured ? AnyView(StructuredExplorerView(browser: browser, explorer: explorer, tree: tree)) : AnyView(LivingTreeView(browser: browser, explorer: explorer, tree: tree))
                window.contentView = NSHostingView(rootView: content.frame(width: viewport.width, height: viewport.height))
                window.contentView!.layoutSubtreeIfNeeded()
                if let view = window.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) { view.cacheDisplay(in: view.bounds, to: rep) }
                let elapsed = Double(DispatchTime.now().uptimeNanoseconds - started) / 1e6
                if structured { toStructured.samples.append(elapsed) } else { toClassic.samples.append(elapsed) }
                window.contentView = nil
            }
        }
        try? await Task.sleep(for: .milliseconds(300))
        let switchBuilds = tree.statistics.builds - buildsBefore
        let memoryEnd = footprintMiB()

        let result: [String: Any] = [
            "label": label, "pending_reconcile_rows": pending, "tree_without_change_journal": journalless,
            "throttled_same_folder_rebuilds_during_navigation": throttled, "failures": failures,
            "folder_enter_cold": cold.json, "folder_enter_warm": enter.json, "folder_revisit": revisit.json, "parent": parent.json,
            "tree_read_wait_after_show": readWait.json, "layout_labels_first_frame": frame.json,
            "selection_to_frame": selection.json, "depth_change": depthChange.json,
            "mount_classic": toClassic.json, "mount_structured": toStructured.json, "tree_builds_during_renderer_switches": switchBuilds,
            "memory_footprint_mib": ["start": memoryStart, "end": memoryEnd],
        ]
        if let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]) { try? data.write(to: output) }
        func line(_ name: String, _ s: Stats) {
            let p95 = s.samples.count >= 10 ? String(format: "%7.1f", s.percentile(0.95)) : "      —"
            print("\(label) \(name.padding(toLength: 22, withPad: " ", startingAt: 0)) n=\(s.samples.count) p50 \(String(format: "%7.1f", s.percentile(0.5))) p95 \(p95) max \(String(format: "%7.1f", s.samples.max() ?? .nan)) ms")
        }
        print("\(label): pending reconcile rows \(pending); tree without change journal \(journalless); throttled same-folder rebuilds \(throttled); failures \(failures); renderer-switch tree builds \(switchBuilds)")
        line("folder enter (cold)", cold); line("folder enter (warm)", enter); line("folder revisit", revisit); line("parent (Up)", parent)
        line("tree read wait", readWait); line("layout+labels frame", frame); line("selection", selection); line("depth change", depthChange)
        line("mount classic", toClassic); line("mount structured", toStructured)
        print("\(label) memory footprint \(String(format: "%.1f", memoryStart)) → \(String(format: "%.1f", memoryEnd)) MiB")
        exit(failures == 0 ? 0 : 1)
    }
}
