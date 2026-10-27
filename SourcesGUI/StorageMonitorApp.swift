import SwiftUI
import AppKit


struct ViewerConfiguration {
    let database: String
    let appearance: String?
    let windowSize: CGSize?
    let isQA: Bool
    let readinessOutput: String?
    static let current: Self = {
        if let runtime = NativeQARuntime.active { return Self(database: runtime.database, appearance: nil, windowSize: nil, isQA: true, readinessOutput: runtime.readiness) }
        let args = CommandLine.arguments
        func value(_ key: String) -> String? { guard let i = args.firstIndex(of: key), args.count > i+1 else { return nil }; return args[i+1] }
        let qaBundle = Bundle.main.bundleIdentifier == "local.macbook.storage-monitor.viewer.inventory-qa"
        let override = value("--database-path") ?? (qaBundle ? Bundle.main.object(forInfoDictionaryKey: "StorageMonitorQADatabasePath") as? String : nil)
        let dimensions = value("--window-size")?.split(separator: "x").compactMap { Double($0) }
        let size: CGSize? = dimensions?.count == 2 ? CGSize(width: max(780,dimensions![0]), height: max(620,dimensions![1])) : nil
        let qa = override != nil
        let readiness = value("--readiness-output").flatMap { qa && $0.hasPrefix("/") ? $0 : nil }
        return Self(database: override ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/MacBook Storage Monitor/history.sqlite3").path, appearance: value("--appearance"), windowSize: size, isQA: qa, readinessOutput: readiness)
    }()
}

@MainActor final class ViewerReadiness {
    private let started = ProcessInfo.processInfo.systemUptime
    private let startedWall = Date().timeIntervalSince1970
    private let output: String?
    private var milestones = [String: Double]()
    private var pageLoads = [Double]()
    private var pageLoadCount = 0

    init(output: String?) {
        self.output = output
        mark("launch")
    }

    func mark(_ name: String) {
        guard milestones[name] == nil else { return }
        milestones[name] = max(0, ProcessInfo.processInfo.systemUptime - started)
        persist()
    }
    func inventoryPageLoaded() {
        guard output != nil else { return }
        pageLoadCount += 1
        if pageLoads.count == 16 { pageLoads.removeFirst() }
        pageLoads.append(ProcessInfo.processInfo.systemUptime - started)
        persist()
    }
    private func persist() {
        guard let output else { return }
        var payload: [String: Any] = ["scope": "model/data readiness; native rendering and interaction require separate verification", "model_started_at_unix": startedWall, "elapsed_seconds": milestones, "inventory_page_load_count": pageLoadCount, "inventory_page_load_seconds_last_16": pageLoads]
        if let runtime = NativeQARuntime.active { payload["qa_runtime"] = runtime.destinations(); payload["pid"] = getpid() }
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]) else { return }
        try? data.write(to: URL(fileURLWithPath: output), options: .atomic)
    }
}

@MainActor final class ViewerStore: ObservableObject {
    @Published private(set) var snapshot: HistorySnapshot?
    @Published private(set) var visibleEvents = [StorageEvent]()
    @Published private(set) var isLoading = false
    @Published private(set) var error: String?
    @Published private(set) var historyMissing = false
    @Published var selection: String?
    @Published var showInspector = false
    @Published var filters: EventFilters { didSet { persist(); applyFilters() } }
    @Published var chartRange: EventTimeFilter = .day { didSet { preferences.set(chartRange.rawValue,forKey:"chartRange") } }
    // Viewer-only appearance; the system-wide setting is never changed.
    @Published var appearance: AppAppearance = .system { didSet { if configuration.appearance == nil { appearance.save(preferences) }; applyAppearance() } }
    @Published private(set) var inventoryRefreshTick = 0
    let live = LiveCapacityMonitor()
    let configuration: ViewerConfiguration
    let readiness: ViewerReadiness
    private let reader: HistoryReader
    private let preferences: UserDefaults
    private var loop: Task<Void,Never>?
    private var refreshTask: Task<Void,Never>?
    private var inventoryVisible = false
    private var inventoryBusy = true
    private var lastInventoryRefresh = Date.distantPast
    private var lastHistoryRefresh: Date?
    var selectedEvent: StorageEvent? { snapshot?.events.first { $0.id == selection } }
    var hasActiveFilters: Bool { filters.activeCount > 0 || filters.sort != .newest }
    init(configuration: ViewerConfiguration = .current) {
        self.configuration = configuration
        preferences = Self.preferences(for: configuration)
        var restored = preferences.data(forKey:"filters").flatMap { try? JSONDecoder().decode(EventFilters.self,from:$0) } ?? EventFilters()
        restored.start = minuteBoundary(restored.start); restored.end = minuteBoundary(restored.end)
        filters = restored
        if let value = preferences.string(forKey:"chartRange"), let range = EventTimeFilter(rawValue:value), range != .custom { chartRange = range }
        reader = HistoryReader(path: configuration.database)
        readiness = ViewerReadiness(output: configuration.readinessOutput)
        appearance = AppAppearance.load(preferences, override: configuration.appearance)
    }
    nonisolated static func preferences(for configuration: ViewerConfiguration) -> UserDefaults {
        if NativeQARuntime.active != nil { return .standard }
        return configuration.isQA ? UserDefaults(suiteName: "local.macbook.storage-monitor.viewer.qa")! : .standard
    }
    func applyAppearance() { Self.apply(appearance) }
    static func apply(_ appearance: AppAppearance) {
        let target: NSAppearance? = appearance == .system ? nil : NSAppearance(named: appearance == .dark ? .darkAqua : .aqua)
        NSApp?.appearance = target   // nil follows macOS, including later changes
        // Windows inherit from the app. Clearing any window-level appearance matters when
        // returning to System: a pinned window would otherwise stay Light or Dark.
        for window in NSApp?.windows ?? [] { window.appearance = nil }
    }
    // Live capacity only: read-only, never stored, never alerts.
    func refreshLive() {
        Task {
            _ = await live.refresh()
            if live.state.reading != nil { readiness.mark("live_capacity_ready") }
        }
    }
    func refreshAll() {
        refresh(); refreshLive()
        if inventoryVisible { inventoryRefreshTick &+= 1; lastInventoryRefresh = Date() }
    }
    func setInventoryBusy(_ busy: Bool) { inventoryBusy = busy }
    func setInventoryVisible(_ visible: Bool) {
        inventoryVisible = visible
        if visible { inventoryRefreshTick &+= 1 }
    }
    private func persist() { if let data = try? JSONEncoder().encode(filters) { preferences.set(data,forKey:"filters") } }
    private func applyFilters() {
        visibleEvents = filters.apply(snapshot?.events ?? [])
        if let selection, !visibleEvents.contains(where: { $0.id == selection }) { self.selection = nil }
    }
    func clearFilters() { filters = EventFilters() }
    func refresh() {
        guard refreshTask == nil else { return }
        lastHistoryRefresh = Date()
        isLoading = true
        refreshTask = Task {
            do {
                let value = try await reader.load()
                guard !Task.isCancelled else { return }
                snapshot = value; error = nil; historyMissing = false; applyFilters(); readiness.mark("history_ready")
                // QA-only: preselect an event so captures show the inspector.
                if configuration.isQA, selection == nil, let i = CommandLine.arguments.firstIndex(of: "--select-event"), CommandLine.arguments.count > i+1 {
                    selection = CommandLine.arguments[i+1]; showInspector = true
                }
            } catch { self.error = error.localizedDescription; historyMissing = (error as? HistoryError)?.isMissingHistory == true }
            isLoading = false; refreshTask = nil
        }
    }
    func start() {
        if let runtime = NativeQARuntime.active { NativeQAWorker.shared.start(runtime) }
        guard loop == nil else { return }
        applyAppearance()
        refreshAll()
        loop = Task {
            while !Task.isCancelled {
                do { try await Task.sleep(for:.seconds(2)) } catch { break }
                guard NSApp.isActive && NSApp.windows.contains(where: { $0.isVisible && !($0 is NSPanel) }) else { continue }
                if inventoryVisible && (inventoryBusy || Date().timeIntervalSince(lastInventoryRefresh) >= 30) {
                    inventoryRefreshTick &+= 1; lastInventoryRefresh = Date()
                }
                if lastHistoryRefresh.map({ Date().timeIntervalSince($0) >= 30 }) ?? true { refresh() }
                if live.isDue(at: Date()) { refreshLive() }
            }
        }
    }
    func stop() { loop?.cancel(); loop = nil; if NativeQARuntime.active != nil { NativeQAWorker.shared.stopAndWait() } }
}

final class ViewerAppDelegate: NSObject, NSApplicationDelegate {
    var reopen: (() -> Void)?
    func applicationWillTerminate(_ notification: Notification) { if NativeQARuntime.active != nil { NativeQAWorker.shared.stopAndWait() } }
    static let launchedAt = Date()
    // Apply the saved appearance before any window is created.
    func applicationWillFinishLaunching(_ notification: Notification) {
        _ = Self.launchedAt
        let configuration = ViewerConfiguration.current
        if NativeQARuntime.active != nil { NSApp.disableRelaunchOnLogin() }
        MainActor.assumeIsolated { ViewerStore.apply(AppAppearance.load(ViewerStore.preferences(for: configuration), override: configuration.appearance)) }
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps:true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { if !flag { reopen?() }; return true }
}

@main struct StorageMonitorViewerApp: App {
    var body: some Scene { StorageMonitorApplication().body }
    static func main() {
        do {
            let runtime = try NativeQABootstrap.prepare()
            if CommandLine.arguments.contains("--qa-verify-only") {
                guard let runtime else { try NativeQARuntime.reject("verification requires explicit QA activation") }
                try NativeQABootstrap.verifyOnly(runtime); return
            }
            if let runtime { try NativeQABootstrap.redirectLogs(runtime) }
            StorageMonitorApplication.main()
        } catch { fputs("\(error)\n", stderr); exit(78) }
    }
}

struct StorageMonitorApplication: App {
    @NSApplicationDelegateAdaptor(ViewerAppDelegate.self) private var delegate
    @StateObject private var store = ViewerStore()
    @Environment(\.openWindow) private var openWindow
    var body: some Scene {
        Settings { AppearanceSettings(store:store) }
        Window("Storage Monitor",id:"main") {
            // Top-aligned and bounded by the window: content taller than the window must never be centred
            // under the title bar and toolbar (D6). The minimum content height holds the whole layout.
            MonitorRootView(store:store)
                .frame(minWidth:780,maxWidth:.infinity,minHeight:640,maxHeight:.infinity,alignment:.top)
                .background(WindowSetup())
                .onAppear { delegate.reopen = { openWindow(id:"main") }; store.start() }
                .onDisappear { store.stop() }
                .onReceive(NotificationCenter.default.publisher(for:NSApplication.didBecomeActiveNotification)) { _ in store.refreshAll() }
        }
        .defaultSize(width:1240,height:820)
        .windowStyle(.titleBar)
        .commands {
            CommandGroup(replacing:.newItem) { Button("Show Storage Monitor") { openWindow(id:"main") }.keyboardShortcut("0") }
            CommandGroup(after:.toolbar) {
                Button("Refresh") { store.refreshAll() }.keyboardShortcut("r")
                Picker("Appearance",selection:$store.appearance) { ForEach(AppAppearance.allCases) { Text($0.title).tag($0) } }
                Toggle("Show Event Details",isOn:$store.showInspector).keyboardShortcut("i",modifiers:[.command,.option])
            }
        }
    }
}

private struct WindowSetup: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { WindowView() }
    func updateNSView(_ nsView: NSView,context: Context) {}
    final class WindowView: NSView {
        static var signalSource: DispatchSourceSignal?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            if NativeQARuntime.active != nil { window.isRestorable = false; window.disableSnapshotRestoration() }
            else { window.setFrameAutosaveName(ViewerConfiguration.current.isQA ? "StorageMonitorQA" : "StorageMonitorMain") }
            window.minSize = NSSize(width:780,height:700)   // frame size: about 640 pt of content below the toolbar
            if let size = ViewerConfiguration.current.windowSize { window.setContentSize(size) }
            if NativeQARuntime.active != nil { window.title = "Storage Monitor — Native QA — Disposable Fixtures" }
            else if ViewerConfiguration.current.isQA { window.title = "Storage Monitor — QA: \(URL(fileURLWithPath:ViewerConfiguration.current.database).lastPathComponent)" }
            // QA-only capture of the actual rendered native content. This is
            // independent of WindowServer's animated/minimized screenshot state.
            let args = CommandLine.arguments
            if ViewerConfiguration.current.isQA, let index = args.firstIndex(of:"--capture-window-path"), args.count > index+1 {
                let path = args[index+1]
                func capture(_ destination: String) {
                    guard let view = window.contentView, let bitmap = view.bitmapImageRepForCachingDisplay(in:view.bounds) else { return }
                    window.effectiveAppearance.performAsCurrentDrawingAppearance { view.cacheDisplay(in:view.bounds,to:bitmap) }
                    if let png = bitmap.representation(using:.png,properties:[:]) { try? png.write(to:URL(fileURLWithPath:destination),options:.atomic) }
                }
                DispatchQueue.main.asyncAfter(deadline:.now()+4) { capture(path) }
                // QA only: SIGUSR1 captures the current state again (path-1.png, path-2.png, …).
                signal(SIGUSR1, SIG_IGN)
                let source = DispatchSource.makeSignalSource(signal:SIGUSR1,queue:.main)
                var count = 0
                source.setEventHandler { count += 1; capture(path.replacingOccurrences(of:".png",with:"-\(count).png")) }
                source.resume()
                WindowView.signalSource = source
            }
        }
    }
}

private struct AppearanceSettings: View {
    @ObservedObject var store: ViewerStore
    @Environment(\.openWindow) private var openWindow
    private static func monitoringState() -> MonitoringSetupStatus {
        if let runtime = NativeQARuntime.active { return MonitoringSetupStatus(state: .off, summary: "QA fixture worker only. Production background monitoring is unavailable in this session.", installedVersion: nil, bundledVersion: nil, helperExecutable: nil, installedApp: URL(fileURLWithPath: runtime.root + "/no-installed-app")) }
        return MonitoringSetupStatus.evaluate(home: FileManager.default.homeDirectoryForCurrentUser, bundledHelper: MonitoringSetupStatus.bundledHelper(in: Bundle.main.bundleURL), launchd: LaunchdState.current())
    }
    @State private var monitoring = Self.monitoringState()
    @State private var pending: MonitoringSetupAction?
    @State private var working = false
    @State private var result: String?
    private func refreshMonitoring() {
        monitoring = Self.monitoringState()
    }
    private func perform(_ action: MonitoringSetupAction) {
        guard NativeQARuntime.active == nil else { return }
        guard let helper = monitoring.helperExecutable else { return }
        working = true; result = nil
        Task {
            let outcome = await action.run(helper: helper)
            working = false; result = outcome.ok ? outcome.output : "Could not complete: \(outcome.output)"
            refreshMonitoring()
        }
    }
    // QA/development configurations never change the person's real LaunchAgents.
    private var actionsAllowed: Bool { !store.configuration.isQA && monitoring.helperExecutable != nil && !working }
    var body: some View {
        Form {
            Section {
                Picker("Appearance",selection:$store.appearance) { ForEach(AppAppearance.allCases) { Text($0.title).tag($0) } }
                    .pickerStyle(.radioGroup)
                    .accessibilityIdentifier("settings.appearance")
                Text("Applies to Storage Monitor only. System follows your Mac's appearance.").font(.subheadline).foregroundStyle(.secondary)
                    .fixedSize(horizontal:false,vertical:true)
            }
            Section("Background Monitoring") {
                Text(monitoring.summary).fixedSize(horizontal:false,vertical:true).accessibilityIdentifier("settings.monitoring.status")
                HStack {
                    switch monitoring.state {
                    case .off: Button("Enable Background Monitoring…") { pending = .enable }
                    case .needsUpdate: Button("Update Background Monitor…") { pending = .enable }; Button("Disable…") { pending = .disable }
                    case .incomplete: Button("Repair…") { pending = .enable }; Button("Disable…") { pending = .disable }
                    case .on:
                        Button("Disable…") { pending = .disable }
                        // macOS prompts only while the choice is undecided; otherwise its settings decide.
                        if monitoring.notifications.canPrompt { Button("Allow Low-Space Notifications…") { perform(.notifications) } }
                        else { Button("Notification Settings…") { if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") { NSWorkspace.shared.open(url) } } }
                    }
                    if working { ProgressView().controlSize(.small) }
                }.disabled(!actionsAllowed).accessibilityIdentifier("settings.monitoring.actions")
                if store.configuration.isQA {
                    Text("Disabled in QA builds, which never change your real background tasks.").font(.caption).foregroundStyle(.secondary)
                } else if monitoring.helperExecutable == nil {
                    Text("This build does not include the background monitor. Install Storage Monitor from its disk image to manage monitoring here.").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
                }
                if monitoring.state == .on {
                    Text(monitoring.notifications.text).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true).accessibilityIdentifier("settings.monitoring.notifications")
                }
                if let result { Text(result).font(.caption).foregroundStyle(.secondary).textSelection(.enabled).fixedSize(horizontal:false,vertical:true).accessibilityIdentifier("settings.monitoring.result") }
            }
            Section("Privacy") {
                Text(MonitoringSetupStatus.permissions).font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
                Button("Open Full Disk Access Settings…") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") { NSWorkspace.shared.open(url) }
                }.disabled(NativeQARuntime.active != nil).accessibilityIdentifier("settings.privacy.fullDiskAccess")
            }
        }
        .formStyle(.grouped)
        .frame(width:480)
        .onAppear {
            refreshMonitoring()
            if NativeQARuntime.active != nil { for window in NSApp.windows { window.isRestorable = false; window.disableSnapshotRestoration() } }
        }
        .alert(pending == .disable ? "Disable background monitoring?" : (monitoring.state == .off ? "Enable background monitoring?" : "Update background monitoring?"),
               isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } })) {
            Button(pending == .disable ? "Disable" : (monitoring.state == .off ? "Enable" : "Update")) { if let action = pending { perform(action) }; pending = nil }
            Button("Cancel", role: .cancel) { pending = nil }
        } message: {
            Text(pending == .disable ? MonitoringSetupStatus.disableConfirmation : MonitoringSetupStatus.consent)
        }
        // macOS can restore Settings alone at launch; the history window must always be available.
        .onAppear {
            let hasMain = NSApp.windows.contains { $0.identifier?.rawValue.hasPrefix("main") == true || ($0.title.hasPrefix("Storage Monitor") && !$0.title.contains("Settings")) }
            if !hasMain { openWindow(id:"main") }
            // Settings shown within moments of launch was restored by macOS, not opened
            // by the person: show the history window instead.
            if Date().timeIntervalSince(ViewerAppDelegate.launchedAt) < 3 {
                DispatchQueue.main.async { for window in NSApp.windows where window.title.contains("Settings") { window.isRestorable = false; window.close() } }
            }
        }
    }
}

