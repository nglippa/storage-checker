import SwiftUI
import AppKit

/// QA-only navigation benchmark run inside a native window, without pointer, keyboard or accessibility input: each
/// step sets the same state its control sets. Enabled only for a QA database with `--perf-script` and `--perf-log`;
/// every step is logged by `PerformanceTrace` with its time to ready. The remembered visualization is restored at the end.
@MainActor final class PerformanceScript {
    static let shared = PerformanceScript()
    static var isEnabled: Bool { ViewerConfiguration.current.isQA && CommandLine.arguments.contains("--perf-script") && PerformanceTrace.isLogging }
    var setSection: ((String) -> Void)?
    private var started = false

    func start(store: ViewerStore, inventory: InventoryBrowserModel) {
        guard Self.isEnabled, !started else { return }
        started = true
        Task { await run(store: store, inventory: inventory) }
    }

    private func waitUntil(_ timeout: Double = 30, _ ready: () -> Bool) async -> Double? {
        let start = PerformanceTrace.now()
        while !ready() { if PerformanceTrace.now() - start > timeout { return nil }; try? await Task.sleep(for: .milliseconds(5)) }
        return PerformanceTrace.now() - start
    }

    private func run(store: ViewerStore, inventory: InventoryBrowserModel) async {
        let explorer = inventory.explorer
        let defaults = UserDefaults.standard, visualizationKey = "inventory.explorer.visualization"
        let savedVisualization = defaults.object(forKey: visualizationKey)
        func storageReady() -> Bool {
            guard !inventory.loading, inventory.status != nil, let directory = inventory.directory else { return false }
            return explorer.state.rootID == directory.id && explorer.mapReady(directory.id) && !explorer.state.loading.contains(directory.id)
        }
        func monitoringReady() -> Bool { store.snapshot != nil && !store.isLoading }
        func step(_ name: String, ready: () -> Bool, _ change: () -> Void) async {
            PerformanceTrace.mark("script.step", "\(name) begin active=\(NSApp.isActive)")
            change()
            let elapsed = await waitUntil(30, ready)
            PerformanceTrace.mark("script.step", elapsed.map { String(format: "%@ ready +%.0fms", name, $0 * 1000) } ?? "\(name) TIMEOUT")
            try? await Task.sleep(for: .seconds(2))
        }
        defaults.set("atlas", forKey: visualizationKey)
        if let elapsed = await waitUntil(120, { storageReady() && store.snapshot != nil }) { PerformanceTrace.mark("script.launchReady", String(format: "+%.0fms after script start", elapsed * 1000)) }
        try? await Task.sleep(for: .seconds(3))
        for _ in 0..<5 {
            await step("storage_to_monitoring", ready: monitoringReady) { setSection?("history") }
            await step("monitoring_to_storage", ready: storageReady) { setSection?("inventory") }
        }
        if let top = inventory.directory,
           let largest = (explorer.state.children[top.id]?.items ?? []).first(where: { $0.kind == .directory && $0.childCount > 0 }) {
            for _ in 0..<5 {
                await step("open_folder", ready: { storageReady() && inventory.directory?.id == largest.id }) { inventory.navigate(largest) }
                await step("parent_folder", ready: { storageReady() && inventory.directory?.id == top.id }) { inventory.navigate(top) }
            }
            let folders = (explorer.state.children[top.id]?.items ?? []).filter { $0.kind == .directory && $0.childCount > 0 }.prefix(4)
            explorer.requestNested(folders.map(\.id))
            _ = await waitUntil(20) { folders.prefix(3).allSatisfy { explorer.nested[$0.id] != nil } }
            for folder in folders.prefix(3) {
                guard let content = explorer.nested[folder.id], let item = content.page.items.first else { continue }
                await step("select_nested_tile", ready: { explorer.state.selection == item.id }) { explorer.select(item, through: [folder] + content.chain) }
            }
            for folder in folders {
                await step("select_folder_inspector_open", ready: { explorer.state.selection == folder.id }) { explorer.selection = folder.id }
            }
        }
        for _ in 0..<3 {
            await step("atlas_to_living_tree", ready: { storageReady() && inventory.livingTree.phase == .ready && inventory.livingTree.model?.root.id == inventory.directory?.id }) { defaults.set("tree", forKey: visualizationKey) }
            await step("living_tree_to_atlas", ready: storageReady) { defaults.set("atlas", forKey: visualizationKey) }
        }
        defaults.set("tree", forKey: visualizationKey)
        try? await Task.sleep(for: .seconds(2))
        for _ in 0..<3 {
            await step("storage_to_monitoring_tree", ready: monitoringReady) { setSection?("history") }
            await step("monitoring_to_storage_tree", ready: storageReady) { setSection?("inventory") }
        }
        if let savedVisualization { defaults.set(savedVisualization, forKey: visualizationKey) } else { defaults.removeObject(forKey: visualizationKey) }
        PerformanceTrace.mark("script.done")
    }
}
