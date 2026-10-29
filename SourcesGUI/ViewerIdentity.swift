import Foundation

/// Which application identity and preference domain this viewer uses, and which QA-only tools it may run.
///
/// Production (`local.macbook.storage-monitor.viewer`, built only by scripts/build-dmg.sh) keeps the installed app's
/// identity, preferences and data. Development builds (scripts/build-gui.sh) use their own bundle identifier, so their
/// preferences, saved window state and caches never belong to the installed app. Independently of the bundle, a
/// viewer reading a QA database keeps every view preference in the QA suite and saves no window state.
enum ViewerIdentity {
    static let productionBundleIdentifier = "local.macbook.storage-monitor.viewer"
    static let developmentBundleIdentifier = "local.macbook.storage-monitor.viewer.dev"
    static let qaPreferencesSuite = "local.macbook.storage-monitor.viewer.qa"

    /// True when this binary was compiled with QA performance tooling (every build except distribution builds).
    static let performanceToolingCompiledIn: Bool = {
        #if STORAGE_MONITOR_DISTRIBUTION
        return false
        #else
        return true
        #endif
    }()

    /// The `--perf-log` path, when the timing log may be written: compiled in, a QA database, an absolute path.
    /// Distribution builds compile the argument handling out entirely, so no argument can reach it.
    static func performanceLogPath(compiledIn: Bool, isQA: Bool, arguments: [String]) -> String? {
        #if STORAGE_MONITOR_DISTRIBUTION
        return nil
        #else
        guard compiledIn, isQA, let i = arguments.firstIndex(of: "--perf-log"), arguments.count > i + 1, arguments[i + 1].hasPrefix("/") else { return nil }
        return arguments[i + 1]
        #endif
    }

    /// Scripted navigation also needs `--perf-script` and a timing log to report to.
    static func performanceScriptEnabled(compiledIn: Bool, isQA: Bool, arguments: [String]) -> Bool {
        #if STORAGE_MONITOR_DISTRIBUTION
        return false
        #else
        return performanceLogPath(compiledIn: compiledIn, isQA: isQA, arguments: arguments) != nil && arguments.contains("--perf-script")
        #endif
    }

    /// The main window's title. QA windows always name their database, in every section.
    static func windowTitle(isQA: Bool, nativeQA: Bool, database: String) -> String {
        if nativeQA { return "Storage Monitor — Native QA — Disposable Fixtures" }
        return isQA ? "Storage Monitor — QA: \(URL(fileURLWithPath: database).lastPathComponent)" : "Storage Monitor"
    }

    /// The domain for persisted view preferences: the QA suite for a QA database, otherwise the app's own domain.
    /// (The strict native QA runtime has its own bundle identifier and verifies its own domain.)
    static func preferencesSuite(isQA: Bool, nativeQA: Bool) -> String? {
        nativeQA || !isQA ? nil : qaPreferencesSuite
    }
}
