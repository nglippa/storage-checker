import SwiftUI
import AppKit

struct MonitorRootView: View {
    @ObservedObject var store: ViewerStore
    /// Every launch opens on the storage browser. The section is never restored from saved state.
    /// QA-only capture aid: `--open-monitoring` opens Monitoring; ignored unless the viewer was opened on a QA database.
    @State private var section = ViewerConfiguration.current.isQA && CommandLine.arguments.contains("--open-monitoring") ? "history" : "inventory"
    @StateObject private var inventory: InventoryBrowserModel
    init(store: ViewerStore) {
        self.store = store
        _inventory = StateObject(wrappedValue: InventoryBrowserModel(database: store.configuration.database, readiness: store.readiness))
    }
    var body: some View {
        Group {
            if section == "history" { HistoryView(store: store) }
            else { DiskInventoryView(configuration: store.configuration, history: store, model: inventory) }
        }
        // Set for both sections, so the QA marker stays in the title after Monitoring is left.
        .navigationTitle(store.configuration.windowTitle)
        // D6: when the content is taller than the window, SwiftUI centred it and pushed its top rows
        // under the title bar and toolbar. Anchor it to the top so any overflow leaves at the bottom.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // The section switcher lives in the toolbar. As a row above the content it pushed each section
        // down by one row while macOS 26 still drew the toolbar's scroll-edge blur at the section's
        // top as if it began under the toolbar, so the blur covered "Internal storage" and the first
        // rows of the overview in tall windows (1.0.3 report, D6). QA windows name their database in
        // the window title.
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("Section", selection: $section) {
                    Text("Storage").tag("inventory")
                    Text("Monitoring").tag("history")
                }.pickerStyle(.segmented).fixedSize().help("Storage shows what is using your disk. Monitoring shows how free space changed over time and why.")
                .accessibilityIdentifier("app.section")
            }
        }
        .onAppear {
            store.setInventoryVisible(section == "inventory")
            PerformanceScript.shared.setSection = { section = $0 }
            PerformanceScript.shared.start(store: store, inventory: inventory)
        }
        .onChange(of: section) { _, value in
            PerformanceTrace.mark("section.change", value, frame: true)
            store.setInventoryVisible(value == "inventory")
        }
    }
}

enum InventoryBrowserMode: String, CaseIterable, Identifiable {
    case explorer = "Explorer", contents = "Contents", directories = "Largest folders", files = "Largest files", all = "Largest items", review = "Review Candidates"
    var id: Self { self }
}

@MainActor final class InventoryBrowserModel: ObservableObject {
    @Published var root: InventoryNode?
    @Published var directory: InventoryNode?
    @Published var status: InventoryStatus?
    @Published var items = [InventoryNode]()
    @Published var breadcrumbs = [InventoryNode]()
    @Published var error: String?
    @Published var message: String?
    @Published var loading = false
    @Published var selected: Int64?
    @Published var parentID: Int64?
    @Published var mode = InventoryBrowserMode.explorer
    @Published var sort = InventorySort.allocated
    @Published var search = ""
    @Published var scopeToFolder = false
    @Published var offset = 0
    @Published var revision = 0
    @Published var hasMore = false
    @Published var initializationRequested = false
    @Published var indexingPaused = false
    @Published var deferredFolders = [InventoryNode]()
    enum ListState { case loading, loaded, failed }
    @Published var deferredFoldersState = ListState.loading
    @Published var progress = [InventoryProgressSample]()
    @Published var databaseBytes: Int64?
    @Published var accounting: InventoryAccounting?
    /// Storage Monitor's own data folder (database, journal, update snapshots): outside the index.
    @Published var ownDataBytes: Int64?
    let database: String
    /// Explorer outline and storage-map state, shared by both and kept across browse-mode changes.
    lazy var explorer = InventoryExplorerController(database: database)
    /// The Living Tree of the explorer's current folder; created the first time the tree is shown.
    lazy var livingTree = LivingTreeController(database: database)
    /// The Structured Explorer's camera and layout cache (it draws `livingTree`'s model), kept across visualization switches.
    lazy var structuredExplorer = StructuredExplorerState()
    /// A bounded review of this catalog, independent of the currently open folder.
    lazy var reviewQueue = CleanupReviewQueueController(database: database)
    /// Migration Readiness: sparse-storage detection over this catalog (read-only; its own reader and actor).
    lazy var migration: MigrationReadinessController = {
        let controller = MigrationReadinessController(database: database)
        controller.onReport = { [weak self] report in self?.structuredExplorer.setMigrationTargets(MigrationReadinessController.targets(report)) }
        return controller
    }()
    /// Cleanup Inspector evidence for the Inspector's subject (read-only; created on first use).
    lazy var cleanup: CleanupInspectorController = {
        var environment = ArtifactEnvironment.current(ownData: (database as NSString).deletingLastPathComponent)
        environment.qaRuntime = NativeQARuntime.active
        let controller = CleanupInspectorController(database: database, environment: environment)
        controller.allowsTrash = !ViewerConfiguration.current.isQA || NativeQARuntime.active != nil
        return controller
    }()
    /// A search result opened in its folder: selected there and revealed in the Living Tree.
    var pendingReveal: InventoryNode?
    let reader: InventoryReader
    let readiness: ViewerReadiness
    private let focusWriter = InventoryFocusWriter()
    private var focusRevision: UInt64 = 0
    private var reloads = InventoryReloadGate()
    private var loadGeneration = 0
    private var requestedPath: String?
    private var lastFocusedNode: Int64?
    private var focusReadyNode: Int64?
    private var loadedPageNode: Int64?
    private var loadedPageHasQualifiedSize = false
    init(database: String, readiness: ViewerReadiness) { self.database = database; self.readiness = readiness; reader = InventoryReader(path: database) }
    var selectedNode: InventoryNode? { items.first { $0.id == selected } }
    var queryID: String { "\(mode.rawValue)|\(sort.rawValue)|\(search)|\(scopeToFolder)|\(offset)|\(revision)" }
    /// The mode that shows a folder after navigating: the explorer stays the explorer; the rankings and
    /// search switch to that folder's contents.
    private var folderMode: InventoryBrowserMode { mode == .explorer ? .explorer : .contents }

    func navigate(_ node: InventoryNode) {
        guard node.kind == .directory else { return }
        guard node.id != parentID else { return }
        PerformanceTrace.mark("folder.open", "\(node.id)", frame: true)
        requestedPath = nil
        pendingReveal = nil
        focus(node)
        parentID = node.id; offset = 0; selected = nil; search = ""; mode = folderMode; revision &+= 1
    }
    func showEnclosingFolder(of node: InventoryNode) {
        guard let parent = node.parentID else { return }
        pendingReveal = node
        parentID = parent; mode = folderMode; search = ""; offset = 0; selected = nil; revision &+= 1
    }
    /// Review Queue uses the same pending-reveal path as search, Atlas and Living Tree selections.
    func revealReviewCandidate(_ node: InventoryNode) {
        mode = .explorer
        showEnclosingFolder(of: node)
    }
    func loadDeferredFolders() async {
        deferredFoldersState = .loading
        do { deferredFolders = try await reader.deferredDirectories(); deferredFoldersState = .loaded }
        catch { deferredFolders = []; deferredFoldersState = .failed }
    }
    func refreshIfIdle() {
        guard reloads.request(loading: loading) else { return }
        revision &+= 1
    }
    func load() async {
        await PerformanceTrace.measure("inventory.load", "mode=\(mode.rawValue) folder=\(parentID.map(String.init) ?? "root")") { await loadPage() }
    }
    private func loadPage() async {
        loadGeneration &+= 1
        let generation = loadGeneration
        loading = true
        // Only the newest load clears the flag and replays a refresh requested meanwhile. A cancelled older load
        // must not clear its successor's flag, and a cancelled newest load must still replay the refresh.
        defer {
            if generation == loadGeneration {
                loading = false
                if reloads.finish() { revision &+= 1 }
            }
        }
        // Before background monitoring is enabled there is no database yet: that is "not started",
        // not an error to show (D4).
        let databasePath = database
        let files = await Task.detached(priority: .utility) { () -> (exists: Bool, bytes: Int64, folder: Int64) in
            let size = { (path: String) in ((try? FileManager.default.attributesOfItem(atPath: path)[.size]) as? NSNumber)?.int64Value ?? 0 }
            let folder = URL(fileURLWithPath: databasePath).deletingLastPathComponent()
            let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
            return (FileManager.default.fileExists(atPath: databasePath), size(databasePath) + size(databasePath + "-journal") + size(databasePath + "-wal"),
                    names.reduce(0) { $0 + size(folder.appendingPathComponent($1).path) })
        }.value
        databaseBytes = files.exists ? files.bytes : nil
        ownDataBytes = files.exists ? files.folder : nil
        guard files.exists else {
            status = InventoryStatus(generation: nil, state: "uninitialized", rootPath: nil, totalNodes: 0, completedDirectories: 0, pendingDirectories: 0, staleDirectories: 0, unknownDirectories: 0, queuedDirectoryJobs: 0, hasReconciliationWork: false, hasInitialDiscoveryWork: false, progress: nil, completeness: .unknown, reason: nil, updatedAt: nil, createdAt: nil, initialCompletion: .notStarted)
            root = nil; directory = nil; items = []; error = nil; progress = []
            return
        }
        do {
            if mode != .review && !search.isEmpty { try await Task.sleep(for: .milliseconds(180)) }
            let newStatus = try await reader.status()
            try Task.checkCancellation()
            accounting = try? await reader.accounting()
            // Samples are read only while a first pass is shown (one small indexed query).
            progress = newStatus.initialCompletion == .inProgress ? ((try? await reader.progressSamples()) ?? []) : []
            // Publish progress before waiting for the selected directory page.
            status = newStatus
            // A refresh request's note gives way to the live status once the worker has picked it up.
            if message?.hasPrefix("Full refresh requested") == true || message == "Folder refresh requested." {
                if newStatus.hasReconciliationWork || InventoryStatusPresentation(status: newStatus).activeListings > 0 { message = nil }
            }
            if newStatus.generation != nil { initializationRequested = false }
            let cancelPath = URL(fileURLWithPath: database).deletingLastPathComponent().appendingPathComponent("inventory.cancel").path
            let paused = await Task.detached(priority: .utility) { FileManager.default.fileExists(atPath: cancelPath) }.value
            try Task.checkCancellation()
            indexingPaused = paused
            let newRoot = try await reader.root()
            try Task.checkCancellation()
            guard let newRoot else {
                guard !Task.isCancelled else { return }
                status = newStatus; root = nil; directory = nil; parentID = nil; items = []; breadcrumbs = []; selected = nil; hasMore = false; error = nil
                readiness.mark("inventory_status_data_ready")
                return
            }
            let requestedParent = parentID
            var folder = newRoot
            var resetToRoot = false
            if let requestedParent {
                if let requested = try await reader.node(id: requestedParent) { folder = requested }
                else { resetToRoot = true }
            }
            if let requestedPath {
                let location = try await reader.locateDirectory(path: requestedPath)
                folder = location.node
                if location.exact {
                    self.requestedPath = nil; lastFocusedNode = folder.id; focusReadyNode = folder.id
                    message = "Requested folder is available. Sizes remain qualified by coverage."
                }
            }
            let page: InventoryPage
            let effectiveMode = resetToRoot ? InventoryBrowserMode.contents : mode
            let effectiveSearch = resetToRoot || effectiveMode == .review ? "" : search
            let effectiveOffset = resetToRoot ? 0 : offset
            let under = scopeToFolder && folder.id != newRoot.id ? folder.id : nil
            if !effectiveSearch.isEmpty { page = try await reader.search(text: effectiveSearch, under: under, offset: effectiveOffset, limit: 100) }
            else {
                switch effectiveMode {
                // The explorer reads its own pages (InventoryExplorerView); this load keeps only the status,
                // current folder and breadcrumbs it shares with the other modes.
                case .explorer, .review: page = InventoryPage(items: [], hasMore: false)
                case .contents: page = try await reader.children(parentID: folder.id, offset: effectiveOffset, limit: 100, sort: sort)
                case .directories: page = try await reader.largest(kind: .directories, under: under, offset: effectiveOffset, limit: 100)
                case .files: page = try await reader.largest(kind: .files, under: under, offset: effectiveOffset, limit: 100)
                case .all: page = try await reader.largest(kind: .all, under: under, offset: effectiveOffset, limit: 100)
                }
            }
            try Task.checkCancellation()
            let trail = try await reader.breadcrumbs(id: folder.id)
            guard !Task.isCancelled else { return }
            if resetToRoot { mode = folderMode; search = ""; offset = 0; scopeToFolder = false }
            root = newRoot; directory = folder; parentID = folder.id; status = newStatus; items = page.items; hasMore = page.hasMore; breadcrumbs = trail; error = nil
            if let selected, !page.items.contains(where: { $0.id == selected }) { self.selected = nil }
            loadedPageNode = folder.id
            loadedPageHasQualifiedSize = page.items.contains { max($0.allocatedBytes ?? $0.previousAllocatedBytes ?? 0, $0.logicalBytes ?? $0.previousLogicalBytes ?? 0) > 0 && $0.status != .unknown }
            readiness.mark("inventory_status_data_ready")
            markPageDataReadyIfQualified()
            readiness.inventoryPageLoaded()
            if requestedParent == nil { focus(folder) }
        } catch is CancellationError { }
        catch { if !Task.isCancelled { self.error = String(describing: error) } }
    }
    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        panel.prompt = "Explore"; panel.message = "Choose a folder on the startup Data volume. Discovered parents appear immediately."
        panel.begin { [weak self] response in
            guard response == .OK, let path = panel.url?.path else { return }
            Task { await self?.openPath(path) }
        }
    }
    func openPath(_ path: String) async {
        do {
            let location = try await reader.locateDirectory(path: path)
            requestedPath = location.exact ? nil : path
            lastFocusedNode = location.node.id
            parentID = location.node.id; offset = 0; selected = nil; mode = folderMode; search = ""
            request("focus", path: path, announce: false) { [weak self] in
                guard let self else { return }
                if location.exact { self.focusReadyNode = location.node.id; self.markPageDataReadyIfQualified() }
                let name = inventoryFolderName(path: path, rootPath: self.root?.path)
                self.message = location.exact ? "“\(name)” moved ahead in the indexing queue." : "“\(name)” moved ahead in the indexing queue. Showing its discovered parent while indexing continues."
            }
            revision &+= 1
        } catch { self.error = String(describing: error) }
    }
    /// The name shown for a folder: the inventory root reads "Startup Data".
    func displayName(_ node: InventoryNode) -> String { node.parentID == nil ? "Startup Data" : node.name }
    func prioritizeCurrentFolder() {
        guard let directory else { return }
        focus(directory, explicit: true)
    }
    private func focus(_ node: InventoryNode, explicit: Bool = false) {
        // Valid cached listings need no worker wakeup or event replay just to browse.
        if !explicit && node.status == .complete {
            lastFocusedNode = node.id; focusReadyNode = node.id; markPageDataReadyIfQualified(); return
        }
        if !explicit && node.status == .unknown { return }
        guard explicit || lastFocusedNode != node.id else { return }
        lastFocusedNode = node.id
        request("focus", path: node.path, announce: explicit) { [weak self] in
            self?.focusReadyNode = node.id
            self?.markPageDataReadyIfQualified()
        }
    }
    private func markPageDataReadyIfQualified() {
        if loadedPageHasQualifiedSize, loadedPageNode == focusReadyNode { readiness.mark("inventory_page_data_ready") }
    }
    func request(_ action: String, path: String? = nil, announce: Bool = true, onSuccess: (() -> Void)? = nil) {
        let database = database
        let starting = action == "refresh" && status?.generation == nil
        if starting { initializationRequested = true }
        let sequence: UInt64?
        if action == "focus" { focusRevision &+= 1; sequence = focusRevision } else { sequence = nil }
        Task {
            do {
                if let sequence {
                    let published = try await focusWriter.enqueue(database: database, path: path, revision: sequence)
                    guard published && sequence == focusRevision else { return }
                } else {
                    _ = try await Task.detached(priority: .utility) { try InventoryRequests.enqueue(database: database, action: action, path: path) }.value
                }
                if action == "pause" { indexingPaused = true }
                if action == "resume" { indexingPaused = false }
                if announce {
                    switch action {
                    case "focus": message = "“\(path.map { inventoryFolderName(path: $0, rootPath: root?.path) } ?? "This folder")” will be indexed before other folders. Existing sizes stay visible."
                    case "pause": message = "Pause requested. Committed results remain available."
                    case "resume": message = "Resume requested."
                    default: message = path == nil ? "Full refresh requested: the background worker will recheck every folder, which can take a while on a large disk." : "Folder refresh requested."
                    }
                }
                onSuccess?()
                if action != "focus" { refreshIfIdle() }
            } catch {
                if starting { initializationRequested = false }
                self.error = String(describing: error)
            }
        }
    }
}

struct DiskInventoryView: View {
    let configuration: ViewerConfiguration
    @ObservedObject var history: ViewerStore
    @ObservedObject var model: InventoryBrowserModel
    @AppStorage("inventory.header.details", store: ViewerStore.viewPreferences) private var showingIndexDetails = false
    @ObservedObject private var qaWorker = NativeQAWorker.shared
    private var workerAvailable: Bool {
        let data = URL(fileURLWithPath: configuration.database).deletingLastPathComponent()
        let path = configuration.isQA ? data.appendingPathComponent("inventory-worker.plist").path : FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents/local.macbook.storage-monitor.inventory.plist").path
        if NativeQARuntime.active != nil { return qaWorker.failure == nil }
        return FileManager.default.fileExists(atPath: path)
    }
    private var indexingActive: Bool {
        guard let status = model.status else { return true }
        // Deferred folders retry on the worker's next scheduled update; they are not active indexing.
        return status.generation == nil || InventoryStatusPresentation(status: status).activeListings > 0 || status.hasReconciliationWork
    }
    @State private var showingDeferred = false
    @State private var showingAccounting = false
    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            controls
            if let error = model.error {
                HStack(alignment: .top) {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                    Text(error).font(.callout).textSelection(.enabled)
                    Spacer(); Button("Retry") { model.revision += 1 }
                }.padding(14).accessibilityIdentifier("inventory.error")
                Divider()
            }
            if model.mode == .review {
                CleanupReviewQueueView(browser: model, queue: model.reviewQueue)
            } else if model.mode == .explorer && model.search.isEmpty {
                InventoryExplorerView(browser: model)
            } else {
            inventoryTable
            if let item = model.selectedNode { itemDetails(item); Divider() }
            HStack {
                Text(model.items.isEmpty ? "No items found on this page" : "Page \(model.offset / 100 + 1) · \(model.items.count) items")
                if model.loading { ProgressView().controlSize(.mini) }
                Spacer()
                Button("Previous") { model.offset = max(0, model.offset - 100) }.disabled(model.offset == 0).accessibilityIdentifier("inventory.previous")
                Button("Next") { model.offset += 100 }.disabled(!model.hasMore).accessibilityIdentifier("inventory.next")
            }.font(.caption).foregroundStyle(.secondary).padding(.horizontal, 22).padding(.vertical, 9)
            }
            Divider()
            Text("Indexed sizes can include shared storage and are not guaranteed recoverable space.")
                .help("File allocation may include shared APFS blocks. Totals count hard links once and do not represent reclaimable physical storage." + (model.databaseBytes.map { " Inventory database: " + ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) + "." } ?? ""))
                .font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 22).padding(.vertical, 9)
        }
        .overlay(alignment: .top) { if NativeQARuntime.active != nil, let failure = qaWorker.failure { Text("QA fixture worker stopped: " + failure).font(.caption).padding().background(.background) } }
        .background(Color(nsColor: .windowBackgroundColor))
        .task(id: model.queryID) { await model.load() }
        .onAppear { PerformanceTrace.mark("storage.appear") }
        // Reuse the viewer's one visible-window clock; inventory adds no scanner or loop.
        .onReceive(history.$inventoryRefreshTick.dropFirst()) { _ in model.refreshIfIdle() }
        // Migration Readiness follows catalog changes; the controller coalesces passes (at most one per 30 s).
        .task { model.migration.refresh() }
        .onChange(of: model.status?.updatedAt) { _, _ in model.migration.refresh() }
        .onChange(of: indexingActive, initial: true) { _, active in history.setInventoryBusy(active) }
        .onChange(of: model.mode) { _, _ in model.offset = 0 }
        .onChange(of: model.search) { _, _ in model.offset = 0 }
        .onChange(of: model.scopeToFolder) { _, _ in model.offset = 0 }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { model.revision += 1 } label: {
                    if model.loading { ProgressView().controlSize(.small) } else { Image(systemName: "arrow.clockwise") }
                }
                    .help("Reload indexed results. No filesystem scan is performed.").accessibilityLabel("Reload inventory").accessibilityIdentifier("inventory.reload")
            }
        }
    }
    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            InventoryCapacitySummary(live: history.live, recorded: history.snapshot?.latest)
            HStack {
                titleTrail
                Spacer()
                Menu("Folder updates") {
                    if let directory = model.directory, indexingActive {
                        Button("Update “\(model.displayName(directory))” first") { model.prioritizeCurrentFolder() }
                    }
                    Button("Refresh this folder") { model.request("refresh", path: model.directory?.path) }
                    Button("Refresh entire inventory") { model.request("refresh") }
                    Divider()
                    Button("Pause indexing") { model.request("pause") }
                    Button("Resume indexing") { model.request("resume") }
                }.disabled(!workerAvailable).accessibilityIdentifier("inventory.refresh")
            }
            initializationProgress
            summaryLine
            MigrationReadinessSummary(controller: model.migration, browser: model)
            if let status = model.status, !(initialization.isVisible && status.generation == nil) {
                let presentation = InventoryStatusPresentation(status: status)
                if !initialization.isVisible {
                    if showingIndexDetails {
                        Text("\(status.totalNodes.formatted()) items found · \(presentation.foundFolders.formatted()) folders found · \(presentation.activeListings.formatted()) listings queued")
                            .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    }
                } else if presentation.phase == .reconciling && !model.indexingPaused {
                    // The first-index panel owns title and counts; add only overlapping reconciliation.
                    Text(status.hasEventGapRecheck ? "Updating older measurements" : presentation.headline).font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("inventory.status")
                }
                if showingIndexDetails || initialization.isVisible {
                    Text(presentation.detail + (status.unknownDirectories > 0 ? " \(status.unknownDirectories.formatted()) folders have partial or unavailable measurements." : ""))
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("inventory.statusDetail")
                }
                if status.deferredDirectories > 0 && (showingIndexDetails || initialization.isVisible) {
                    Button(status.deferredDirectories == 1 ? "Show folder" : "Show \(status.deferredDirectories.formatted()) folders") {
                        showingDeferred = true
                        Task { await model.loadDeferredFolders() }
                    }
                    .buttonStyle(.link).font(.caption).accessibilityIdentifier("inventory.showDeferred")
                    .popover(isPresented: $showingDeferred, arrowEdge: .bottom) { deferredFolders }
                }
                if showingIndexDetails, let note = presentation.completionNote {
                    Text(note).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("inventory.completionNote")
                }
            }
            if let message = model.message { Text(message).font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("inventory.requestStatus") }
        }.padding(.horizontal, 22).padding(.top, 12).padding(.bottom, 10)
    }

    /// The breadcrumb trail is the title: earlier folders are links, the current one is emphasized, and the
    /// full path is on hover. Long trails keep the volume, an ellipsis and the last three folders.
    private var titleTrail: some View {
        let trail = model.breadcrumbs.isEmpty ? (model.directory.map { [$0] } ?? []) : model.breadcrumbs
        let shown: [InventoryNode?] = trail.count > 4 ? [trail[0], nil] + trail.suffix(3).map { $0 } : trail.map { $0 }
        return HStack(alignment: .firstTextBaseline, spacing: 6) {
            if trail.isEmpty { Text("Disk Inventory").font(.title3.weight(.semibold)) }
            ForEach(Array(shown.enumerated()), id: \.offset) { index, node in
                if index > 0 { Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary) }
                if let node {
                    let name = node.parentID == nil ? "Startup Data" : node.name
                    if node.id == model.directory?.id {
                        // The current folder is the title, not a (dimmed, disabled) control.
                        Text(name).font(.title2.weight(.semibold)).lineLimit(1).help(node.path)
                            .accessibilityIdentifier("inventory.breadcrumb.\(node.id)")
                    } else {
                        Button(name) { model.navigate(node) }
                            .buttonStyle(.plain).font(.title3).foregroundStyle(.secondary).lineLimit(1).help(node.path)
                            .accessibilityIdentifier("inventory.breadcrumb.\(node.id)")
                    }
                } else { Text("…").font(.title3).foregroundStyle(.tertiary) }
            }
        }.accessibilityIdentifier("inventory.breadcrumbs")
    }

    /// One line: indexing status (details a click away), a full refresh's progress, and the storage accounting.
    @ViewBuilder private var summaryLine: some View {
        HStack(spacing: 6) {
            if let status = model.status, !initialization.isVisible {
                let presentation = InventoryStatusPresentation(status: status)
                Text(status.hasEventGapRecheck ? "Updating older measurements" : presentation.headline).font(.caption).foregroundStyle(.secondary).lineLimit(1).accessibilityIdentifier("inventory.status")
                if status.refreshIsManual, status.hasReconciliationWork, let fraction = status.refreshFraction {
                    ProgressView(value: fraction).progressViewStyle(.linear).controlSize(.small).frame(width: 90)
                        .accessibilityLabel("Full refresh").accessibilityValue("about \(Int(fraction * 100)) percent rechecked")
                        .accessibilityIdentifier("inventory.refreshProgress")
                }
                Button(showingIndexDetails ? "Hide details" : "Indexing details") { showingIndexDetails.toggle() }
                    .buttonStyle(.link).font(.caption).accessibilityIdentifier("inventory.indexDetails")
            }
            if let latest = history.snapshot?.latest {
                let accounting = storageAccounting(latest)
                if model.status != nil && !initialization.isVisible { Text("·").font(.caption).foregroundStyle(.tertiary) }
                if showingIndexDetails {
                    Text(accounting.summary).font(.caption).foregroundStyle(.secondary).monospacedDigit().lineLimit(2)
                        .accessibilityIdentifier("inventory.accountingSummary")
                }
                Button("Disk details") { showingAccounting = true }
                    .buttonStyle(.link).font(.caption).accessibilityIdentifier("inventory.accounting")
                    .popover(isPresented: $showingAccounting, arrowEdge: .bottom) { accountingDetails(accounting) }
            }
        }
    }
    private func storageAccounting(_ latest: Measurement) -> StorageAccountingPresentation {
        StorageAccountingPresentation(used: latest.used, free: latest.free, volumes: latest.volumes.map { StorageVolumeUsage(name: $0.name, roles: $0.roles, bytes: $0.bytes) },
                                      inventory: model.status?.generation == nil ? nil : model.accounting, ownDataBytes: model.ownDataBytes,
                                      firstPassComplete: model.status?.initialCompletion != .inProgress)
    }
    private func accountingDetails(_ accounting: StorageAccountingPresentation) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Storage accounting").font(.headline)
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                ForEach(accounting.rows, id: \.label) { row in
                    GridRow {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(row.label).font(.callout)
                            if let detail = row.detail { Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                        }
                        Text(row.value).font(.callout.monospacedDigit()).gridColumnAlignment(.trailing)
                    }
                }
            }
            if !accounting.notes.isEmpty {
                Divider()
                ForEach(accounting.notes, id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            }
            if accounting.needsFullDiskAccess || model.accounting?.fullDiskAccess == "unknown" {
                Divider()
                Text(StorageAccountingPresentation.fullDiskAccessGuidance).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Button("Open Full Disk Access Settings…") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") { NSWorkspace.shared.open(url) }
                }.controlSize(.small)
            }
        }.padding(16).frame(width: 470)
    }
    private var deferredFolders: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Folders that kept changing").font(.headline)
            Text("Each was retried during the last update and changed every time. Earlier sizes are shown until a listing succeeds.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Divider()
            switch model.deferredFoldersState {
            case .loading: ProgressView("Loading…").controlSize(.small)
            case .failed:
                HStack {
                    Text("Couldn't load the list right now.").font(.callout).foregroundStyle(.secondary)
                    Button("Try Again") { Task { await model.loadDeferredFolders() } }.controlSize(.small)
                }
            case .loaded where model.deferredFolders.isEmpty:
                Text("No folders are waiting now; the last update listed them.").font(.callout).foregroundStyle(.secondary)
            case .loaded: EmptyView()
            }
            ForEach(model.deferredFolders) { node in
                HStack(alignment: .firstTextBaseline) {
                    Text(node.path).font(.callout).lineLimit(1).truncationMode(.middle).textSelection(.enabled).help(node.path)
                    Spacer(minLength: 12)
                    Text(bytes(node.allocatedBytes ?? node.previousAllocatedBytes, node: node)).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                    Button("Show") { showingDeferred = false; model.navigate(node) }.controlSize(.small)
                }
            }
        }.padding(16).frame(width: 460)
    }
    private var initialization: InventoryInitializationPresentation {
        InventoryInitializationPresentation(status: model.status, requested: model.initializationRequested, paused: model.indexingPaused, progress: model.progress,
                                            volumeObjects: inventoryVolumeObjectCount(root: model.status?.rootPath))
    }
    @ViewBuilder private var initializationProgress: some View {
        let presentation = initialization
        if presentation.isVisible, model.status != nil || model.error == nil {
            VStack(alignment: .leading, spacing: 7) {
                HStack(alignment: .firstTextBaseline) {
                    Text(presentation.title).font(.callout).fontWeight(.medium)
                    Spacer(minLength: 12)
                    if let elapsed = presentation.elapsed {
                        Text(elapsed).font(.caption).foregroundStyle(.secondary).monospacedDigit().multilineTextAlignment(.trailing)
                            .accessibilityIdentifier("inventory.initializationElapsed")
                    }
                }
                if (model.indexingPaused || model.status?.lowSpacePaused == true) && model.status?.generation != nil {
                    // A static track: nothing is running while paused.
                    Rectangle().fill(Color.secondary.opacity(0.15)).frame(height: 4)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(presentation.title)
                        .accessibilityValue(presentation.accessibilityValue)
                        .accessibilityIdentifier("inventory.initializationPaused")
                } else {
                    ProgressView().progressViewStyle(.linear)
                        .accessibilityLabel(presentation.title)
                        .accessibilityValue(presentation.accessibilityValue)
                        .accessibilityIdentifier("inventory.initializationProgress")
                }
                if let counts = presentation.counts {
                    Text(counts).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("inventory.initializationCounts")
                }
                if let remaining = presentation.remaining {
                    Text(([presentation.rate].compactMap { $0 } + [remaining]).joined(separator: " · ")).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("inventory.initializationEstimate")
                }
                if presentation.showsGuidance {
                    Text(InventoryInitializationPresentation.durationGuidance).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(InventoryInitializationPresentation.laterChecksGuidance).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }.padding(.top, 8).padding(.bottom, 4)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("inventory.initialization")
        }
    }
    private var controls: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Picker("Browse", selection: $model.mode) { ForEach(InventoryBrowserMode.allCases) { Text($0.rawValue).tag($0) } }
                    .labelsHidden().fixedSize().accessibilityIdentifier("inventory.mode")
                if model.mode != .review { Button("Go to folder…") { model.chooseFolder() }.accessibilityIdentifier("inventory.goToFolder") }
                if model.mode == .review {
                    Button { model.mode = .explorer } label: { Label("Back to Explorer", systemImage: "chevron.backward") }
                        .help("Return to browsing folders").accessibilityIdentifier("inventory.backToExplorer")
                } else {
                    Button { model.mode = .review } label: { Label("Review Cleanup", systemImage: "checklist") }
                        .buttonStyle(.borderedProminent)
                        .help("Review storage candidates and their evidence. This list cannot move or delete files.")
                        .accessibilityIdentifier("inventory.reviewCleanup")
                }
                if model.mode == .contents && model.search.isEmpty {
                    Picker("Sort", selection: $model.sort) {
                        Text("Allocated size").tag(InventorySort.allocated); Text("Name").tag(InventorySort.name)
                        Text("Logical size").tag(InventorySort.logical); Text("Modified").tag(InventorySort.modified)
                    }.frame(maxWidth: 210).accessibilityIdentifier("inventory.sort")
                }
                Spacer()
                if model.mode != .review {
                    TextField("Search name or path prefix", text: $model.search).textFieldStyle(.roundedBorder).frame(minWidth: 180, maxWidth: 290).accessibilityIdentifier("inventory.search")
                }
            }
            if model.mode != .review && ((model.mode != .contents && model.mode != .explorer) || !model.search.isEmpty) {
                Toggle("Only inside the selected folder", isOn: $model.scopeToFolder).font(.caption).accessibilityIdentifier("inventory.scope")
            }
            if model.mode != .review && model.mode != .contents && model.mode != .explorer, let status = model.status, InventoryStatusPresentation(status: status).rankingsArePartial {
                Text("Ranked from measurements available so far; incomplete folders can move as indexing continues.")
                    .font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("inventory.rankingQualification")
            }
        }.padding(.horizontal, 22).padding(.vertical, 10)
    }
    private var inventoryTable: some View {
        ZStack {
            Table(model.items, selection: $model.selected) {
                TableColumn("Name") { node in
                    Label(node.name, systemImage: node.kind == .directory ? "folder" : (node.kind == .symlink ? "link" : "doc"))
                        .lineLimit(1).help(node.path)
                }.width(min: 150, ideal: 280, max: .infinity)
                TableColumn("Indexed size") { node in
                    // The Measurement column states an earlier-size state once, so the size itself carries no "Previously" prefix.
                    Text(InventoryNodePresentation.compactSize(node.allocatedBytes ?? node.previousAllocatedBytes, node: node) { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }).font(.callout.weight(.medium)).monospacedDigit()
                }.width(min: 120, ideal: 165)
                TableColumn("Measurement") { node in
                    Text(InventoryNodePresentation.coverage(node)).font(.callout).foregroundStyle(.secondary)
                        .help(node.statusReason ?? "Measured metadata; filesystem changes are reconciled in the background.")
                }.width(min: 135, ideal: 180)
                TableColumn("Last checked") { node in
                    if let date = node.measuredAt { Text(date, format: .dateTime.month(.abbreviated).day().hour().minute()).font(.callout).foregroundStyle(.secondary) }
                    else { Text("Not yet measured").foregroundStyle(.secondary) }
                }.width(min: 120, ideal: 160)
            }
            .tableStyle(.inset(alternatesRowBackgrounds: false))
            .accessibilityIdentifier("inventory.table")
            .contextMenu(forSelectionType: Int64.self) { ids in
                if let id = ids.first, let item = model.items.first(where: { $0.id == id }) {
                    Button(item.kind == .directory ? "Open folder" : "Show enclosing folder") { open(item) }
                    Button("Copy path") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(item.path, forType: .string) }
                }
            } primaryAction: { ids in if let id = ids.first, let item = model.items.first(where: { $0.id == id }) { open(item) } }
            switch InventoryPlaceholder(hasRoot: model.root != nil, status: model.status, requested: model.initializationRequested, failed: model.error != nil) {
            case .checking, .waiting:
                Text(model.initializationRequested ? "Waiting for the background indexer. Results will appear here." : "Checking inventory status…")
                    .font(.callout).foregroundStyle(.secondary)
            case .notStarted:
                VStack(spacing: 9) {
                    Image(systemName: "folder").font(.title).foregroundStyle(.secondary)
                    Text("No disk inventory yet").font(.headline)
                    Text(workerAvailable ? "Start background indexing to browse measured files and folders. The first pass over a large disk may take some time; you can explore results as they're discovered." : "Background indexing has not been installed. Monitoring history remains available.")
                        .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    if workerAvailable { Button("Start indexing") { model.request("refresh") }.accessibilityIdentifier("inventory.start") }
                }.frame(maxWidth: 430).padding(24)
            case .loadingResults: ProgressView("Loading inventory results…")
            case .none: EmptyView()
            }
        }.frame(maxHeight: .infinity)
    }
    private func itemDetails(_ item: InventoryNode) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text(item.path).font(.callout).textSelection(.enabled)
                Text("\(InventoryNodePresentation.coverage(item)) · \(item.descendantFiles.formatted()) descendant files · \(item.descendantDirectories.formatted()) descendant folders\(item.isHardlinkAlias ? " · Hard-link alias: allocation counted at its owning entry" : "")")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Logical size: \(bytes(item.objectLogicalBytes ?? item.logicalBytes ?? item.previousLogicalBytes, node: item))" + (item.kind == .directory ? " · \(item.childCount.formatted()) direct items" : ""))
                    .font(.caption).foregroundStyle(.secondary)
                if let reason = item.statusReason { Text(reason).font(.caption).foregroundStyle(.secondary) }
                if item.isHardlinkAlias, let logical = item.objectLogicalBytes, let allocated = item.objectAllocatedBytes {
                    Text("File metadata: \(ByteCountFormatter.string(fromByteCount: logical, countStyle: .file)) logical · \(ByteCountFormatter.string(fromByteCount: allocated, countStyle: .file)) allocated. Its storage contribution is counted at the owning entry.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button(item.kind == .directory ? "Open folder" : "Show location") { open(item) }.accessibilityIdentifier("inventory.open")
        }.padding(.horizontal, 22).padding(.vertical, 10).accessibilityIdentifier("inventory.details")
    }
    private func bytes(_ value: Int64?, node: InventoryNode) -> String {
        InventoryNodePresentation.size(value, node: node) { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }
    }
    private func open(_ item: InventoryNode) {
        if item.kind == .directory { model.navigate(item) }
        else { model.showEnclosingFolder(of: item) }
    }
}

/// Answers "how much space do I have?" at the top of the storage browser: live free space when available,
/// otherwise the last recorded reading, labelled as such.
struct InventoryCapacitySummary: View {
    @ObservedObject var live: LiveCapacityMonitor
    let recorded: Measurement?
    var body: some View {
        let reading = live.state.reading
        let free = reading?.free ?? recorded?.free, used = reading?.used ?? recorded?.used
        if let free, let used {
            let total = free + used, severity = EventSeverity.capacity(free)
            HStack(alignment: .center, spacing: 24) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(reading == nil ? "Available · last recorded" : "Available now").font(.caption).foregroundStyle(.secondary)
                    Text(capacity(free)).font(StorageDesign.valueFont)
                }
                VStack(alignment: .leading, spacing: 6) {
                    ProgressView(value: Double(used), total: Double(max(total, 1))).progressViewStyle(.linear)
                        .tint(severity == .normal ? .accentColor : (severity == .warning ? .orange : .red))
                        .accessibilityLabel("Disk usage").accessibilityValue("\(capacity(used)) used of \(capacity(total))")
                    Text("\(capacity(used)) used of \(capacity(total))").font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }.frame(maxWidth: 280)
                if severity != .normal {
                    Label(severity == .critical ? "Very low space" : "Low space", systemImage: "exclamationmark.circle")
                        .font(.callout.weight(.medium)).foregroundStyle(severity == .critical ? .red : .orange)
                }
                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .combine).accessibilityIdentifier("inventory.capacity")
        }
    }
}
