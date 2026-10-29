import SwiftUI
import AppKit

/// Owns a bounded, resumable catalog review. Discovery runs on an actor; the main actor only publishes pages.
@MainActor final class CleanupReviewQueueController: ObservableObject {
    @Published private(set) var snapshot: CleanupReviewQueueSnapshot?
    @Published private(set) var loading = false
    @Published private(set) var reviewing = false
    @Published private(set) var error: String?
    @Published var selection = Set<Int64>()
    @Published var status: CleanupStatus? = .reviewCandidate
    @Published var kind: ArtifactKind?
    @Published var tool: ArtifactTool?
    @Published var sort = CleanupReviewQueueSort.indexedAllocated
    @Published var includesPotentialMatches = false
    @Published private(set) var inspectorNode: InventoryNode?
    @Published private(set) var freshnessNow = Date()
    let reader: InventoryReader
    let queue = CleanupReviewQueue()
    let environment: ArtifactEnvironment
    private var task: Task<Void, Never>?
    private var reviewTask: Task<Void, Never>?
    private var revision = 0
    private var reviewRevision = 0
    private var changeRevision = 0

    init(database: String) {
        reader = InventoryReader(path: database)
        var environment = ArtifactEnvironment.current()
        environment.ownData = (database as NSString).deletingLastPathComponent
        self.environment = environment
    }

    var rows: [CleanupReviewQueueEntry] {
        snapshot?.filtered(filter: .init(status: status, kind: kind, tool: tool, includesPotentialMatches: includesPotentialMatches || status == .insufficientEvidence), sort: sort, now: freshnessNow) ?? []
    }
    var selectedEntries: [CleanupReviewQueueEntry] { snapshot?.entries.filter { selection.contains($0.id) } ?? [] }
    var plan: CleanupReviewPlan { CleanupReviewPlan(entries: selectedEntries, now: freshnessNow) }
    var tools: [ArtifactTool] {
        Array(Set(snapshot?.entries.compactMap { $0.inspection?.classification?.tool } ?? [])).sorted { $0.rawValue < $1.rawValue }
    }

    /// The visible queue expires evidence even while the inventory is idle. This never recollects it.
    func advanceFreshness(to now: Date, cleanup: CleanupInspectorController? = nil) {
        freshnessNow = now
        if let snapshot { self.snapshot = snapshot.reevaluatingFreshness(at: now) }
        if let cleanup, let id = inspectorNode?.id,
           let entry = snapshot?.entries.first(where: { $0.id == id }),
           !entry.freshness.isFresh(now: now), let inspection = entry.inspection,
           let current = cleanup.inspection, current.nodeID == id, current.collectedAt == inspection.collectedAt,
           current.assessment?.status != .insufficientEvidence {
            if let expired = entry.inspectionForReview(at: now) { cleanup.acceptQueueReview(expired, node: entry.node) }
        }
    }

    /// Each press considers at most eight catalog pages. A larger inventory requires explicit continuation.
    func discover() {
        guard !loading else { return }
        task?.cancel(); revision += 1
        let revision = revision, queue = queue, reader = reader, environment = environment
        loading = true; error = nil
        task = Task { [weak self] in
            await queue.resume()
            do {
                for _ in 0..<8 {
                    try Task.checkCancellation()
                    let page = try await queue.discoverNext(reader: reader, environment: environment)
                    guard let self, self.revision == revision, !Task.isCancelled else { return }
                    self.publish(page)
                    if !page.progress.hasMore || page.progress.stopReason != nil { break }
                }
            } catch is CancellationError { }
            catch { if let self, self.revision == revision { self.error = error.localizedDescription } }
            if let self, self.revision == revision { self.loading = false }
        }
    }

    func cancel() {
        task?.cancel(); revision += 1; loading = false
        let revision = revision
        Task { [weak self, queue] in
            await queue.cancel()
            let page = await queue.snapshot()
            if let self, self.revision == revision { self.publish(page) }
        }
    }

    func restart() {
        guard !loading else { return }
        task?.cancel(); reviewTask?.cancel()
        revision += 1; reviewRevision += 1; changeRevision += 1
        selection = []; inspectorNode = nil; reviewing = false; error = nil; loading = true
        Task { [weak self, queue] in
            await queue.reset()
            guard let self else { return }
            self.snapshot = nil; self.loading = false
            self.discover()
        }
    }

    func inventoryChanged(cleanup: CleanupInspectorController) {
        guard let snapshot else { return }
        changeRevision += 1
        let revision = changeRevision
        let queue = queue, reader = reader
        Task { [weak self] in
            do {
                let batch = try await reader.changes(since: snapshot.journal, limit: 512)
                guard let self, self.changeRevision == revision else { return }
                let page = await queue.applyChanges(batch)
                guard self.changeRevision == revision else { return }
                self.publish(page)
                if !batch.changes.isEmpty || batch.mustResynchronize || batch.generationStale { self.reviewSelection(cleanup: cleanup) }
            } catch { if let self, self.changeRevision == revision { self.error = "Evidence freshness could not be checked: \(error.localizedDescription)" } }
        }
    }

    func reviewSelection(cleanup: CleanupInspectorController, preferredID: Int64? = nil) {
        reviewTask?.cancel(); reviewRevision += 1
        let preferred = preferredID.flatMap { selection.contains($0) ? $0 : nil }
            ?? inspectorNode.flatMap { selection.contains($0.id) ? $0.id : nil }
            ?? selection.sorted().first
        guard let id = preferred, let entry = selectedEntries.first(where: { $0.id == id }) else {
            inspectorNode = nil; reviewing = false; return
        }
        inspectorNode = entry.node
        cleanup.beginQueueReview(entry.node)
        reviewing = true
        let revision = reviewRevision, queue = queue, reader = reader, environment = environment
        reviewTask = Task { [weak self] in
            do {
                let entry = try await queue.refresh(nodeID: id, reader: reader, environment: environment)
                let page = await queue.snapshot()
                guard let self, self.reviewRevision == revision, !Task.isCancelled else { return }
                self.publish(page); self.inspectorNode = entry?.node
                if let entry, let inspection = entry.inspectionForReview(at: self.freshnessNow) { cleanup.acceptQueueReview(inspection, node: entry.node) }
                else { cleanup.update(nil) }
            } catch is CancellationError { }
            catch { if let self, self.reviewRevision == revision { self.error = "Review could not be refreshed: \(error.localizedDescription)"; cleanup.finishQueueReviewFailure() } }
            if let self, self.reviewRevision == revision { self.reviewing = false }
        }
    }

    func stop(cleanup: CleanupInspectorController) {
        cancel(); reviewTask?.cancel(); reviewRevision += 1; changeRevision += 1
        if reviewing { cleanup.finishQueueReviewFailure() }
        reviewing = false
    }

    private func publish(_ page: CleanupReviewQueueSnapshot) {
        freshnessNow = Date()
        snapshot = page.reevaluatingFreshness(at: freshnessNow)
        selection.formIntersection(Set(page.entries.map(\.id)))
    }
}

/// A destination inside Disk Inventory. It shares the existing Inspector and has no removal controls.
struct CleanupReviewQueueView: View {
    @ObservedObject var browser: InventoryBrowserModel
    @ObservedObject var queue: CleanupReviewQueueController
    @State private var showingPlan = false
    @State private var showingInspector = false
    @ViewState private var showingFilters = false

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                filters
                Divider()
                HStack(spacing: 0) {
                    table
                    if geometry.size.width >= 1_000, let node = queue.inspectorNode {
                        Divider()
                        InventoryInspectorView(browser: browser, explorer: browser.explorer, reviewSubject: node, showsTrash: false, usesQueueEvidence: true).frame(width: StorageDesign.inspectorWidth)
                    }
                }
                Divider()
                footer(compact: geometry.size.width < 1_000)
            }
        }
        .accessibilityIdentifier("inventory.reviewQueue")
        .onAppear { if queue.snapshot == nil { queue.discover() } }
        .task {
            queue.advanceFreshness(to: Date(), cleanup: browser.cleanup)
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                queue.advanceFreshness(to: Date(), cleanup: browser.cleanup)
            }
        }
        .onDisappear { queue.stop(cleanup: browser.cleanup) }
        .onChange(of: queue.selection) { old, selected in
            queue.reviewSelection(cleanup: browser.cleanup, preferredID: selected.subtracting(old).sorted().first)
        }
        .onChange(of: browser.revision) { _, _ in queue.inventoryChanged(cleanup: browser.cleanup) }
        .sheet(isPresented: $showingPlan) { CleanupReviewPlanView(plan: queue.plan) { showingPlan = false } }
        .sheet(isPresented: $showingInspector) {
            VStack(spacing: 0) {
                HStack { Text("Cleanup Inspector").font(.headline); Spacer(); Button("Done") { showingInspector = false }.keyboardShortcut(.cancelAction) }.padding()
                Divider()
                if let node = queue.inspectorNode {
                    InventoryInspectorView(browser: browser, explorer: browser.explorer, reviewSubject: node, showsTrash: false, usesQueueEvidence: true)
                } else { Text("Select an item to review.").padding() }
            }.frame(width: 420, height: 600)
        }
    }

    private var filters: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Review cleanup").font(.title2.weight(.semibold))
                    Text("Understand an item before deciding what to keep.").font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Refresh review") { queue.restart() }.disabled(queue.loading)
                    .help("Restart the bounded read-only review of the existing index. This does not scan or change files.")
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { assessmentFilter; filterButton; Spacer(minLength: 4); sortPicker }
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 12) { assessmentFilter; filterButton }
                    sortPicker
                }
            }
        }.padding(.horizontal, StorageDesign.gutter).padding(.vertical, 14)
    }
    private var filterButton: some View {
        Button { showingFilters.toggle() } label: { Label("Filters", systemImage: "line.3.horizontal.decrease") }
            .popover(isPresented: $showingFilters) {
                Form {
                    kindFilter; toolFilter
                    Toggle("Include potential matches awaiting evidence", isOn: $queue.includesPotentialMatches)
                    Text("Names and paths alone do not establish an item exists or is removable. Filters apply to this bounded review page.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }.formStyle(.grouped).frame(width: 400).padding(8)
            }
    }

    private var assessmentFilter: some View {
        Picker("Assessment", selection: $queue.status) {
            Text("All assessments").tag(CleanupStatus?.none)
            ForEach(CleanupStatus.allCases, id: \.self) { Text($0.title).tag(Optional($0)) }
        }.fixedSize().accessibilityIdentifier("inventory.reviewQueue.assessment")
    }
    private var kindFilter: some View {
        Picker("Type", selection: $queue.kind) {
            Text("All artifacts").tag(ArtifactKind?.none)
            ForEach(ArtifactKind.allCases, id: \.self) { Text($0.title).tag(Optional($0)) }
        }.fixedSize().accessibilityIdentifier("inventory.reviewQueue.type")
    }
    private var toolFilter: some View {
        Picker("Tool", selection: $queue.tool) {
            Text("All tools").tag(ArtifactTool?.none)
            ForEach(queue.tools, id: \.self) { Text($0.rawValue).tag(Optional($0)) }
        }.fixedSize().accessibilityIdentifier("inventory.reviewQueue.tool")
    }
    private var sortPicker: some View {
        Picker("Sort", selection: $queue.sort) {
            ForEach(CleanupReviewQueueSort.allCases, id: \.self) { Text($0.title).tag($0) }
        }.fixedSize().accessibilityIdentifier("inventory.reviewQueue.sort")
    }

    private var table: some View {
        Table(queue.rows, selection: $queue.selection) {
            TableColumn("Item") { entry in
                VStack(alignment: .leading, spacing: 5) {
                    Text(entry.inspection?.classification?.title ?? entry.node.name).font(.callout.weight(.medium)).lineLimit(1)
                    Text(entry.inspection?.classification?.kind.title ?? "Awaiting identification")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }.padding(.vertical, 5).help(entry.node.path)
            }.width(min: 180, ideal: 290, max: .infinity)
            TableColumn("Review status") { entry in
                VStack(alignment: .leading, spacing: 5) {
                    Text(entry.stage == .potentialMatch ? "Potential match" : (entry.status(at: queue.freshnessNow)?.title ?? "Insufficient evidence"))
                        .font(.callout.weight(.medium))
                    Text(entry.freshness.reasons(now: queue.freshnessNow).first ?? entry.inspection?.assessment?.reasons.first ?? "Select to read the evidence.")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }.padding(.vertical, 5)
            }.width(min: 175, ideal: 250, max: .infinity)
            TableColumn("Storage") { entry in
                VStack(alignment: .trailing, spacing: 5) {
                    Text(entry.indexedAllocatedBytes.map(AtlasText.bytes) ?? "Not measured").font(.callout.weight(.semibold).monospacedDigit())
                    Text(entry.recoverableBytes(at: queue.freshnessNow).map { "≈ " + AtlasText.bytes($0) + " may be recoverable" } ?? "Recovery unknown")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }.padding(.vertical, 5)
                    .help("Indexed size is not physical recovery. APFS sharing and snapshots may retain data; moving to Trash may not increase available space.")
            }.width(min: 130, ideal: 175)
        }
        .tableStyle(.inset(alternatesRowBackgrounds: false))
        .overlay { if queue.rows.isEmpty { emptyState } }
        .accessibilityIdentifier("inventory.reviewQueue.table")
        .contextMenu(forSelectionType: Int64.self) { ids in
            if let id = ids.sorted().first, let entry = queue.snapshot?.entries.first(where: { $0.id == id }) {
                Button("Review evidence") { queue.selection = [id]; queue.reviewSelection(cleanup: browser.cleanup); showingInspector = true }
                revealMenu(entry.node)
            }
        } primaryAction: { ids in
            if let id = ids.sorted().first { queue.selection = [id]; queue.reviewSelection(cleanup: browser.cleanup); showingInspector = true }
        }
    }

    private var emptyState: some View {
        let expiredEvidence = queue.snapshot?.entries.contains { $0.stage == .verifiedArtifact && !$0.freshness.isFresh(now: queue.freshnessNow) } == true
        return VStack(alignment: .center, spacing: 12) {
            if queue.loading { ProgressView().controlSize(.small) }
            else { Image(systemName: expiredEvidence ? "arrow.clockwise.circle" : "checklist").font(.system(size: 28)).foregroundStyle(.secondary) }
            Text(queue.loading ? "Reviewing your indexed items…" : expiredEvidence ? "These items need a fresh review" : "No suggestions on this page")
                .font(.title3.weight(.semibold))
            Text(expiredEvidence
                 ? "The saved evidence is out of date. See all assessments to understand what was found, or refresh the review."
                 : "Some items may be protected or need more evidence. You can inspect all assessments or continue through the index.")
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 390)
            if !queue.loading {
                HStack(spacing: 12) {
                    Button("See all assessments") { queue.status = nil; queue.kind = nil; queue.tool = nil; queue.includesPotentialMatches = true }
                        .buttonStyle(.bordered)
                    if expiredEvidence { Button("Refresh review") { queue.restart() } }
                }
            }
        }.padding(24)
    }

    private func footer(compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            if let error = queue.error {
                Label(error, systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
            HStack(spacing: 10) {
                if queue.loading { ProgressView().controlSize(.mini) }
                Text(queue.snapshot?.progress.text ?? "Reviewing existing indexed metadata; no filesystem scan.").font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 4)
                if queue.loading { Button("Cancel") { queue.cancel() } }
                else if queue.snapshot?.progress.hasMore != false {
                    Button(queue.snapshot?.progress.stopReason?.contains("memory budget") == true ? "Next artifact page" : "Continue discovery") { queue.discover() }
                        .help("Continues from the indexed cursor. At the artifact memory limit, this replaces the retained page and its selection; earlier artifacts are not kept in memory. Sorting and filtering cover the current page.")
                }
            }
            Text(queue.snapshot?.progress.stopReason ?? "Coverage is incomplete. Discovery is paginated and bounded; unindexed or inaccessible locations are not assessed.")
                .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let pagedOut = queue.snapshot?.progress.pagedOutEntries, pagedOut > 0 {
                Text("\(pagedOut.formatted()) earlier artifacts were released from memory. Filters, sorting and selection apply to the current page.").font(.caption2).foregroundStyle(.secondary)
            }
            HStack(spacing: 10) {
                Text("\(queue.selection.count) selected · Review only; nothing is moved here").font(.caption).foregroundStyle(.secondary)
                if queue.reviewing { ProgressView().controlSize(.mini); Text("Refreshing selected evidence…").font(.caption).foregroundStyle(.secondary) }
                if let node = queue.inspectorNode {
                    if compact { Button("Review evidence") { showingInspector = true } }
                    Menu("Reveal in…") { revealMenu(node) }
                }
                Spacer()
                Button("Review plan…") { showingPlan = true }.disabled(queue.plan.count == 0)
                    .help("An informational plan for selected review candidates. It has no Trash or execution action.")
            }.controlSize(.small)
        }.padding(.horizontal, 18).padding(.vertical, 10)
    }

    @ViewBuilder private func revealMenu(_ node: InventoryNode) -> some View {
        Button("Reveal in Navigator") { reveal(node, visualization: nil) }
        Button("Reveal in Atlas") { reveal(node, visualization: .atlas) }
        Button("Reveal in Living Tree") { reveal(node, visualization: .tree) }
    }

    private func reveal(_ node: InventoryNode, visualization: InventoryVisualization?) {
        if let visualization {
            ViewerStore.viewPreferences.set(visualization.rawValue, forKey: "inventory.explorer.visualization")
            ViewerStore.viewPreferences.set(true, forKey: "inventory.explorer.showMap")
        }
        ViewerStore.viewPreferences.set(false, forKey: "inventory.explorer.technical")
        browser.revealReviewCandidate(node)
    }
}

struct CleanupReviewPlanView: View {
    let plan: CleanupReviewPlan
    let done: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Text("Cleanup review plan").font(.headline); Spacer(); Button("Done", action: done).keyboardShortcut(.cancelAction) }
            Text("Informational only. This plan cannot move or delete anything.").font(.callout).foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text("\(plan.count) review candidates · Indexed allocation \(plan.indexedAllocatedBytes.map(AtlasText.bytes) ?? "Unknown")").font(.callout.weight(.medium))
                    switch plan.recovery {
                    case .estimated(let bytes, let basis): Text("Estimated recoverable: ≈ \(AtlasText.bytes(bytes)). \(basis)").font(.caption)
                    case .unknown: Text("Total recoverable storage cannot be determined.").font(.callout.weight(.medium))
                    }
                    Text("\(plan.unknownRecoveryCount) items have unknown recovery amounts. Indexed allocation may share APFS blocks; moving to Trash does not establish physical recovery.").font(.caption).foregroundStyle(.secondary)
                    ForEach(plan.items) { entry in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(entry.node.path).font(.callout).textSelection(.enabled)
                            Text("\(entry.inspection?.classification?.tool.rawValue ?? "Unknown tool") · Indexed \(entry.indexedAllocatedBytes.map(AtlasText.bytes) ?? "Unknown") · Recoverable \(entry.recoverableBytes.map { "≈ " + AtlasText.bytes($0) } ?? "Unknown")")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    notes("Overlapping paths excluded from totals", plan.excludedOverlaps)
                    notes("Selections excluded because they are not review candidates", plan.excludedNonCandidates)
                    notes("Dependencies", plan.dependencies)
                    notes("Risks and uncertainty", plan.risks)
                    notes("Require revalidation", plan.requiresRevalidation)
                    notes("Protected related artifacts", plan.protectedRelated.map { "\($0.path) · \($0.roles.map(\.rawValue).joined(separator: ", "))" })
                    Text("All items require fresh identity, protection, Git and active-use checks before any separately requested single-item Trash action.").font(.caption).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
        }.padding(20).frame(width: 620, height: 580).accessibilityIdentifier("inventory.reviewQueue.plan")
    }
    @ViewBuilder private func notes(_ title: String, _ values: [String]) -> some View {
        if !values.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.caption.weight(.semibold))
                ForEach(values, id: \.self) { Text("· " + $0).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
            }
        }
    }
}
