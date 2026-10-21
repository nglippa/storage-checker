import SwiftUI
import AppKit


struct ViewerConfiguration {
    let database: String
    let appearance: String?
    let windowSize: CGSize?
    let isQA: Bool
    static let current: Self = {
        let args = CommandLine.arguments
        func value(_ key: String) -> String? { guard let i = args.firstIndex(of: key), args.count > i+1 else { return nil }; return args[i+1] }
        let override = value("--database-path")
        let dimensions = value("--window-size")?.split(separator: "x").compactMap { Double($0) }
        let size: CGSize? = dimensions?.count == 2 ? CGSize(width: max(780,dimensions![0]), height: max(620,dimensions![1])) : nil
        return Self(database: override ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/MacBook Storage Monitor/history.sqlite3").path, appearance: value("--appearance"), windowSize: size, isQA: override != nil)
    }()
}

@MainActor final class ViewerStore: ObservableObject {
    @Published private(set) var snapshot: HistorySnapshot?
    @Published private(set) var visibleEvents = [StorageEvent]()
    @Published private(set) var isLoading = false
    @Published private(set) var error: String?
    @Published var selection: String?
    @Published var showInspector = false
    @Published var filters: EventFilters { didSet { persist(); applyFilters() } }
    @Published var chartRange: EventTimeFilter = .day { didSet { preferences.set(chartRange.rawValue,forKey:"chartRange") } }
    // Viewer-only appearance; the system-wide setting is never changed.
    @Published var appearance: AppAppearance = .system { didSet { if configuration.appearance == nil { appearance.save(preferences) }; applyAppearance() } }
    let live = LiveCapacityMonitor()
    let configuration: ViewerConfiguration
    private let reader: HistoryReader
    private let preferences: UserDefaults
    private var loop: Task<Void,Never>?
    private var refreshTask: Task<Void,Never>?
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
        appearance = AppAppearance.load(preferences, override: configuration.appearance)
    }
    nonisolated static func preferences(for configuration: ViewerConfiguration) -> UserDefaults {
        configuration.isQA ? UserDefaults(suiteName: "local.macbook.storage-monitor.viewer.qa")! : .standard
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
    func refreshLive() { Task { await live.refresh() } }
    func refreshAll() { refresh(); refreshLive() }
    private func persist() { if let data = try? JSONEncoder().encode(filters) { preferences.set(data,forKey:"filters") } }
    private func applyFilters() {
        visibleEvents = filters.apply(snapshot?.events ?? [])
        if let selection, !visibleEvents.contains(where: { $0.id == selection }) { self.selection = nil }
    }
    func clearFilters() { filters = EventFilters() }
    func refresh() {
        guard refreshTask == nil else { return }
        isLoading = true
        refreshTask = Task {
            do {
                let value = try await reader.load()
                guard !Task.isCancelled else { return }
                snapshot = value; error = nil; applyFilters()
                // QA-only: preselect an event so captures show the inspector.
                if configuration.isQA, selection == nil, let i = CommandLine.arguments.firstIndex(of: "--select-event"), CommandLine.arguments.count > i+1 {
                    selection = CommandLine.arguments[i+1]; showInspector = true
                }
            } catch { self.error = error.localizedDescription }
            isLoading = false; refreshTask = nil
        }
    }
    func start() {
        guard loop == nil else { return }
        applyAppearance()
        refreshAll()
        loop = Task {
            while !Task.isCancelled {
                do { try await Task.sleep(for:.seconds(30)) } catch { break }
                guard NSApp.isActive && NSApp.windows.contains(where: { $0.isVisible && !($0 is NSPanel) }) else { continue }
                refresh()
                if live.isDue(at: Date()) { refreshLive() }
            }
        }
    }
    func stop() { loop?.cancel(); loop = nil }
}

final class ViewerAppDelegate: NSObject, NSApplicationDelegate {
    var reopen: (() -> Void)?
    static let launchedAt = Date()
    // Apply the saved appearance before any window is created.
    func applicationWillFinishLaunching(_ notification: Notification) {
        _ = Self.launchedAt
        let configuration = ViewerConfiguration.current
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
    @NSApplicationDelegateAdaptor(ViewerAppDelegate.self) private var delegate
    @StateObject private var store = ViewerStore()
    @Environment(\.openWindow) private var openWindow
    var body: some Scene {
        Settings { AppearanceSettings(store:store) }
        Window("Storage Monitor",id:"main") {
            HistoryView(store:store)
                .frame(minWidth:780,minHeight:620)
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
            window.setFrameAutosaveName(ViewerConfiguration.current.isQA ? "StorageMonitorQA" : "StorageMonitorMain")
            window.minSize = NSSize(width:780,height:620)
            if let size = ViewerConfiguration.current.windowSize { window.setContentSize(size) }
            if ViewerConfiguration.current.isQA { window.title = "Storage Monitor — QA: \(URL(fileURLWithPath:ViewerConfiguration.current.database).lastPathComponent)" }
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
    var body: some View {
        Form {
            Picker("Appearance",selection:$store.appearance) { ForEach(AppAppearance.allCases) { Text($0.title).tag($0) } }
                .pickerStyle(.radioGroup)
                .accessibilityIdentifier("settings.appearance")
            Text("Applies to Storage Monitor only. System follows your Mac's appearance.").font(.subheadline).foregroundStyle(.secondary)
                .fixedSize(horizontal:false,vertical:true)
        }
        .padding(20).frame(width:380)
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

