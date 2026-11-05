import SwiftUI
import AppKit


struct ViewerConfiguration {
    let database: String
    let appearance: String?
    let windowSize: CGSize?
    let isQA: Bool
    let readinessOutput: String?
    var windowTitle: String {
        if LifecycleQAScope.active != nil { return "Storage Monitor — Lifecycle QA — Disposable Fixtures" }
        return ViewerIdentity.windowTitle(isQA: isQA, nativeQA: NativeQARuntime.active != nil, database: database)
    }
    static let current: Self = {
        if let scope = LifecycleQAScope.active { return Self(database: scope.database, appearance: nil, windowSize: nil, isQA: true, readinessOutput: nil) }
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
    @Published private(set) var monitoring: MonitoringSetupStatus?
    @Published private(set) var lastWake: Date?
    /// When the saved inventory pause marker was written; nil when indexing is not paused.
    @Published private(set) var inventoryPausedSince: Date?
    /// Set by the Storage screen's Enable Monitoring button so Settings opens straight to the consent prompt.
    @Published var enableMonitoringRequested = false
    private var healthEvidence = MonitoringHealthEvidence()
    private var inventoryHealthEvidence: InventoryWorkerEvidence?
    private var monitoringTask: Task<Void, Never>?
    private var lastMonitoringRefresh: Date?
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
        if LifecycleQAScope.active != nil { return .standard }
        guard let suite = ViewerIdentity.preferencesSuite(isQA: configuration.isQA, nativeQA: NativeQARuntime.active != nil) else { return .standard }
        return UserDefaults(suiteName: suite)!
    }
    /// Where every persisted view preference (`@AppStorage` included) is kept for this launch.
    nonisolated(unsafe) static let viewPreferences = preferences(for: .current)  // UserDefaults is thread-safe
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
    func refreshMonitoring() {
        guard monitoringTask == nil else { return }
        lastMonitoringRefresh = Date()
        let configuration = self.configuration
        monitoringTask = Task {
            let status = await Task.detached(priority: .utility) {
                if let scope = LifecycleQAScope.active {
                    do {
                        try scope.validateStorage()
                        return MonitoringSetupStatus.evaluate(home: scope.home, bundledHelper: scope.bundle("Installer"), launchd: LaunchdState.current(), labels: scope.labels)
                    } catch {
                        var status = MonitoringSetupStatus(state: .incomplete, summary: "Disposable lifecycle scope needs attention: \(error)", installedVersion: nil, bundledVersion: nil, helperExecutable: nil, installedApp: scope.app)
                        status.jobLabels = scope.labels; return status
                    }
                }
                if configuration.isQA {
                    return MonitoringSetupStatus(state: .off, summary: "QA fixture worker only. Production background monitoring is unavailable in this session.", installedVersion: nil, bundledVersion: nil, helperExecutable: nil, installedApp: URL(fileURLWithPath: "/private/tmp/no-installed-monitor"))
                }
                return MonitoringSetupStatus.evaluate(home: FileManager.default.homeDirectoryForCurrentUser, bundledHelper: MonitoringSetupStatus.bundledHelper(in: Bundle.main.bundleURL), launchd: LaunchdState.current())
            }.value
            if !configuration.isQA || LifecycleQAScope.active != nil {
                let observed = await Task.detached(priority: .utility) {
                    InventoryWorkerEvidence.read(directory: URL(fileURLWithPath: configuration.database).deletingLastPathComponent(), now: Date())
                }.value
                inventoryHealthEvidence = InventoryWorkerEvidence.retainingFailure(inventoryHealthEvidence, observed: observed)
            }
            inventoryPausedSince = await Task.detached(priority: .utility) {
                let marker = URL(fileURLWithPath: configuration.database).deletingLastPathComponent().appendingPathComponent("inventory.cancel").path
                return (try? FileManager.default.attributesOfItem(atPath: marker))?[.modificationDate] as? Date
            }.value
            healthEvidence.observe(status.launchd, at: Date(), labels: status.jobLabels)
            monitoring = status
            monitoringTask = nil
        }
    }
    func monitoringHealth(at now: Date) -> MonitoringHealthPresentation {
        MonitoringHealthPresentation(setup: monitoring, lastSuccess: snapshot?.latest?.timestamp, evidence: healthEvidence, lastWake: lastWake, inventory: inventoryHealthEvidence, inventoryPausedSince: inventoryPausedSince, now: now)
    }
    var inventoryEvidence: InventoryWorkerEvidence? { inventoryHealthEvidence }
    /// The same request the Storage screen's Resume Indexing sends: the worker clears the saved pause and continues.
    func resumeIndexing() async -> String {
        let database = configuration.database
        do {
            _ = try await Task.detached(priority: .utility) { try InventoryRequests.enqueue(database: database, action: "resume", path: nil) }.value
            refreshMonitoring()
            return "Resume requested. Disk indexing continues in the next background run, usually within a few minutes."
        } catch { return "Couldn't resume indexing: \(error.localizedDescription)" }
    }
    var inventoryFailure: String? {
        if let monitoring { return monitoring.inventoryFailure(inventoryHealthEvidence) }
        return inventoryHealthEvidence?.failureDescription
    }
    func woke() { lastWake = Date(); refreshAll() }
    func refreshAll() {
        refresh(); refreshLive(); refreshMonitoring()
        if inventoryVisible { inventoryRefreshTick &+= 1; lastInventoryRefresh = Date() }
    }
    func setInventoryBusy(_ busy: Bool) { inventoryBusy = busy }
    /// Becoming visible needs no extra refresh: the inventory view reads the catalog as it appears. A tick here
    /// queued a second and third full read behind that one on every return to Storage.
    func setInventoryVisible(_ visible: Bool) {
        inventoryVisible = visible
        if visible { lastInventoryRefresh = Date() }
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
                let value = try await PerformanceTrace.measure("history.load") { try await reader.load() }
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
        PerformanceTrace.startStallMonitor()
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
                if lastMonitoringRefresh.map({ Date().timeIntervalSince($0) >= 30 }) ?? true { refreshMonitoring() }
            }
        }
    }
    func stop() { loop?.cancel(); loop = nil; if NativeQARuntime.active != nil { NativeQAWorker.shared.stopAndWait() } }
}

final class ViewerAppDelegate: NSObject, NSApplicationDelegate {
    var reopen: (() -> Void)?
    func applicationWillTerminate(_ notification: Notification) { if NativeQARuntime.active != nil { NativeQAWorker.shared.stopAndWait() } }
    // Apply the saved appearance before any window is created.
    func applicationWillFinishLaunching(_ notification: Notification) {
        let configuration = ViewerConfiguration.current
        if NativeQARuntime.active != nil || LifecycleQAScope.active != nil { NSApp.disableRelaunchOnLogin() }
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
            try NativeQABootstrap.prepareLifecycle()
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
        Window("Storage Monitor",id:"main") {
            // Top-aligned and bounded by the window: content taller than the window must never be centred
            // under the title bar and toolbar (D6). The minimum content height holds the whole layout.
            MonitorRootView(store:store)
                .frame(minWidth:1000,maxWidth:.infinity,minHeight:640,maxHeight:.infinity,alignment:.top)
                .background(WindowSetup())
                .onAppear { delegate.reopen = { openWindow(id:"main") }; store.start() }
                .onDisappear { store.stop() }
                .onReceive(NotificationCenter.default.publisher(for:NSApplication.didBecomeActiveNotification)) { _ in store.refreshAll() }
                .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)) { _ in store.woke() }
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
        Settings { AppearanceSettings(store:store) }
    }
}

private struct WindowSetup: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { WindowView() }
    func updateNSView(_ nsView: NSView,context: Context) {}
    final class WindowView: NSView {
        static var signalSource: DispatchSourceSignal?
        private var interactionMonitor: Any?
        private var responderObservation: NSKeyValueObservation?
        private var keyObserver: NSObjectProtocol?
        private var releasingAutomaticFocus = false
        private weak var armedWindow: NSWindow?
        /// AppKit makes the first text field (a search field) first responder when the window opens, so typing meant
        /// for another app lands in it as the window comes forward. Until the person's first deliberate interaction in
        /// this window (a click, a ⌘ shortcut or Tab), any automatic move of focus into a text field is undone as it
        /// happens. The event monitor is local to this app and returns every event unchanged; all observers stop after
        /// that first interaction, so a click into Search works at once and nothing changes later.
        func releaseInitialTextFocus(_ window: NSWindow) {
            // Armed once per window: moving into the same window again must not re-arm it after the person's first
            // interaction, nor leave an earlier monitor installed.
            guard window !== armedWindow else { return }
            stopReleasingAutomaticFocus()
            armedWindow = window
            releasingAutomaticFocus = true
            interactionMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown]) { [weak self, weak window] event in
                let deliberate = event.type != .keyDown || event.modifierFlags.contains(.command) || event.keyCode == 48 // Tab
                if let window, event.window === window, deliberate { self?.stopReleasingAutomaticFocus() }
                return event
            }
            responderObservation = window.observe(\.firstResponder, options: [.new]) { [weak self] window, _ in
                DispatchQueue.main.async { self?.releaseAutomaticFocus(window) }
            }
            keyObserver = NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main) { [weak self, weak window] _ in
                guard let window else { return }
                DispatchQueue.main.async { self?.releaseAutomaticFocus(window) }
            }
            releaseAutomaticFocus(window)
        }
        private func releaseAutomaticFocus(_ window: NSWindow) {
            guard releasingAutomaticFocus, let editor = window.firstResponder as? NSTextView, editor.isFieldEditor else { return }
            window.makeFirstResponder(nil)
        }
        private func stopReleasingAutomaticFocus() {
            releasingAutomaticFocus = false
            if let monitor = interactionMonitor { NSEvent.removeMonitor(monitor) }
            if let observer = keyObserver { NotificationCenter.default.removeObserver(observer) }
            interactionMonitor = nil; keyObserver = nil; responderObservation = nil
        }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            // QA windows save no frame or restoration state: those live in the app's own domain, which a QA database
            // read by a production build must not change.
            if NativeQARuntime.active != nil || ViewerConfiguration.current.isQA { window.isRestorable = false; window.disableSnapshotRestoration() }
            else { window.setFrameAutosaveName("StorageMonitorMain") }
            window.minSize = NSSize(width:1000,height:700)   // frame size: about 640 pt of content below the toolbar
            releaseInitialTextFocus(window)
            if let size = ViewerConfiguration.current.windowSize { window.setContentSize(size) }
            window.title = ViewerConfiguration.current.windowTitle
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
    @State private var pending: MonitoringSetupAction?
    @State private var working = false
    @State private var result: String?
    @State private var resultDetail: String?
    @State private var showResultDetail = false
    @State private var showTechnical = false
    @ViewState private var showPrivacyDetails = false
    private var monitoring: MonitoringSetupStatus? { store.monitoring }
    private func refreshMonitoring() { store.refreshMonitoring() }
    private func perform(_ action: MonitoringSetupAction) {
        guard NativeQARuntime.active == nil else { return }
        guard let helper = monitoring?.helperExecutable else { return }
        working = true; result = nil; resultDetail = nil
        Task {
            let outcome = await action.run(helper: helper, scope: LifecycleQAScope.active)
            working = false
            // Helper output is technical: success shows it plainly; a failure leads with a sentence and folds the output away.
            if outcome.ok { result = outcome.output }
            else { result = "That didn't finish. Try again, or see the details below."; resultDetail = outcome.output }
            refreshMonitoring()
        }
    }
    private func resume() {
        working = true; result = nil; resultDetail = nil
        Task { result = await store.resumeIndexing(); working = false }
    }
    // QA/development configurations never change the person's real LaunchAgents.
    private var actionsAllowed: Bool { (!store.configuration.isQA || LifecycleQAScope.active != nil) && monitoring?.helperExecutable != nil && !working }
    @ViewBuilder private func monitoringControls(_ monitoring: MonitoringSetupStatus) -> some View {
        Text(monitoring.summary).fixedSize(horizontal:false,vertical:true).accessibilityIdentifier("settings.monitoring.status")
        HStack {
            switch monitoring.state {
            case .off: Button("Enable Background Monitoring…") { pending = .enable }
            case .needsUpdate: Button("Update Background Monitor…") { pending = .enable }; Button("Disable…") { pending = .disable }
            case .incomplete: Button("Repair…") { pending = .enable }; Button("Disable…") { pending = .disable }
            case .on:
                if store.monitoringHealth(at: Date()).offersRepair { Button("Repair…") { pending = .enable } }
                Button("Disable…") { pending = .disable }
                // macOS prompts only while the choice is undecided; otherwise its settings decide.
                if LifecycleQAScope.active == nil {
                    if monitoring.notifications.canPrompt { Button("Allow Low-Space Notifications…") { perform(.notifications) } }
                    else { Button("Notification Settings…") { if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") { NSWorkspace.shared.open(url) } } }
                }
            }
            if working { ProgressView().controlSize(.small) }
        }.disabled(!actionsAllowed).accessibilityIdentifier("settings.monitoring.actions")
        if LifecycleQAScope.active != nil {
            Text("Disposable lifecycle installation. Background tasks scan only the private fixtures; notifications are suppressed.").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
        } else if store.configuration.isQA {
            Text("Disabled in QA builds, which never change your real background tasks.").font(.caption).foregroundStyle(.secondary)
        } else if monitoring.helperExecutable == nil {
            Text("This build does not include the background monitor. Install Storage Monitor from its disk image to manage monitoring here.").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
        }
        if monitoring.state == .on && LifecycleQAScope.active == nil {
            Text(monitoring.notifications.text).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true).accessibilityIdentifier("settings.monitoring.notifications")
        }
    }
    /// The Storage screen's Enable Monitoring asks for consent directly; nothing is set up without it.
    private func openRequestedConsent() {
        guard store.enableMonitoringRequested, let monitoring else { return }
        store.enableMonitoringRequested = false
        if monitoring.state == .off && actionsAllowed { pending = .enable }
    }
    var body: some View {
        Form {
            // Setup comes first: it is what a new user opens Settings for.
            Section("Background Monitoring") {
                if let monitoring { monitoringControls(monitoring) }
                else { Text("Checking background monitoring…").foregroundStyle(.secondary).accessibilityIdentifier("settings.monitoring.status") }
                TimelineView(.periodic(from: .now, by: 15)) { context in
                    let health = store.monitoringHealth(at: context.date)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(health.title).font(.callout.weight(.medium))
                        Text(health.detail).font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        if health.state == .paused {
                            Button("Resume Indexing") { resume() }.disabled(working).accessibilityIdentifier("settings.monitoring.resume")
                        }
                        InspectorDisclosure("Technical details", isExpanded: $showTechnical) {
                            ForEach(health.technicalLines(inventory: store.inventoryEvidence), id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary).textSelection(.enabled).fixedSize(horizontal: false, vertical: true) }
                        }
                    }.accessibilityIdentifier("settings.monitoring.health")
                }
                Button("Check Again") { store.refresh(); refreshMonitoring() }
                    .help("Read the background monitor's current status again.")
                if let result { Text(result).font(.caption).foregroundStyle(.secondary).textSelection(.enabled).fixedSize(horizontal:false,vertical:true).accessibilityIdentifier("settings.monitoring.result") }
                if let resultDetail {
                    InspectorDisclosure("Details", isExpanded: $showResultDetail) {
                        Text(resultDetail).font(.caption).foregroundStyle(.secondary).textSelection(.enabled).fixedSize(horizontal:false,vertical:true)
                    }
                }
            }
            Section("Appearance") {
                Picker("Appearance",selection:$store.appearance) { ForEach(AppAppearance.allCases) { Text($0.title).tag($0) } }
                    .pickerStyle(.radioGroup)
                    .accessibilityIdentifier("settings.appearance")
                Text("Applies to Storage Monitor only. System follows your Mac's appearance.").font(.subheadline).foregroundStyle(.secondary)
                    .fixedSize(horizontal:false,vertical:true)
            }
            Section("Privacy") {
                Text("Storage Monitor reads local capacity and optional folder measurements. It does not upload your storage history.")
                    .font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
                InspectorDisclosure("Permission details",isExpanded:$showPrivacyDetails) {
                    Text(MonitoringSetupStatus.permissions).font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
                }
                Button("Open Full Disk Access Settings…") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") { NSWorkspace.shared.open(url) }
                }.disabled(NativeQARuntime.active != nil || LifecycleQAScope.active != nil).accessibilityIdentifier("settings.privacy.fullDiskAccess")
            }
        }
        .formStyle(.grouped)
        .frame(width:540)
        .background(SettingsWindowSetup())
        .task {
            // Scoped to the visible Settings view; cancellation stops this clock on disappearance.
            while !Task.isCancelled {
                refreshMonitoring(); store.refresh()
                do { try await Task.sleep(for: .seconds(30)) } catch { break }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in refreshMonitoring(); store.refresh() }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)) { _ in store.woke() }
        .onAppear {
            refreshMonitoring()
            openRequestedConsent()
        }
        .onChange(of: store.enableMonitoringRequested) { _, _ in openRequestedConsent() }
        .onChange(of: monitoring?.state) { _, _ in openRequestedConsent() }
        .alert(pending == .disable ? "Disable background monitoring?" : (monitoring?.state == .off ? "Enable background monitoring?" : "Update background monitoring?"),
               isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } })) {
            Button(pending == .disable ? "Disable" : (monitoring?.state == .off ? "Enable" : "Update")) { if let action = pending { perform(action) }; pending = nil }
            Button("Cancel", role: .cancel) { pending = nil }
        } message: {
            if let scope = LifecycleQAScope.active {
                Text(pending == .disable ? "Remove this disposable session's three background tasks. Its private fixture history is kept." : "Install the disposable helper and register three session-specific tasks. They scan only \(scope.fixtures). Production monitoring is untouched. Private plists do not establish login persistence. Notifications are suppressed.")
            } else { Text(pending == .disable ? MonitoringSetupStatus.disableConfirmation : MonitoringSetupStatus.consent) }
        }
    }
}

/// The Settings scene owns one window. Never close it based on launch timing: an immediate Command-comma
/// is as deliberate as a later request. Disable future restoration on this window only, without finding
/// or modifying any other window by title.
struct SettingsWindowSetup: NSViewRepresentable {
    static func configure(_ window: NSWindow) {
        window.isRestorable = false
        window.disableSnapshotRestoration()
    }
    func makeNSView(context: Context) -> NSView { Host() }
    func updateNSView(_ view: NSView, context: Context) { if let window = view.window { Self.configure(window) } }
    final class Host: NSView {
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); if let window { SettingsWindowSetup.configure(window) } }
    }
}
