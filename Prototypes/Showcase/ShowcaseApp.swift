import SwiftUI
import AppKit

// Living Tree prototype showcase (QA only; never shipped). One window with the current Living Tree and both prototypes
// over the same catalog, switchable with a segmented control, so they can be compared with a real mouse, trackpad and
// keyboard. Pass a COPY of a catalog (an APFS clone under /private/tmp): the browser only reads it.
//   open -n "build/prototypes/Living Tree Prototypes.app" --args /private/tmp/…/catalog.sqlite3

@MainActor final class ShowcaseStore: ObservableObject {
    enum Mode: String, CaseIterable { case current = "Current", organic = "A · Organic", structured = "B · Structured" }
    @Published var mode = Mode.structured
    @Published private(set) var status = "Loading catalog…"
    @Published private(set) var trail: [InventoryNode] = []
    let browser: InventoryBrowserModel?
    let organic = ProtoExplorer(kind: .organic), structured = ProtoExplorer(kind: .structured)

    init() {
        let path = CommandLine.arguments.dropFirst().first { !$0.hasPrefix("-") }
        if let path, !path.hasPrefix(NSHomeDirectory() + "/Library/Application Support/"), FileManager.default.fileExists(atPath: path) {
            browser = InventoryBrowserModel(database: path, readiness: ViewerReadiness(output: nil))
        } else {
            browser = nil
            status = "Pass a copied catalog path (not the production database) as the first argument."
        }
        for explorer in [organic, structured] {
            explorer.navigateInto = { [weak self] node in Task { await self?.go(node) } }
            explorer.navigateUp = { [weak self] in Task { await self?.up() } }
        }
    }

    func start() async {
        guard let browser else { return }
        await browser.load()
        guard let root = browser.directory else { status = "The catalog has no inventory."; return }
        browser.explorer.show(root: root, trail: browser.breadcrumbs)
        await go(root)
    }
    func go(_ node: InventoryNode) async {
        guard let browser else { return }
        status = "Reading \(node.name)…"
        browser.navigate(node); await browser.load()
        let target = browser.directory ?? node
        browser.explorer.show(root: target, trail: browser.breadcrumbs)
        browser.livingTree.show(root: target, trail: browser.breadcrumbs)
        let deadline = Date().addingTimeInterval(30)
        while browser.livingTree.model?.root.id != target.id && Date() < deadline { try? await Task.sleep(for: .milliseconds(30)) }
        guard let model = browser.livingTree.model else { status = "The tree could not be read."; return }
        organic.load(model); structured.load(model)
        trail = browser.breadcrumbs
        status = "\(model.count) elements"
    }
    func up() async { if trail.count >= 2 { await go(trail[trail.count - 2]) } }
}

struct ShowcaseView: View {
    @ObservedObject var store: ShowcaseStore
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("View", selection: $store.mode) { ForEach(ShowcaseStore.Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                    .pickerStyle(.segmented).frame(width: 420).labelsHidden()
                Spacer()
                Text(store.status).font(.caption).foregroundStyle(.secondary)
            }.padding(10)
            Divider()
            if let browser = store.browser {
                let names = store.trail.map { $0.parentID == nil ? "Startup Data" : $0.name }
                let open: (Int) -> Void = { index in if store.trail.indices.contains(index) { Task { await store.go(store.trail[index]) } } }
                switch store.mode {
                case .current: LivingTreeView(browser: browser, explorer: browser.explorer, tree: browser.livingTree)
                case .organic: ProtoExplorerView(explorer: store.organic, trail: names, openTrail: open)
                case .structured: ProtoExplorerView(explorer: store.structured, trail: names, openTrail: open)
                }
            } else {
                Text(store.status).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task { await store.start() }
    }
}

@main struct LivingTreePrototypeShowcase: App {
    @StateObject private var store = ShowcaseStore()
    var body: some Scene {
        WindowGroup("Living Tree Prototypes") { ShowcaseView(store: store).frame(minWidth: 1100, minHeight: 700) }
    }
}
