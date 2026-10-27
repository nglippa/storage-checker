// Offscreen check that the Inspector keeps its scroll position through refreshes of the same item and starts at the
// top for a new one. Hosts the real explorer page in a borderless window that is never shown; reads an APFS clone.
// Run through scripts/probe-inspector-scroll.sh /path/to/catalog.sqlite3
import SwiftUI
import AppKit
import SQLite3

@MainActor func waitUntil(seconds: Double = 10, _ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while !condition() { if Date() > deadline { return false }; try? await Task.sleep(for: .milliseconds(5)) }
    return true
}
func firstID(_ database: String, _ sql: String) -> Int64? {
    var db: OpaquePointer?, st: OpaquePointer?; defer { sqlite3_finalize(st); sqlite3_close(db) }
    guard sqlite3_open_v2(database, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return nil }
    sqlite3_prepare_v2(db, sql, -1, &st, nil); return sqlite3_step(st) == SQLITE_ROW ? sqlite3_column_int64(st, 0) : nil
}
func scrollViews(_ view: NSView) -> [NSScrollView] { (view as? NSScrollView).map { [$0] } ?? [] + view.subviews.flatMap(scrollViews) }

@main struct Probe {
    @MainActor static func main() async {
        setvbuf(stdout, nil, _IOLBF, 0)
        _ = NSApplication.shared; NSApplication.shared.setActivationPolicy(.prohibited)
        UserDefaults.standard.register(defaults: ["inventory.explorer.visualization": "atlas", "inventory.explorer.mapHeight": 400.0, "inventory.explorer.inspector": true])
        let database = CommandLine.arguments[1]
        let reader = InventoryReader(path: database)
        guard let id = firstID(database, "SELECT n.id FROM inventory_nodes n JOIN inventory_nodes p ON n.parent_id=p.id WHERE n.name='2.1.306' AND p.name='versions'"),
              let node = try? await reader.node(id: id), let parent = try? await reader.node(id: node.parentID!) else { print("no node"); return }
        let browser = InventoryBrowserModel(database: database, readiness: ViewerReadiness(output: nil))
        await browser.load(); browser.navigate(parent); await browser.load()
        browser.explorer.show(root: browser.directory ?? parent, trail: browser.breadcrumbs)
        _ = await waitUntil { browser.explorer.state.children[parent.id] != nil }
        browser.explorer.select(node, through: [])
        let host = NSHostingView(rootView: InventoryExplorerView(browser: browser).frame(width: 1240, height: 720))
        host.frame = NSRect(x: 0, y: 0, width: 1240, height: 720)
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 1240, height: 720), styleMask: [.borderless], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false; window.contentView = host; host.appearance = NSAppearance(named: .aqua)
        host.layoutSubtreeIfNeeded()
        _ = await waitUntil(seconds: 8) { browser.cleanup.inspection?.nodeID == node.id }
        browser.cleanup.loadPreview(node)
        _ = await waitUntil(seconds: 8) { browser.cleanup.preview != nil }
        func spin(_ s: Double) async { let end = Date().addingTimeInterval(s); while Date() < end { host.layoutSubtreeIfNeeded(); try? await Task.sleep(for: .milliseconds(20)) } }
        await spin(0.6)
        guard let scroll = scrollViews(host).filter({ $0.convert($0.bounds, to: host).minX > 900 }).max(by: { $0.bounds.height < $1.bounds.height }) else { print("no inspector scroll view"); return }
        func state() -> String { let doc = scroll.documentView?.frame.height ?? 0; return String(format: "offset %.0f / max %.0f (doc %.0f)", scroll.contentView.bounds.origin.y, doc - scroll.contentView.bounds.height, doc) }
        func toBottom() { let doc = scroll.documentView?.frame.height ?? 0; scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, doc - scroll.contentView.bounds.height))); scroll.reflectScrolledClipView(scroll.contentView) }
        toBottom(); await spin(0.3); print("start          ", state())
        // Track the minimum offset during each event (a momentary jump to the top counts).
        func watch(_ label: String, _ seconds: Double, _ action: () async -> Void) async {
            toBottom(); await spin(0.2)
            let before = scroll.contentView.bounds.origin.y
            await action()
            var low = before; let end = Date().addingTimeInterval(seconds)
            while Date() < end { host.layoutSubtreeIfNeeded(); low = min(low, scroll.contentView.bounds.origin.y); try? await Task.sleep(for: .milliseconds(10)) }
            print(label.padding(toLength: 34, withPad: " ", startingAt: 0), String(format: "before %.0f  lowest %.0f  ", before, low), state())
        }
        await watch("browser.revision += 1", 1.5) { browser.revision &+= 1 }
        await watch("cleanup.refresh(node)", 3) { browser.cleanup.refresh(browser.explorer.state.node(node.id) ?? node) }
        await watch("explorer.inventoryChanged()", 2) { browser.explorer.inventoryChanged() }
        await watch("browser.load()", 3) { await browser.load() }
        await watch("node remeasured (fingerprint)", 3) {
            var changed = node; changed = InventoryNode(id: node.id, parentID: node.parentID, identity: node.identity, path: node.path, name: node.name, kind: node.kind, logicalBytes: (node.logicalBytes ?? 0) + 1, allocatedBytes: node.allocatedBytes, previousLogicalBytes: nil, previousAllocatedBytes: nil, objectLogicalBytes: nil, objectAllocatedBytes: nil, directLogicalBytes: 0, directAllocatedBytes: 0, childCount: 0, descendantFiles: 0, descendantDirectories: 0, status: .complete, coverageState: "complete", listingState: nil, statusReason: nil, measuredAt: Date(), modifiedAt: nil, generation: node.generation, isHardlinkAlias: false, historicalGrowthBytes: nil)
            browser.cleanup.update(changed)
        }
        await watch("idle 25 s", 25) {}
        if let otherID = firstID(database, "SELECT n.id FROM inventory_nodes n JOIN inventory_nodes p ON n.parent_id=p.id WHERE n.name='2.1.310' AND p.name='versions'"), let other = try? await reader.node(id: otherID) {
            toBottom(); await spin(0.2)
            browser.explorer.select(other, through: []); await spin(1.5)
            print("select another item              ", state(), "subject", browser.cleanup.inspection?.nodeID == other.id ? "2.1.310" : "?")
        }
        window.contentView = nil
    }
}
