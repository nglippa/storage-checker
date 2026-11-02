import SwiftUI
import AppKit
import Darwin

// Headless navigation benchmark. Hosts the real MonitorRootView in a borderless window at −30000 that is never
// ordered on screen (activation policy .prohibited). No pointer, keyboard or accessibility input: every transition
// is a model/state change, exactly what the corresponding control would set.

@MainActor enum BenchHooks { static var inventory: InventoryBrowserModel?; static var liveLoop = CommandLine.arguments.contains("--live-loop") }

final class BenchSection: ObservableObject { static let shared = BenchSection(); @Published var value = "inventory" }

/// Main-thread blocking: every run-loop pass longer than 16 ms is recorded (wall time between afterWaiting and the
/// next beforeWaiting).
final class MainStallMonitor {
    struct Span { let start: Double; let duration: Double }
    private(set) var spans = [Span]()
    private var began: Double?
    private var observer: CFRunLoopObserver?
    func start() {
        observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.afterWaiting.rawValue | CFRunLoopActivity.beforeWaiting.rawValue, true, 0) { [weak self] _, activity in
            guard let self else { return }
            let now = ProcessInfo.processInfo.systemUptime
            if activity == .afterWaiting { self.began = now }
            else if let began = self.began { if now - began > 0.016 { self.spans.append(Span(start: began, duration: now - began)) }; self.began = nil }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
    }
    func blocked(from: Double, to: Double) -> (total: Double, longest: Double) {
        let inside = spans.filter { $0.start >= from - 0.001 && $0.start <= to }
        return (inside.reduce(0) { $0 + $1.duration }, inside.map(\.duration).max() ?? 0)
    }
}

func residentMB() -> Double {
    var info = mach_task_basic_info(); var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
    let result = withUnsafeMutablePointer(to: &info) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count) } }
    return result == KERN_SUCCESS ? Double(info.resident_size) / 1_048_576 : -1
}
func cpuSeconds() -> Double { var usage = rusage(); getrusage(RUSAGE_SELF, &usage); return Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1e6 + Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1e6 }

@main struct NavigationBench {
    @MainActor static func main() async {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let args = CommandLine.arguments
        func arg(_ key: String) -> String? { args.firstIndex(of: key).map { args[$0 + 1] } }
        let db = arg("--database-path")!, output = arg("--output")!, samples = Int(arg("--samples") ?? "7")!, label = arg("--label") ?? "run"
        let dark = true
        // Bench-process defaults only (unbundled executable domain); the visualization starts on the Atlas.
        let defaults = UserDefaults.standard
        for (key, value) in ["inventory.explorer.visualization": "atlas", "inventory.explorer.showMap": true, "inventory.explorer.inspector": true,
                             "inventory.explorer.technical": false, "inventory.livingTree.dimension": "flat", "inventory.header.details": false] as [String: Any] { defaults.set(value, forKey: key) }
        let stalls = MainStallMonitor(); stalls.start()
        let clock = { ProcessInfo.processInfo.systemUptime }
        var results = [[String: Any]]()
        var axElements = 0
        func record(_ name: String, _ phase: String, start: Double, firstFrame: Double, ready: Double?, cpu0: Double, extra: [String: Any] = [:]) {
            let end = ready ?? clock()
            let blocked = stalls.blocked(from: start, to: end)
            var row: [String: Any] = ["transition": name, "phase": phase, "first_frame_ms": (firstFrame - start) * 1000, "ready_ms": ready.map { ($0 - start) * 1000 } ?? -1,
                                      "main_blocked_ms": blocked.total * 1000, "longest_main_stall_ms": blocked.longest * 1000, "cpu_ms": (cpuSeconds() - cpu0) * 1000, "rss_mb": residentMB(), "ax_elements": axElements]
            row.merge(extra) { a, _ in a }
            results.append(row)
            print(String(format: "%@ %@ first=%.0fms ready=%@ blocked=%.0fms longest=%.0fms cpu=%.0fms rss=%.0fMB ax=%d", name, phase, (firstFrame - start) * 1000,
                         ready.map { String(format: "%.0fms", ($0 - start) * 1000) } ?? "TIMEOUT", blocked.total * 1000, blocked.longest * 1000, (cpuSeconds() - cpu0) * 1000, residentMB(), axElements))
            fflush(stdout)
        }
        func waitUntil(_ timeout: Double = 30, _ predicate: () -> Bool) async -> Double? {
            let end = clock() + timeout
            while !predicate() { if clock() > end { return nil }; try? await Task.sleep(for: .milliseconds(5)) }
            return clock()
        }

        // --empty-probe <png>: the Monitoring view at 1000 × 648 with the default 24-hour filter, rendered to a file.
        if let i = args.firstIndex(of: "--empty-probe") {
            let config = ViewerConfiguration(database: db, appearance: nil, windowSize: nil, isQA: true, readinessOutput: nil)
            let store = ViewerStore(configuration: config); store.filters = EventFilters(); store.refresh(); store.refreshLive()
            _ = await waitUntil(30) { store.snapshot != nil }; _ = await waitUntil(10) { store.live.state.reading != nil }
            let size = NSSize(width: 1000, height: 648)
            let view = NSHostingView(rootView: HistoryView(store: store).frame(width: size.width, height: size.height).background(Color(nsColor: .windowBackgroundColor)))
            view.frame = NSRect(origin: .zero, size: size)
            let probe = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: size.width, height: size.height), styleMask: [.borderless], backing: .buffered, defer: true)
            probe.appearance = NSAppearance(named: .aqua); probe.contentView = view
            for _ in 0..<8 { view.layoutSubtreeIfNeeded(); try? await Task.sleep(for: .milliseconds(150)) }
            let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
            probe.appearance!.performAsCurrentDrawingAppearance { view.cacheDisplay(in: view.bounds, to: bitmap) }
            try! bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: args[i + 1]))
            precondition(!probe.isVisible); print("WROTE \(args[i + 1])"); exit(0)
        }
        // --layout-probe: the Monitoring summary's natural height against the height it is given, per window size.
        if args.contains("--layout-probe") {
            let config = ViewerConfiguration(database: db, appearance: nil, windowSize: nil, isQA: args.contains("--qa-banner"), readinessOutput: nil)
            let store = ViewerStore(configuration: config); store.filters.time = .month; store.refresh(); store.refreshLive()
            _ = await waitUntil(30) { store.snapshot != nil }; _ = await waitUntil(10) { store.live.state.reading != nil }
            if args.contains("--select") { store.selection = store.visibleEvents.first?.id; store.showInspector = true }
            for (w, h) in [(1000.0, 640.0), (1000.0, 660.0), (1240.0, 760.0), (1440.0, 840.0)] {
                let view = NSHostingView(rootView: HistoryView(store: store).frame(width: w, height: h))
                view.frame = NSRect(x: 0, y: 0, width: w, height: h)
                let probe = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: w, height: h), styleMask: [.borderless], backing: .buffered, defer: true)
                probe.contentView = view
                for _ in 0..<6 { view.layoutSubtreeIfNeeded(); try? await Task.sleep(for: .milliseconds(150)) }
                func scrolls(_ v: NSView) -> [NSScrollView] { (v as? NSScrollView).map { [$0] } ?? [] + v.subviews.flatMap(scrolls) }
                for scroll in scrolls(view) {
                    let table = scroll.documentView is NSTableView
                    print(String(format: "LAYOUT %.0fx%.0f %@ visible=%.0f content=%.0f clipped=%.0f rowsVisible=%@", w, h, table ? "table" : "summary", scroll.contentView.bounds.height, scroll.documentView?.frame.height ?? 0, max(0, (scroll.documentView?.frame.height ?? 0) - scroll.contentView.bounds.height), table ? String(format: "%.1f", scroll.contentView.bounds.height / max(1, ((scroll.documentView as? NSTableView)?.rowHeight ?? 24) + 2)) : "-"))
                }
            }
            exit(0)
        }
        let launch = clock(), cpuLaunch = cpuSeconds()
        let config = ViewerConfiguration(database: db, appearance: nil, windowSize: nil, isQA: true, readinessOutput: nil)
        let store = ViewerStore(configuration: config)
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!
        NSApp.appearance = appearance
        let root = MonitorRootView(store: store)
        let hosting = NSHostingView(rootView: root.frame(width: 1240, height: 760).environment(\.livingTreeInteractive, true))
        hosting.frame = NSRect(x: 0, y: 0, width: 1240, height: 760)
        let window = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: 1240, height: 760), styleMask: [.borderless], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false; window.isRestorable = false; window.appearance = appearance; window.contentView = hosting
        store.start()
        let render = args.contains("--render")
        let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds)!
        // --render: draw the whole hierarchy into a bitmap each frame (a hidden window may otherwise skip drawing).
        // --ax: read the accessibility hierarchy after each frame, as an assistive client (VoiceOver, UI automation) does.
        let ax = args.contains("--ax")
        func walk(_ element: Any, _ depth: Int) {
            axElements += 1
            guard depth < 40, axElements < 200_000, let object = element as? NSAccessibilityProtocol else { return }
            _ = object.accessibilityLabel(); _ = object.accessibilityRole(); _ = object.accessibilityFrame()
            for child in (object.accessibilityChildren() ?? []) { walk(child, depth + 1) }
        }
        func frame() {
            hosting.layoutSubtreeIfNeeded(); hosting.displayIfNeeded()
            if render { appearance.performAsCurrentDrawingAppearance { hosting.cacheDisplay(in: hosting.bounds, to: bitmap) } }
            if ax { axElements = 0; walk(hosting, 0) }
        }
        frame()
        precondition(!window.isVisible, "bench window must never be visible")
        // The browser model MonitorRootView created registers itself (bench build only).
        guard let inventory = BenchHooks.inventory else { fatalError("inventory model not registered") }
        let explorer = inventory.explorer
        func storageReady() -> Bool {
            guard !inventory.loading, inventory.status != nil, let directory = inventory.directory else { return false }
            return explorer.state.rootID == directory.id && explorer.mapReady(directory.id) && !explorer.state.loading.contains(directory.id)
        }
        func monitoringReady() -> Bool { store.snapshot != nil && !store.isLoading }
        // --script-only: run the viewer's own QA navigation script (PerformanceScript) instead of the bench sequence.
        if args.contains("--script-only") {
            while !(try! String(contentsOfFile: arg("--perf-log")!, encoding: .utf8)).contains("script.done") { try? await Task.sleep(for: .milliseconds(200)) }
            print("SCRIPT DONE"); exit(0)
        }
        let coldReady = await waitUntil(60) { storageReady() && store.snapshot != nil }
        record("startup", "cold", start: launch, firstFrame: launch, ready: coldReady, cpu0: cpuLaunch)
        try? await Task.sleep(for: .seconds(1.5))

        func transition(_ name: String, _ phase: String, ready: @escaping () -> Bool, settle: Double = 0.8, _ change: () -> Void) async {
            let start = clock(), cpu0 = cpuSeconds()
            change()
            frame()
            let firstFrame = clock()
            let done = await waitUntil(30, ready)
            frame()
            record(name, phase, start: start, firstFrame: firstFrame, ready: done.map { max($0, clock()) }, cpu0: cpu0)
            try? await Task.sleep(for: .seconds(settle))
        }
        // Section switching: the first switch to Monitoring is cold for its views; later ones are warm.
        for i in 0..<samples {
            await transition("storage_to_monitoring", i == 0 ? "cold" : "warm", ready: monitoringReady) { BenchSection.shared.value = "history" }
            await transition("monitoring_to_storage", i == 0 ? "cold" : "warm", ready: storageReady) { BenchSection.shared.value = "inventory" }
        }
        // Folder navigation: open the largest child folder, then go back to the parent.
        guard let top = inventory.directory else { fatalError("no directory") }
        let loaded: [InventoryNode] = explorer.state.children[top.id]?.items ?? []
        let children: [InventoryNode] = loaded.filter { $0.kind == .directory && $0.childCount > 0 }
        guard let largest = children.first else { fatalError("no child folders") }
        for i in 0..<samples {
            await transition("open_folder", i == 0 ? "cold" : "warm", ready: { storageReady() && inventory.directory?.id == largest.id }) { inventory.navigate(largest) }
            await transition("parent_folder", i == 0 ? "cold" : "warm", ready: { storageReady() && inventory.directory?.id == top.id }) { inventory.navigate(top) }
        }
        // Selecting nested tiles with the Inspector open: the nested contents of the largest folder tiles.
        explorer.requestNested(children.prefix(6).map(\.id))
        _ = await waitUntil(20) { children.prefix(3).allSatisfy { explorer.nested[$0.id] != nil } }
        let nestedTargets = children.prefix(3).compactMap { folder in explorer.nested[folder.id].flatMap { content in content.page.items.first.map { (content.chain, folder, $0) } } }
        for i in 0..<samples {
            let (chain, folder, item) = nestedTargets[i % nestedTargets.count]
            await transition("select_nested_tile", i < nestedTargets.count ? "cold" : "warm", ready: { storageReady() && explorer.state.selection == item.id }) {
                explorer.select(item, through: [folder] + chain)
            }
        }
        for i in 0..<samples {
            let target = children[i % min(children.count, 4)]
            await transition("select_folder_inspector_open", i < min(children.count, 4) ? "cold" : "warm", ready: { explorer.state.selection == target.id }) { explorer.selection = target.id }
        }
        // Explorer ↔ Living Tree.
        for i in 0..<samples {
            await transition("atlas_to_living_tree", i == 0 ? "cold" : "warm", ready: { storageReady() && inventory.livingTree.phase == .ready && inventory.livingTree.model != nil }) { defaults.set("tree", forKey: "inventory.explorer.visualization") }
            await transition("living_tree_to_atlas", i == 0 ? "cold" : "warm", ready: storageReady) { defaults.set("atlas", forKey: "inventory.explorer.visualization") }
        }
        // Monitoring → Storage while the Living Tree is the visualization (the native session's state).
        defaults.set("tree", forKey: "inventory.explorer.visualization"); try? await Task.sleep(for: .seconds(1.5))
        for i in 0..<samples {
            await transition("storage_to_monitoring_tree", i == 0 ? "cold" : "warm", ready: monitoringReady) { BenchSection.shared.value = "history" }
            await transition("monitoring_to_storage_tree", i == 0 ? "cold" : "warm", ready: storageReady) { BenchSection.shared.value = "inventory" }
        }
        let payload: [String: Any] = ["label": label, "database": db, "window": "1240x760 borderless hidden, dark", "samples": samples, "results": results,
                                      "all_main_stalls_over_250ms": stalls.spans.filter { $0.duration > 0.25 }.map { ["at": $0.start - launch, "ms": $0.duration * 1000] }]
        try! JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: output))
        precondition(!window.isVisible)
        print("WROTE \(output)")
        exit(0)
    }
}
