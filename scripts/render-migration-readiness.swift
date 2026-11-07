import SwiftUI
import AppKit
import ImageIO
import UniformTypeIdentifiers

// Offscreen renders of Migration Readiness for review. Nothing is shown on screen: the process may not activate
// (activation policy .prohibited) and every view is drawn by an NSHostingView in a borderless window that is never
// ordered in. Run through scripts/render-migration-readiness.sh on a disposable fixture catalog.

func writePNG(_ image: CGImage, to url: URL) {
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
    CGImageDestinationAddImage(destination, image, nil)
    CGImageDestinationFinalize(destination)
}

@MainActor func waitUntil(seconds: Double = 20, _ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while !condition() { if Date() > deadline { return false }; try? await Task.sleep(for: .milliseconds(25)) }
    return true
}

@main struct MigrationReadinessRenderHarness {
    @MainActor static func main() async {
        _ = NSApplication.shared
        NSApplication.shared.setActivationPolicy(.prohibited)
        let arguments = CommandLine.arguments
        guard arguments.count == 3 else { fputs("usage: render <fixture catalog> <output folder>\n", stderr); exit(2) }
        let database = arguments[1], output = URL(fileURLWithPath: arguments[2], isDirectory: true)
        try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        // Registered (in-memory) defaults only: nothing is written to any preferences file.
        UserDefaults.standard.register(defaults: ["inventory.explorer.visualization": "tree", "inventory.explorer.mapHeight": 600.0, "inventory.explorer.inspector": true])

        let browser = InventoryBrowserModel(database: database, readiness: ViewerReadiness(output: nil))
        await browser.load()
        let migration = browser.migration
        migration.refresh(); await migration.waitForPass()
        guard let report = migration.report, let headline = report.headline else { fputs("no report: \(migration.error ?? "")\n", stderr); exit(1) }
        print("report: \(report.reviewCount) review, \(report.unknownCount) unknown, \(report.informationalCount) informational; headline \(headline.title)")

        func host<V: View>(_ name: String, size: CGSize, dark: Bool, settle: Double = 0.8, _ view: V) {
            let scheme: NSAppearance.Name = dark ? .darkAqua : .aqua
            let hosting = NSHostingView(rootView: view.frame(width: size.width, height: size.height).background(Color(nsColor: .windowBackgroundColor)))
            hosting.frame = NSRect(origin: .zero, size: size)
            let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: size.width, height: size.height), styleMask: [.borderless], backing: .buffered, defer: true)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: scheme); hosting.appearance = NSAppearance(named: scheme)
            window.contentView = hosting
            hosting.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(settle))
            hosting.layoutSubtreeIfNeeded()
            guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return }
            hosting.appearance!.performAsCurrentDrawingAppearance { hosting.cacheDisplay(in: hosting.bounds, to: bitmap) }
            if let image = bitmap.cgImage { writePNG(image, to: output.appendingPathComponent(name + ".png")); print("render \(name) \(Int(size.width))x\(Int(size.height)) (window never ordered in)") }
            window.contentView = nil
        }

        // 1. The Overview line and the details popover's content.
        for dark in [false, true] {
            let suffix = dark ? "dark" : "light"
            host("overview-summary-\(suffix)", size: CGSize(width: 760, height: 34), dark: dark,
                 MigrationReadinessSummary(controller: migration, browser: browser).padding(.horizontal, 22).frame(maxWidth: .infinity, alignment: .leading))
            host("overview-details-\(suffix)", size: CGSize(width: 440, height: 560), dark: dark, MigrationReadinessPanel(report: report, browser: browser, close: {}))
        }
        // 2. The Inspector section for each kind of item.
        for item in report.items.prefix(4) {
            let slug = item.kind.application?.lowercased().replacingOccurrences(of: " ", with: "-") ?? item.kind.category.rawValue
            host("inspector-\(item.severity.rawValue)-\(slug)", size: CGSize(width: 320, height: 700), dark: false,
                 ScrollView { MigrationReadinessInspectorSection(item: item, filesystem: report.filesystem).padding(16) })
        }
        // 3. The Structured Explorer at the fixture root with Migration Review on, and the item selected in the Inspector.
        guard let root = browser.directory else { exit(1) }
        browser.explorer.show(root: root, trail: browser.breadcrumbs)
        browser.livingTree.show(root: root, trail: browser.breadcrumbs)
        _ = await waitUntil { browser.livingTree.model != nil && browser.explorer.state.children[root.id] != nil }
        browser.structuredExplorer.filter.migrationReview = true
        browser.explorer.reveal(headline.node)
        _ = await waitUntil(seconds: 5) { browser.livingTree.model?[.node(headline.id)] != nil }
        for dark in [false, true] {
            host("explorer-migration-review-\(dark ? "dark" : "light")", size: CGSize(width: 1440, height: 980), dark: dark, settle: 1.5, InventoryExplorerView(browser: browser))
        }
        browser.structuredExplorer.filter.presentation = .hide
        host("explorer-migration-review-hide-light", size: CGSize(width: 1440, height: 980), dark: false, settle: 1.5, InventoryExplorerView(browser: browser))
        browser.structuredExplorer.filter = StructuredExplorerFilter()
        host("explorer-filter-off-light", size: CGSize(width: 1440, height: 980), dark: false, settle: 1.5, InventoryExplorerView(browser: browser))
        // 4. Small window (the 1000 × 700 minimum's content area).
        browser.structuredExplorer.filter.migrationReview = true
        host("explorer-migration-review-small-light", size: CGSize(width: 1000, height: 640), dark: false, settle: 1.5, InventoryExplorerView(browser: browser))
        exit(0)
    }
}
