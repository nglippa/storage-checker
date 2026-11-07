// Headless preference-isolation probe. Built from the real viewer sources (only @main removed) inside an app bundle
// whose identifier is chosen per run. It never creates a window or activates (activation policy .prohibited).
// write: changes the persisted V2 view settings through the same @AppStorage bindings the views use.
// read:  prints them, so a relaunch shows what persisted and where.
import SwiftUI
import AppKit

@main struct PreferenceProbe {
    @MainActor static func main() {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let mode = CommandLine.arguments.contains("--probe-write") ? "write" : "read"
        let store = ViewerStore.viewPreferences
        var visualization = AppStorage(wrappedValue: InventoryVisualization.atlas, "inventory.explorer.visualization", store: store)
        var navigator = AppStorage(wrappedValue: false, "inventory.explorer.treeNavigatorExpanded", store: store)
        var evidence = AppStorage(wrappedValue: false, "event.showEvidence", store: store)
        var dimension = AppStorage(wrappedValue: LivingTreeDimension.flat.rawValue, "inventory.livingTree.dimension", store: store)
        if mode == "write" {
            visualization.wrappedValue = .tree; navigator.wrappedValue = true; evidence.wrappedValue = true; dimension.wrappedValue = LivingTreeDimension.depth.rawValue
            store.synchronize()
        }
        let result: [String: Any] = [
            "mode": mode, "bundle": Bundle.main.bundleIdentifier ?? "", "isQA": ViewerConfiguration.current.isQA,
            "uses_standard_domain": store === UserDefaults.standard, "window_title": ViewerConfiguration.current.windowTitle,
            "visualization": visualization.wrappedValue.rawValue, "treeNavigatorExpanded": navigator.wrappedValue,
            "showEvidence": evidence.wrappedValue, "dimension": dimension.wrappedValue,
            "perf_log_honored": ViewerIdentity.performanceLogPath(compiledIn: ViewerIdentity.performanceToolingCompiledIn, isQA: ViewerConfiguration.current.isQA, arguments: CommandLine.arguments) != nil,
            "perf_script_enabled": ViewerIdentity.performanceScriptEnabled(compiledIn: ViewerIdentity.performanceToolingCompiledIn, isQA: ViewerConfiguration.current.isQA, arguments: CommandLine.arguments),
            "trace_logging": PerformanceTrace.isLogging, "tooling_compiled_in": ViewerIdentity.performanceToolingCompiledIn,
        ]
        let data = try! JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
        print(String(decoding: data, as: UTF8.self))
    }
}
