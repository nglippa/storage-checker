import SwiftUI
import AppKit
import SQLite3
import ImageIO
import UniformTypeIdentifiers

// Cleanup Inspector measurements against an APFS clone of a real catalog: SQLite read latency, the quick check every
// selection pays, full inspections of recognized items (read-only evidence from the real filesystem), controller
// update latency, rapid selection changes and memory. Run through scripts/benchmark-cleanup-inspector.sh. Nothing is
// shown on screen and nothing is written outside the clone.

func footprint() -> Int64 {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let result = withUnsafeMutablePointer(to: &info) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) } }
    return result == KERN_SUCCESS ? Int64(info.phys_footprint) : -1
}
func percentile(_ values: [Double], _ p: Double) -> Double { guard !values.isEmpty else { return 0 }; let s = values.sorted(); return s[min(s.count - 1, Int(Double(s.count - 1) * p + 0.5))] }
func ms(_ s: Double) -> String { String(format: "%.2f", s * 1000) }
@MainActor func waitUntil(seconds: Double = 10, _ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while !condition() { if Date() > deadline { return false }; try? await Task.sleep(for: .milliseconds(2)) }
    return true
}

/// Node ids from the clone (read-only connection).
func ids(_ database: String, _ sql: String) -> [Int64] {
    var db: OpaquePointer?, statement: OpaquePointer?, result = [Int64]()
    guard sqlite3_open_v2(database, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return [] }
    defer { sqlite3_finalize(statement); sqlite3_close(db) }
    sqlite3_prepare_v2(db, sql, -1, &statement, nil)
    while sqlite3_step(statement) == SQLITE_ROW { result.append(sqlite3_column_int64(statement, 0)) }
    return result
}

@main struct CleanupInspectorBenchmark {
    @MainActor static func main() async {
        setvbuf(stdout, nil, _IOLBF, 0)
        _ = NSApplication.shared
        NSApplication.shared.setActivationPolicy(.prohibited)
        guard CommandLine.arguments.count >= 2 else { fputs("usage: benchmark <catalog clone> [evidence folder]\n", stderr); exit(2) }
        let database = CommandLine.arguments[1]
        let reader = InventoryReader(path: database)
        let environment = ArtifactEnvironment.current(ownData: "/nonexistent")
        print("catalog nodes=\(ids(database, "SELECT COUNT(*) FROM inventory_nodes").first ?? 0)")

        // 1. SQLite: a node by id and the preview's largest children.
        let sample = ids(database, "SELECT id FROM inventory_nodes ORDER BY random() LIMIT 2000")
        var nodeReads = [Double](), childReads = [Double](), nodes = [InventoryNode]()
        for id in sample {
            let t = Date(); if let node = try? await reader.node(id: id) { nodes.append(node) }; nodeReads.append(Date().timeIntervalSince(t))
        }
        for node in nodes.filter({ $0.kind == .directory }).prefix(300) {
            let t = Date(); _ = try? await reader.explorerChildren(parentID: node.id, limit: 12); childReads.append(Date().timeIntervalSince(t))
        }
        print("sqlite node read p50=\(ms(percentile(nodeReads, 0.5)))ms p95=\(ms(percentile(nodeReads, 0.95)))ms; preview children (12 largest) p50=\(ms(percentile(childReads, 0.5)))ms p95=\(ms(percentile(childReads, 0.95)))ms max=\(ms(childReads.max() ?? 0))ms (n=\(childReads.count))")

        // 2. The quick check every selection pays (names plus at most two lstat calls), over random real paths.
        var quick = [Double](), applies = 0
        for node in nodes {
            let subject = ArtifactSubject(nodeID: node.id, path: node.path, kind: node.kind, identity: node.identity)
            let t = Date(); if ArtifactInspector.mightApply(subject, environment: environment) { applies += 1 }; quick.append(Date().timeIntervalSince(t))
        }
        print("quick check (\(nodes.count) random nodes) p50=\(String(format: "%.1f", percentile(quick, 0.5) * 1e6))us p95=\(String(format: "%.1f", percentile(quick, 0.95) * 1e6))us max=\(ms(quick.max() ?? 0))ms; \(applies) might be artifacts")

        // 3. Full inspections of items detectors recognize, by family (read-only evidence from the real filesystem).
        let families: [(String, String)] = [
            ("node_modules", "SELECT id FROM inventory_nodes WHERE name='node_modules' AND kind='directory' ORDER BY random() LIMIT 40"),
            ("build output", "SELECT id FROM inventory_nodes WHERE name IN ('dist','build','.next','storybook-static') AND kind='directory' ORDER BY random() LIMIT 40"),
            ("__pycache__", "SELECT id FROM inventory_nodes WHERE name='__pycache__' ORDER BY random() LIMIT 40"),
            ("venv", "SELECT n.id FROM inventory_nodes n JOIN inventory_nodes c ON c.parent_id=n.id AND c.name='pyvenv.cfg' ORDER BY random() LIMIT 30"),
            ("claude/codex releases", "SELECT n.id FROM inventory_nodes n JOIN inventory_nodes p ON n.parent_id=p.id WHERE p.name IN ('versions','releases') AND n.name GLOB '[0-9]*.[0-9]*' LIMIT 40"),
            ("worktrees", "SELECT n.id FROM inventory_nodes n JOIN inventory_nodes c ON c.parent_id=n.id AND c.name='.git' AND c.kind='file' LIMIT 20"),
            ("sessions", "SELECT id FROM inventory_nodes WHERE name IN ('sessions','archived_sessions','projects') AND kind='directory' LIMIT 20"),
        ]
        var all = [Double](), statuses = [CleanupStatus: Int](), unclassified = 0
        var examples = [CleanupStatus: InventoryNode]()
        for (family, sql) in families {
            var times = [Double](), found = 0
            for id in ids(database, sql) {
                guard let node = try? await reader.node(id: id) else { continue }
                let t = Date(); let inspection = ArtifactInspector.inspect(node, environment: environment); let dt = Date().timeIntervalSince(t)
                times.append(dt); all.append(dt)
                if let status = inspection.assessment?.status { statuses[status, default: 0] += 1; found += 1; if examples[status] == nil && inspection.identity == .verified { examples[status] = node } } else { unclassified += 1 }
            }
            print("inspect \(family): n=\(times.count) recognized=\(found) p50=\(ms(percentile(times, 0.5)))ms p95=\(ms(percentile(times, 0.95)))ms max=\(ms(times.max() ?? 0))ms")
        }
        print("inspect all: n=\(all.count) p50=\(ms(percentile(all, 0.5)))ms p95=\(ms(percentile(all, 0.95)))ms; statuses \(statuses.map { "\($0.key.title)=\($0.value)" }.sorted().joined(separator: ", ")); unrecognized after validation=\(unclassified)")

        // 4. Controller: update latency (selection to published evidence) and rapid selection changes.
        let controller = CleanupInspectorController(database: database, environment: environment)
        let recognized = await {
            var result = [InventoryNode]()
            for (_, sql) in families { for id in ids(database, sql).prefix(6) { if let node = try? await reader.node(id: id), ArtifactInspector.mightApply(ArtifactSubject(nodeID: node.id, path: node.path, kind: node.kind, identity: node.identity), environment: environment) { result.append(node) } } }
            return result
        }()
        var updates = [Double]()
        for node in recognized.prefix(30) {
            let t = Date(); controller.update(node)
            _ = await waitUntil { controller.inspection?.nodeID == node.id || (controller.inspecting == nil && controller.inspection == nil) }
            updates.append(Date().timeIntervalSince(t))
        }
        print("controller update to published evidence (n=\(updates.count)) p50=\(ms(percentile(updates, 0.5)))ms p95=\(ms(percentile(updates, 0.95)))ms max=\(ms(updates.max() ?? 0))ms")
        let before = footprint()
        let mixed = (recognized + nodes.prefix(200)).shuffled()
        let t0 = Date()
        for round in 0..<5 { for node in mixed { controller.update(node) }; if round == 4 { break } }
        let rapid = Date().timeIntervalSince(t0)
        let last = mixed.last!
        _ = await waitUntil(seconds: 20) { controller.inspecting == nil }
        try? await Task.sleep(for: .milliseconds(500))
        print("rapid selection: \(mixed.count * 5) changes in \(ms(rapid))ms on the main thread (\(String(format: "%.1f", rapid / Double(mixed.count * 5) * 1e6))us each); final evidence is for the last selection: \(controller.inspection == nil || controller.inspection?.nodeID == last.id); inspections=\(controller.statistics.inspections) discarded=\(controller.statistics.discarded) quick skips=\(controller.statistics.quickSkips); footprint before=\(before / 1024)KB after=\(footprint() / 1024)KB")

        // 5. Offscreen renders of the explorer page with the Inspector showing each kind of assessment (a borderless
        //    window that is never ordered in; the process may not activate).
        guard CommandLine.arguments.count >= 3 else { return }
        let output = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
        try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        UserDefaults.standard.register(defaults: ["inventory.explorer.visualization": "atlas", "inventory.explorer.mapHeight": 260.0, "inventory.explorer.inspector": true])
        for (status, node) in examples.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
            let browser = InventoryBrowserModel(database: database, readiness: ViewerReadiness(output: nil))
            await browser.load()
            guard let parentID = node.parentID, let parent = try? await reader.node(id: parentID) else { continue }
            browser.navigate(parent); await browser.load()
            browser.explorer.show(root: browser.directory ?? parent, trail: browser.breadcrumbs)
            _ = await waitUntil { browser.explorer.state.children[parent.id] != nil }
            browser.explorer.select(node, through: [])
            let host = NSHostingView(rootView: InventoryExplorerView(browser: browser).frame(width: 1280, height: 900))
            host.frame = NSRect(x: 0, y: 0, width: 1280, height: 900)
            let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 1280, height: 900), styleMask: [.borderless], backing: .buffered, defer: true)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: .aqua); window.contentView = host; host.appearance = NSAppearance(named: .aqua)
            host.layoutSubtreeIfNeeded()
            // The Inspector starts the inspection when it appears; wait cooperatively (the result is published on the
            // main actor), then lay out again.
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
            if browser.cleanup.inspecting == nil && browser.cleanup.inspection?.nodeID != node.id { browser.cleanup.update(node) }
            _ = await waitUntil(seconds: 8) { browser.cleanup.inspection?.nodeID == node.id }
            if status == .reviewCandidate {
                browser.cleanup.loadPreview(node)
                _ = await waitUntil(seconds: 8) { browser.cleanup.preview != nil }
            }
            RunLoop.main.run(until: Date().addingTimeInterval(0.5))
            host.layoutSubtreeIfNeeded()
            if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.appearance!.performAsCurrentDrawingAppearance { host.cacheDisplay(in: host.bounds, to: bitmap) }
                let name = "cleanup-inspector-\(status.rawValue).png"
                if let image = bitmap.cgImage, let destination = CGImageDestinationCreateWithURL(output.appendingPathComponent(name) as CFURL, UTType.png.identifier as CFString, 1, nil) {
                    CGImageDestinationAddImage(destination, image, nil); CGImageDestinationFinalize(destination)
                    print("render \(name): \(node.name) → \(browser.cleanup.inspection?.assessment?.status.title ?? "none")\(status == .reviewCandidate ? " (preview \(browser.cleanup.preview != nil ? "open" : "not loaded"))" : "")")
                }
            }
            window.contentView = nil
        }
    }
}
