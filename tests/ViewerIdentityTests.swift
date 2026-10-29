import Foundation

/// Release safeguards: production/QA identity, preference isolation, QA tooling activation, QA window identity and
/// release version metadata. `root` is the repository, so the build scripts and sources can be checked as written.
func viewerIdentityTests(root: URL, _ test: (Bool, String) throws -> Void) throws {
    func source(_ path: String) throws -> String { try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8) }

    // QA tooling activation matrix. A distribution build is modeled by compiledIn: false and is also compiled out.
    let flags = ["--database-path", "/x/catalog.sqlite3", "--perf-log", "/private/tmp/perf.log", "--perf-script"]
    let cases: [(compiledIn: Bool, isQA: Bool, arguments: [String], log: Bool, script: Bool, name: String)] = [
        (false, false, [], false, false, "release, production database, no arguments"),
        (false, false, flags, false, false, "release, production database, QA flags"),
        (false, true, flags, false, false, "release, QA database, QA flags"),
        (false, true, [], false, false, "release, QA database, no flags"),
        (true, false, flags, false, false, "development, production database, QA flags"),
        (true, true, [], false, false, "development, QA database, no flags"),
        (true, true, ["--perf-log", "relative.log", "--perf-script"], false, false, "development, QA database, relative log path"),
        (true, true, ["--perf-script"], false, false, "development, QA database, script without a log"),
        (true, true, flags, true, true, "authorized QA: QA database with explicit flags"),
    ]
    for c in cases {
        let log = ViewerIdentity.performanceLogPath(compiledIn: c.compiledIn, isQA: c.isQA, arguments: c.arguments) != nil
        let script = ViewerIdentity.performanceScriptEnabled(compiledIn: c.compiledIn, isQA: c.isQA, arguments: c.arguments)
        try test(log == c.log && script == c.script, "QA tooling activation: \(c.name) → log \(c.log), script \(c.script)")
    }
    try test(ViewerIdentity.performanceToolingCompiledIn, "QA tooling is compiled into development and test builds")
    let trace = try source("SourcesGUI/PerformanceTrace.swift"), script = try source("SourcesGUI/PerformanceScript.swift"), identity = try source("SourcesGUI/ViewerIdentity.swift")
    try test(trace.contains("#if STORAGE_MONITOR_DISTRIBUTION\n        return nil") && trace.contains("#if !STORAGE_MONITOR_DISTRIBUTION\n        guard output != nil")
             && trace.contains("#if !STORAGE_MONITOR_DISTRIBUTION\n        guard let output"),
             "distribution builds compile the timing log, its file output and the stall monitor out")
    try test(script.contains("#if STORAGE_MONITOR_DISTRIBUTION\n    func start(store: ViewerStore, inventory: InventoryBrowserModel) {}\n    #else"),
             "distribution builds keep only an inert scripted-navigation shell")
    try test(identity.components(separatedBy: "#if STORAGE_MONITOR_DISTRIBUTION").count == 4, "distribution builds compile the QA argument handling out")
    let dmg = try source("scripts/build-dmg.sh")
    try test(dmg.components(separatedBy: "swiftc -D STORAGE_MONITOR_DISTRIBUTION").count == 3, "release builds compile both binaries as distribution builds")

    // Identity and preference domains.
    try test(ViewerIdentity.preferencesSuite(isQA: true, nativeQA: false) == ViewerIdentity.qaPreferencesSuite
             && ViewerIdentity.preferencesSuite(isQA: false, nativeQA: false) == nil && ViewerIdentity.preferencesSuite(isQA: true, nativeQA: true) == nil,
             "a QA database keeps view preferences in the QA suite; production uses the app's own domain")
    try test(Set([ViewerIdentity.productionBundleIdentifier, ViewerIdentity.developmentBundleIdentifier, ViewerIdentity.qaPreferencesSuite]).count == 3
             && ViewerIdentity.productionBundleIdentifier == "local.macbook.storage-monitor.viewer",
             "production, development and QA preference domains are distinct; production keeps its identifier")
    let gui = try source("scripts/build-gui.sh"), install = try source("scripts/install-gui.sh")
    try test(gui.contains("BUNDLE_ID=local.macbook.storage-monitor.viewer.dev") && gui.contains("<string>$BUNDLE_ID</string>")
             && gui.contains("--identifier \"$BUNDLE_ID\"") && !gui.contains("<string>local.macbook.storage-monitor.viewer</string>"),
             "development builds use their own bundle and signing identifier")
    try test(dmg.contains("info local.macbook.storage-monitor.viewer \"Storage Monitor\"") && dmg.contains("sign \"$APP\" local.macbook.storage-monitor.viewer\n"),
             "release builds keep the production bundle and signing identifier")
    try test(install.contains("build/dist/work/Storage Monitor.app") && install.contains("!= local.macbook.storage-monitor.viewer ]"),
             "install-gui.sh installs only a bundle with the production identifier")
    var unrouted = [String](), standardWrites = [String]()
    for name in try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("SourcesGUI").path) where name.hasSuffix(".swift") {
        let text = try source("SourcesGUI/" + name)
        for line in text.components(separatedBy: "\n") {
            if line.contains("@AppStorage(") && !line.contains("store: ViewerStore.viewPreferences)") { unrouted.append(name) }
            if line.contains("UserDefaults.standard.set(") && name != "NativeQABootstrap.swift" { standardWrites.append(name) }
        }
    }
    try test(unrouted.isEmpty, "every @AppStorage preference uses the launch's preference domain (\(unrouted))")
    try test(standardWrites.isEmpty, "view code writes no preference directly to the app's standard domain (\(standardWrites))")
    let app = try source("SourcesGUI/StorageMonitorApp.swift")
    try test(app.contains("if NativeQARuntime.active != nil || ViewerConfiguration.current.isQA { window.isRestorable = false; window.disableSnapshotRestoration() }")
             && app.contains("else { window.setFrameAutosaveName(\"StorageMonitorMain\") }") && !app.contains("\"StorageMonitorQA\""),
             "QA windows save no frame or restoration state in the app's domain")

    // QA window identity.
    try test(ViewerIdentity.windowTitle(isQA: true, nativeQA: false, database: "/private/tmp/x/catalog.sqlite3") == "Storage Monitor — QA: catalog.sqlite3"
             && ViewerIdentity.windowTitle(isQA: false, nativeQA: false, database: "/Users/x/history.sqlite3") == "Storage Monitor"
             && ViewerIdentity.windowTitle(isQA: false, nativeQA: true, database: "/x").contains("Native QA"),
             "window titles mark QA and native QA databases and never mark production")
    let inventory = try source("SourcesGUI/InventoryView.swift"), history = try source("SourcesGUI/HistoryView.swift")
    try test(inventory.contains(".navigationTitle(store.configuration.windowTitle)") && !history.contains(".navigationTitle(")
             && app.contains("window.title = ViewerConfiguration.current.windowTitle"),
             "the QA title is set once for both sections and for the window itself")

    // Release version metadata: one source, and the build number never goes back.
    let version = try source("scripts/version.env")
    func value(_ key: String) -> String? { version.components(separatedBy: "\n").first { $0.hasPrefix(key + "=") }.map { String($0.dropFirst(key.count + 1)) } }
    try test(value("STORAGE_MONITOR_RELEASE_VERSION") == "2.1.0" && (Int(value("STORAGE_MONITOR_RELEASE_BUILD") ?? "") ?? 0) > 8,
             "the release is 2.1.0 with a build number above every earlier build (2.0.0 was 8, the 2.1.0 test DMG 1)")
    for path in ["scripts/build.sh", "scripts/build-gui.sh", "scripts/build-dmg.sh"] {
        let text = try source(path)
        try test(text.contains(". \"$ROOT/scripts/version.env\"") && text.contains("${STORAGE_MONITOR_VERSION:-$STORAGE_MONITOR_RELEASE_VERSION}")
                 && text.contains("${STORAGE_MONITOR_BUILD:-$STORAGE_MONITOR_RELEASE_BUILD}") && !text.contains("<string>1.0.0</string>"),
                 "\(path) stamps the version from scripts/version.env")
    }
}
