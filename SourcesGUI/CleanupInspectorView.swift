import SwiftUI
import AppKit

/// Runs Cleanup Inspector evidence collection for the Inspector's subject: off the main thread, one at a time, and
/// only for items a detector or protection rule could apply to (ordinary items cost a name check and at most two
/// lstat calls). A newer selection always wins: results for an earlier one are dropped. When the subject's
/// inventory row changes (identity, size, measurement state), its evidence is collected again; when the subject
/// disappears, no recommendation is kept for it.
@MainActor final class CleanupInspectorController: ObservableObject {
    @Published private(set) var inspection: ArtifactInspection?
    /// The node being examined now (shows a progress line).
    @Published private(set) var inspecting: Int64?
    /// The previous subject disappeared from the inventory; the selection moved on.
    @Published private(set) var vanished: String?
    @Published private(set) var preview: CleanupPreview?
    @Published private(set) var previewLoading = false
    /// The subject was checked and is not a kind the inspector recognizes (shown as such, not hidden).
    @Published private(set) var ordinary: Int64?
    /// The last Move to Trash, for the confirmation line.
    @Published private(set) var trashResult: (name: String, outcome: CleanupTrashOutcome)?
    @Published private(set) var trashing = false
    @Published private(set) var preparingTrash = false
    /// Items checked so far by the running preparation (reported every few hundred items; 0 before the first report).
    @Published private(set) var preparationChecked = 0
    @Published private(set) var trashConfirmation: CleanupTrashConfirmationToken?

    private let reader: InventoryReader
    private let database: String
    let environment: ArtifactEnvironment
    /// Replaceable for tests: the move to the Trash.
    var trash: (@Sendable (URL) throws -> URL?)?
    /// False in QA builds: their catalog is a copy, but the paths in it are real files.
    var allowsTrash = true
    /// Evidence older than this is collected again when the inventory reports changes (not on every update).
    static let refreshInterval: TimeInterval = 20
    /// Replaceable for tests: the inspection itself.
    var inspect: @Sendable (InventoryNode, ArtifactEnvironment) -> ArtifactInspection = { node, environment in ArtifactInspector.inspect(node, environment: environment) }
    /// Replaceable for deterministic preview cancellation checks; the default walk stays off the main actor.
    var previewEstimate: @Sendable (InventoryNode) async -> ArtifactRecoveryEstimate? = { node in
        await Task.detached(priority: .userInitiated) {
            node.kind == .directory ? ArtifactRecoveryEstimate.measure(node.path, probe: ArtifactProbe(budget: .init(entries: 20_000, reads: 0, seconds: 1.5))) : nil
        }.value
    }
    private var task: Task<Void, Never>?
    private var previewTask: Task<Void, Never>?
    private var preparationTask: Task<Void, Never>?
    private var preparationRevision = 0
    private var token = 0
    private var fingerprint: String?
    private var subject: (id: Int64, name: String, identity: InventoryIdentity, path: String)?
    private(set) var statistics = Statistics()

    struct Statistics: Equatable { var inspections = 0, quickSkips = 0, discarded = 0; var lastSeconds = 0.0 }

    init(database: String, environment: ArtifactEnvironment = .current()) {
        reader = InventoryReader(path: database); self.database = database
        var environment = environment
        if environment.ownData == nil { environment.ownData = (database as NSString).deletingLastPathComponent }
        self.environment = environment
    }

    /// What identifies the evidence's validity: a change to any of these invalidates it.
    static func fingerprint(_ node: InventoryNode) -> String {
        "\(node.id)|\(node.identity.stableKey)|\(node.path)|\(node.status.rawValue)|\(node.coverageState)|\(InventoryMapPlan.weight(node) ?? -1)|\(node.measuredAt?.timeIntervalSince1970 ?? 0)|\(node.generation)|\(node.listingState ?? "")"
    }

    /// The Inspector's subject changed (or its inventory row did). `exists` says whether an earlier subject is still in
    /// the inventory, to tell a vanished item apart from a new selection.
    func update(_ node: InventoryNode?, exists: (Int64) -> Bool = { _ in true }) {
        let print = node.map(Self.fingerprint)
        guard print != fingerprint else { return }
        fingerprint = print
        if let previous = subject, previous.id != node?.id { vanished = exists(previous.id) ? nil : previous.name }
        subject = node.map { ($0.id, $0.parentID == nil ? "Startup Data" : $0.name, $0.identity, $0.path) }
        start(node)
    }

    /// Collects the evidence again (a manual refresh).
    func refresh(_ node: InventoryNode?) { fingerprint = node.map(Self.fingerprint); start(node) }

    /// Queue discovery already owns the bounded evidence collection. Feed its result into this same Inspector.
    func beginQueueReview(_ node: InventoryNode) {
        let sameSubject = subject?.id == node.id && subject?.identity == node.identity && subject?.path == node.path
        task?.cancel(); token += 1; cancelTrashConfirmation()
        fingerprint = Self.fingerprint(node)
        subject = (node.id, node.name, node.identity, node.path)
        // As with an ordinary refresh, keep this item's content in place while rechecking it.
        // Removing the evidence and preview collapses the scroll document and clamps its offset.
        if !sameSubject || inspection?.nodeID != node.id { inspection = nil; closePreview() }
        else if previewNode != nil { previewNode = node }
        ordinary = nil; inspecting = node.id; vanished = nil
    }

    func acceptQueueReview(_ result: ArtifactInspection, node: InventoryNode) {
        guard subject?.id == node.id else { return }
        if subject?.identity != node.identity || subject?.path != node.path { closePreview() }
        else if previewNode != nil { previewNode = node }
        subject = (node.id, node.name, node.identity, node.path)
        fingerprint = Self.fingerprint(node)
        finish(result, token: token, seconds: result.elapsed)
    }

    func finishQueueReviewFailure() {
        inspecting = nil; fingerprint = nil; inspection = nil; ordinary = nil
        closePreview()
    }

    /// The inventory reported changes: evidence older than `refreshInterval` is collected again. While indexing runs
    /// these reports are frequent; refreshing on each would keep re-running inspections.
    func inventoryChanged(_ node: InventoryNode?) {
        guard let node, let inspection, inspection.nodeID == node.id, Date().timeIntervalSince(inspection.collectedAt) >= Self.refreshInterval else { return }
        refresh(node)
    }

    private func start(_ node: InventoryNode?) {
        task?.cancel()
        cancelTrashConfirmation()
        token += 1
        guard let node else { inspection = nil; inspecting = nil; ordinary = nil; closePreview(); return }
        // The same subject keeps its evidence and open preview on screen until the new result replaces them (the
        // Inspector does not shrink and lose its scroll position); a different subject starts clean.
        if inspection?.nodeID != node.id { inspection = nil; closePreview() }
        if trashResult != nil && subject?.id != node.id { trashResult = nil }
        let subject = ArtifactSubject(nodeID: node.id, path: node.path, kind: node.kind, identity: node.identity)
        guard ArtifactInspector.mightApply(subject, environment: environment) else { inspection = nil; inspecting = nil; ordinary = node.id; closePreview(); statistics.quickSkips += 1; return }
        ordinary = nil
        inspecting = node.id
        let token = token, environment = environment, inspect = inspect
        task = Task.detached(priority: .userInitiated) { [weak self] in
            let started = Date()
            let result = inspect(node, environment)
            await self?.finish(result, token: token, seconds: Date().timeIntervalSince(started))
        }
    }

    /// Publishes a result only if it is still for the current subject (a newer selection always wins).
    private func finish(_ result: ArtifactInspection, token: Int, seconds: TimeInterval) {
        guard token == self.token else { statistics.discarded += 1; return }
        inspection = result; inspecting = nil
        ordinary = result.identity == .verified && result.classification == nil && result.assessment == nil ? result.nodeID : nil
        statistics.inspections += 1; statistics.lastSeconds = seconds
        // Invalidation cancels a pending first preview as well as an already visible preview.
        if result.assessment?.status != .reviewCandidate { closePreview() }
        else if let node = previewNode, node.id == result.nodeID, preview != nil || previewLoading {
            loadPreview(node, quietly: true)
        }
    }

    private var previewNode: InventoryNode?

    /// The read-only cleanup preview: the largest entries from the inventory and a bounded walk for a recovery estimate.
    @discardableResult func loadPreview(_ node: InventoryNode, quietly: Bool = false) -> Task<Void, Never>? {
        guard let inspection, inspection.nodeID == node.id, inspection.assessment?.status == .reviewCandidate else { return nil }
        previewTask?.cancel()
        previewNode = node
        if !quietly { previewLoading = true }
        let token = token, reader = reader, previewEstimate = previewEstimate
        let loadingTask = Task { [weak self] in
            var children = [InventoryNode](), complete = true
            if node.kind == .directory, let page = try? await reader.explorerChildren(parentID: node.id, limit: 12) {
                children = page.items; complete = page.next == nil
            }
            let estimate = await previewEstimate(node)
            guard let self, token == self.token, !Task.isCancelled else { return }
            self.preview = CleanupPreview(inspection: inspection, node: node, children: children, childrenComplete: complete, estimate: estimate)
            self.previewLoading = false
        }
        previewTask = loadingTask
        return loadingTask
    }

    func closePreview() { previewTask?.cancel(); previewTask = nil; preview = nil; previewLoading = false; previewNode = nil }

    // MARK: Move to Trash (explicit, one item)

    /// Prepare the exact selected item off the main actor before presenting its native confirmation.
    @discardableResult func prepareTrash(_ node: InventoryNode) -> Task<Void, Never>? {
        guard allowsTrash, !preparingTrash, !trashing,
              subject?.id == node.id, fingerprint == Self.fingerprint(node) else { return nil }
        cancelTrashConfirmation()
        trashResult = nil; reconciliationError = nil; preparingTrash = true; preparationChecked = 0
        let revision = preparationRevision, selected = Self.fingerprint(node), environment = environment
        let report: @Sendable (Int) -> Void = { [weak self] checked in
            Task { @MainActor [weak self] in if let self, self.preparingTrash, self.preparationRevision == revision { self.preparationChecked = checked } }
        }
        let work = Task.detached(priority: .userInitiated) { CleanupTrashPolicy.prepare(node: node, environment: environment, progress: report) }
        let preparation = Task { [weak self] in
            let result = await withTaskCancellationHandler(operation: { await work.value }, onCancel: { work.cancel() })
            guard let self else {
                if case .ready(let confirmation) = result { CleanupTrashPolicy.cancel(confirmation) }
                return
            }
            guard !Task.isCancelled, revision == self.preparationRevision,
                  self.fingerprint == selected, self.subject?.id == node.id else {
                if revision == self.preparationRevision { self.preparingTrash = false; self.preparationTask = nil }
                if case .ready(let confirmation) = result { CleanupTrashPolicy.cancel(confirmation) }
                return
            }
            self.preparingTrash = false; self.preparationTask = nil
            switch result {
            case .ready(let confirmation): self.trashConfirmation = confirmation
            case .blocked(let reason): self.trashResult = (node.name, .refused(reason))
            }
        }
        preparationTask = preparation
        return preparation
    }

    func cancelTrashConfirmation() {
        preparationRevision += 1
        preparationTask?.cancel(); preparationTask = nil; preparingTrash = false
        if let confirmation = trashConfirmation { CleanupTrashPolicy.cancel(confirmation) }
        trashConfirmation = nil
    }

    func moveToTrash(_ confirmation: CleanupTrashConfirmationToken, overrideAccepted: Bool) {
        let selected = Self.fingerprint(confirmation.node)
        // A duplicate callback must not cancel the token already submitted to the executor.
        guard !trashing else { return }
        guard allowsTrash, !preparingTrash, trashConfirmation === confirmation,
              subject?.id == confirmation.node.id, fingerprint == selected else {
            CleanupTrashPolicy.cancel(confirmation)
            trashResult = (confirmation.node.name, .refused(CleanupTrashPolicy.unavailableReason))
            return
        }
        trashConfirmation = nil
        trashing = true; reconciliationError = nil
        let environment = environment, trash = trash, database = database
        let node = confirmation.node
        Task { [weak self] in
            let outcome = await Task.detached(priority: .userInitiated) {
                CleanupTrashPolicy.perform(confirmation: confirmation, overrideAccepted: overrideAccepted, environment: environment, trash: trash)
            }.value
            var refreshFailure: String?
            // Failed native calls/result checks may have partially moved the item. Reconcile without retrying.
            if outcome.needsReconciliation {
                let parent = (node.path as NSString).deletingLastPathComponent
                do { _ = try await Task.detached(priority: .utility) { try InventoryRequests.enqueue(database: database, action: "refresh", path: parent) }.value }
                catch { refreshFailure = String(describing: error) }
            }
            guard let self else { return }
            self.trashing = false
            self.trashResult = (node.name, outcome)
            self.reconciliationError = refreshFailure
            if outcome.needsReconciliation, self.fingerprint == selected, self.subject?.id == node.id {
                self.inspection = nil; self.ordinary = nil; self.inspecting = nil; self.fingerprint = nil
                self.closePreview()
                if case .moved = outcome { self.vanished = node.name }
            }
        }
    }

    @Published private(set) var reconciliationError: String?

    /// Advisory visibility only. Preparation repeats all mandatory protection and identity checks.
    func trashDecision(_ node: InventoryNode) -> CleanupTrashDecision {
        guard allowsTrash else { return .blocked("Not available in QA builds: the catalog is a copy, but its paths are real files.") }
        if let runtime = environment.qaRuntime {
            do { try runtime.validateTrash(node.path) } catch { return .blocked(String(describing: error)) }
        }
        let result = inspection?.nodeID == node.id ? inspection : nil
        return CleanupTrashPolicy.decide(node: node, inspection: result,
                                        examined: inspecting != node.id && (result != nil || ordinary == node.id), home: environment.home)
    }

    /// A mutable node and an acknowledgment are not the native sheet's explicit, prepared authorization.
    func moveToTrash(_ node: InventoryNode, overrideAccepted: Bool) {
        trashResult = (node.name, .refused(CleanupTrashPolicy.unavailableReason))
    }

}

/// The Inspector's Cleanup section: identity, assessment, evidence, storage impact, risks and the read-only preview.
/// Shown only for recognized artifacts and protected items; ordinary items keep the Inspector as it was.
struct CleanupInspectorSection: View {
    @ObservedObject var cleanup: CleanupInspectorController
    let node: InventoryNode
    var showsTrash = true
    @State private var showAllEvidence = false
    @State private var showLimitations = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let vanished = cleanup.vanished {
                Label("\(vanished) is no longer present; the selection moved to its folder.", systemImage: "info.circle")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if cleanup.inspecting == node.id && cleanup.inspection?.nodeID != node.id {
                Divider()
                HStack(spacing: 6) { ProgressView().controlSize(.mini); Text("Examining…").font(.caption).foregroundStyle(.secondary) }
                    .accessibilityIdentifier("inventory.cleanup.examining")
            } else if let inspection = cleanup.inspection, inspection.nodeID == node.id, let shown = CleanupInspectorPresentation(inspection, formatter: AtlasText.bytes) {
                Divider()
                content(shown, inspection: inspection)
            } else if cleanup.ordinary == node.id {
                Divider()
                VStack(alignment: .leading, spacing: 4) {
                    Text("CLEANUP REVIEW").font(.caption2.weight(.semibold)).foregroundStyle(.tertiary).tracking(0.6)
                    Text("Not a recognized artifact").font(.callout.weight(.medium))
                    Text("Cleanup review recognizes app installations (Claude Code, Codex), development dependencies and build output, Python environments and caches, Git worktrees, agent session history and package caches.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    if showsTrash { trashArea }
                }
                .accessibilityElement(children: .contain).accessibilityIdentifier("inventory.cleanup")
            }
            if showsTrash, let result = cleanup.trashResult { trashResultLine(result) }
        }
        .onChange(of: node.id) { _, _ in showAllEvidence = false; showLimitations = false }
    }

    @ViewBuilder private func content(_ shown: CleanupInspectorPresentation, inspection: ArtifactInspection) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("CLEANUP REVIEW").font(.caption2.weight(.semibold)).foregroundStyle(.tertiary).tracking(0.6)
                Text(shown.title).font(.callout.weight(.semibold)).lineLimit(2).truncationMode(.middle)
                Text(shown.subtitle).font(.caption).foregroundStyle(.secondary)
                if !shown.characteristics.isEmpty { Text("\(shown.characteristics) · \(shown.confidence)").font(.caption).foregroundStyle(.tertiary) }
            }
            assessment(shown)
            if !shown.evidence.isEmpty || shown.hasMoreEvidence { evidence(shown) }
            storage(shown)
            if !shown.risks.isEmpty { list("Risks and dependencies", shown.risks) }
            if !shown.related.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Related").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    ForEach(shown.related, id: \.label) { row in
                        HStack(alignment: .firstTextBaseline) { Text(row.label).font(.caption); Spacer(minLength: 6); Text(row.value).font(.caption).foregroundStyle(.secondary) }
                    }
                }
            }
            if shown.offersPreview { previewArea }
            if showsTrash { trashArea }
            HStack(spacing: 6) {
                Text(shown.collected).font(.caption).foregroundStyle(.tertiary)
                Spacer()
                Button("Check Again", systemImage: "arrow.clockwise") { cleanup.refresh(node) }
                    .buttonStyle(.borderless).font(.caption).help("Collect the evidence again").accessibilityLabel("Check Again")
            }
        }
        .accessibilityElement(children: .contain).accessibilityIdentifier("inventory.cleanup")
    }

    private func assessment(_ shown: CleanupInspectorPresentation) -> some View {
        let (symbol, tint): (String, Color) = {
            switch shown.status {
            case .preserve: return ("checkmark.shield", .green)
            case .reviewCandidate: return ("eye", .accentColor)
            case .insufficientEvidence: return ("questionmark.circle", .secondary)
            case .protected: return ("lock", .secondary)
            }
        }()
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: symbol).font(.callout).foregroundStyle(tint.opacity(0.85))
                Text(shown.statusTitle).font(.callout.weight(.medium))
            }
            .accessibilityElement(children: .combine).accessibilityLabel("Assessment: \(shown.statusTitle)")
            Text(shown.summary).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            ForEach(shown.reasons, id: \.self) { bullet($0) }
        }
    }

    private func evidence(_ shown: CleanupInspectorPresentation) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Evidence").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            ForEach(showAllEvidence ? shown.allEvidence : shown.evidence, id: \.self) { bullet($0) }
            if shown.hasMoreEvidence {
                Button(showAllEvidence ? "Show less" : "Show all evidence (\(shown.allEvidence.count))") { showAllEvidence.toggle() }
                    .buttonStyle(.link).font(.caption)
            }
        }
    }

    private func storage(_ shown: CleanupInspectorPresentation) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Storage impact").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 3) {
                ForEach(shown.storage, id: \.label) { row in
                    GridRow { Text(row.label).font(.caption).foregroundStyle(.secondary); Text(row.value).font(.caption.monospacedDigit()).textSelection(.enabled) }
                }
                GridRow { Text("Recoverable").font(.caption).foregroundStyle(.secondary); Text(shown.recovery).font(.caption.monospacedDigit()) }
            }
            if let basis = shown.recoveryBasis { Text(basis).font(.caption).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true) }
            Button(showLimitations ? "Hide accounting notes" : "About these sizes") { showLimitations.toggle() }.buttonStyle(.link).font(.caption)
            if showLimitations { ForEach(ArtifactStorage.limitations, id: \.self) { bullet($0) } }
        }
    }

    @ViewBuilder private var previewArea: some View {
        if let preview = cleanup.preview, cleanup.inspection?.nodeID == node.id {
            CleanupPreviewView(preview: preview) { cleanup.closePreview() }
        } else {
            HStack(spacing: 6) {
                Button("Show cleanup preview") { cleanup.loadPreview(node) }.font(.caption).disabled(cleanup.previewLoading)
                if cleanup.previewLoading { ProgressView().controlSize(.mini) }
            }
            .help("What a cleanup would affect. This preview does not move or change anything.")
        }
    }

    // MARK: Move to Trash

    @ViewBuilder private var trashArea: some View {
        switch cleanup.trashDecision(node) {
        case .blocked(let why):
            if cleanup.inspection?.nodeID == node.id || cleanup.ordinary == node.id {
                refusal(why, prefix: "Can't be moved to the Trash")
            }
        case .allowed:
            HStack(spacing: 6) {
                Button { cleanup.prepareTrash(node) } label: { Text("Move to Trash…") }
                    .buttonStyle(.link).font(.caption).disabled(cleanup.trashing || cleanup.preparingTrash)
                    .help("Validates this exact item, then asks for confirmation before moving it to the macOS Trash.")
                if cleanup.trashing || cleanup.preparingTrash { ProgressView().controlSize(.mini) }
                if cleanup.preparingTrash {
                    Text(Self.checkingText(cleanup.preparationChecked, node: node)).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                        .accessibilityIdentifier("cleanup.trashProgress")
                    Button("Stop") { cleanup.cancelTrashConfirmation() }.buttonStyle(.link).font(.caption)
                        .help("Stops checking. Nothing is moved.").accessibilityIdentifier("cleanup.trashStop")
                }
            }
            .sheet(isPresented: Binding(get: { cleanup.trashConfirmation != nil }, set: { if !$0 { cleanup.cancelTrashConfirmation() } })) {
                if let confirmation = cleanup.trashConfirmation {
                    CleanupTrashConfirmation(node: confirmation.node, decision: confirmation.decision, status: confirmation.inspection.assessment?.status, inspection: confirmation.inspection, preparedAt: confirmation.preparedAt) { accepted in
                        if let accepted { cleanup.moveToTrash(confirmation, overrideAccepted: accepted) }
                        else { cleanup.cancelTrashConfirmation() }
                    }
                    .id(ObjectIdentifier(confirmation))
                }
            }
        }
    }

    /// Items checked so far, against the inventory's indexed count when there is one (labelled "about": it can be stale).
    static func checkingText(_ checked: Int, node: InventoryNode) -> String {
        let indexed = node.kind == .directory ? Int(node.descendantFiles + node.descendantDirectories + 1) : 1
        guard checked > 0 else { return "Checking every item inside before moving…" }
        return indexed > checked ? "Checked \(checked.formatted()) of about \(indexed.formatted()) items…" : "Checked \(checked.formatted()) items…"
    }

    /// A refusal: what kind of restriction it is, the exact reason, and the next step where there is one.
    private func refusal(_ why: String, prefix: String) -> some View {
        let guidance = CleanupTrashGuidance.explain(why)
        return VStack(alignment: .leading, spacing: 3) {
            Text("\(prefix) · \(guidance.title)").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Text(why).font(.caption2).foregroundStyle(.secondary).textSelection(.enabled)
            if let next = guidance.nextStep { Text(next).font(.caption2).foregroundStyle(.primary) }
        }
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("cleanup.trashRefusal")
    }

    @ViewBuilder private func trashResultLine(_ result: (name: String, outcome: CleanupTrashOutcome)) -> some View {
        if case .refused(let why) = result.outcome {
            refusal(why, prefix: "“\(result.name)” was not moved")
        } else { trashOutcomeLine(result) }
    }

    private func trashOutcomeLine(_ result: (name: String, outcome: CleanupTrashOutcome)) -> some View {
        let text: String, symbol: String
        switch result.outcome {
        case .moved(let path): text = "Moved “\(result.name)” to the macOS Trash. " + (path.map { "Destination: \(CleanupTrashConfirmation.displayPath($0)). " } ?? "") + "Finder Put Back has not been verified. Available disk space may not increase. " + (cleanup.reconciliationError.map { "The inventory refresh request failed: \($0). Refresh this folder to reconcile it." } ?? "The inventory will update after it rechecks the folder."); symbol = "trash"
        case .refused(let why): text = "“\(result.name)” was not moved. \(why)"; symbol = "exclamationmark.circle"
        case .failed(let why): text = "Move to Trash for “\(result.name)” could not be confirmed: \(why) " + (cleanup.reconciliationError.map { "The inventory refresh request also failed: \($0). Refresh the folder manually." } ?? "An inventory refresh was requested; no automatic retry will occur."); symbol = "exclamationmark.triangle"
        }
        return Label(text, systemImage: symbol).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }

    private func list(_ title: String, _ items: [String]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            ForEach(items, id: \.self) { bullet($0) }
        }
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Text("·").font(.caption).foregroundStyle(.tertiary)
            Text(text).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
        }
    }
}

/// The read-only preview: what a future cleanup operation would affect. It offers no action.
struct CleanupPreviewView: View {
    let preview: CleanupPreview
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Cleanup preview").font(.caption.weight(.semibold))
                Spacer()
                Button("Close", action: close).buttonStyle(.link).font(.caption)
            }
            Text("Preview only. This preview does not move or change anything.").font(.caption2).foregroundStyle(.secondary)
            field("Target", preview.target, selectable: true)
            field("Identity", preview.identity)
            field("Tool", preview.tool)
            field("Classification", preview.classification)
            field("Indexed size", (preview.indexedBytes.map(AtlasText.bytes) ?? "Unknown") + " · \(preview.measurement)")
            if !preview.contents.isEmpty || preview.contentsTotal != nil {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Contents").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                    ForEach(preview.contents, id: \.name) { entry in
                        HStack { Text(entry.name).font(.caption2).lineLimit(1).truncationMode(.middle); Spacer(); Text(entry.bytes.map(AtlasText.bytes) ?? "—").font(.caption2.monospacedDigit()).foregroundStyle(.secondary) }
                    }
                    if let total = preview.contentsTotal {
                        Text(preview.contentsComplete && Int64(preview.contents.count) >= total ? "All \(total.formatted()) items listed." : "Largest \(preview.contents.count) of \(total.formatted()) items (not an exhaustive listing).")
                            .font(.caption2).foregroundStyle(.tertiary)
                    }
                }
            }
            if !preview.preserved.isEmpty { section("Must be preserved", preview.preserved.map { "\($0.label) (\($0.roles.map(\.rawValue).joined(separator: ", ")))" }) }
            if !preview.references.isEmpty { section("Known references", preview.references) }
            if !preview.risks.isEmpty { section("Unresolved risks", preview.risks) }
            if !preview.unknowns.isEmpty { section("Unknown", preview.unknowns) }
            switch preview.recovery {
            case .estimated(let bytes, let basis): section("Estimated recoverable", ["About \(AtlasText.bytes(bytes)) (an estimate, not a verified result)", basis] + (preview.recoveryDetail.map { [$0] } ?? []))
            case .unknown(let why): section("Recoverable", [why] + (preview.recoveryDetail.map { [$0] } ?? []))
            }
            section("Storage accounting", preview.limitations)
            Text("Evidence collected \(preview.evidenceCollected.formatted(date: .abbreviated, time: .standard)); it is collected again when the inventory changes.").font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(10)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .accessibilityElement(children: .contain).accessibilityIdentifier("inventory.cleanup.preview")
    }

    private func field(_ label: String, _ value: String, selectable: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            Text(value).font(.caption2).textSelection(.enabled).lineLimit(selectable ? 6 : 3).truncationMode(.middle).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func section(_ title: String, _ items: [String]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            ForEach(items, id: \.self) { Text("· \($0)").font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
        }
    }
}

/// The confirmation before a move to the Trash: the exact item, what the review found, and, when the review did not mark
/// it as a review candidate, an explicit acknowledgement before the move is possible. Cancel is the default.
struct CleanupTrashConfirmation: View {
    let node: InventoryNode
    let decision: CleanupTrashDecision
    let status: CleanupStatus?
    var inspection: ArtifactInspection? = nil
    var preparedAt: Date? = nil
    /// nil: cancelled; otherwise whether the override was accepted.
    let done: (Bool?) -> Void
    @State private var accepted = false

    var body: some View {
        let (override, rawWarnings): (Bool, [String]) = { if case .allowed(let o, let w) = decision { return (o, w) }; return (true, []) }()
        let warnings = CleanupTrashGuidance.presentedWarnings(rawWarnings)
        VStack(alignment: .leading, spacing: 12) {
            ScrollView {
            VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: override ? "exclamationmark.triangle.fill" : "trash").font(.title2).foregroundStyle(override ? .orange : .secondary)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Move “\(Self.displayPath(node.name))” to the Trash?").font(.headline)
                    Text(verbatim: Self.displayPath(node.path)).font(.caption).foregroundStyle(.secondary).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    Text("\(node.kind == .directory ? "Folder" : (node.kind == .file ? "File" : node.kind.rawValue.capitalized)) · \(InventoryMapPlan.weight(node).map(AtlasText.bytes) ?? "size unknown")" + (status.map { " · \($0.title)" } ?? "")).font(.caption).foregroundStyle(.secondary)
                }
            }
            if let classification = inspection?.classification {
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(classification.kind.title) · \(classification.tool.rawValue) · \(classification.confidence.title)").font(.caption.weight(.medium))
                    ForEach(Array(classification.supporting.prefix(4)), id: \.self) { observation in
                        Text("· " + observation.text).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            if !warnings.isEmpty || override {
                VStack(alignment: .leading, spacing: 4) {
                    Text(override ? CleanupTrashGuidance.notConfirmedSafe : "What could be affected").font(.callout.weight(.semibold))
                    VStack(alignment: .leading, spacing: 3) { ForEach(warnings, id: \.self) { Text("· \($0)").font(.caption).fixedSize(horizontal: false, vertical: true) } }
                }
                .accessibilityElement(children: .combine).accessibilityIdentifier("inventory.cleanup.trashWarnings")
            }
            Group {
                if let recovery = inspection?.storage.recovery, case .estimated(let bytes, let basis) = recovery { Text("Space you may get back: about \(AtlasText.bytes(bytes)). \(basis)") }
                else { Text("Space you may get back: unknown until the Trash is emptied.") }
            }.font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 4) {
                Text("About Move to Trash").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Text("macOS moves the item to the Trash; nothing is deleted. Space is freed only when you empty the Trash, and APFS snapshots or shared storage can keep some of it. In a cloud-synced folder the removal may reach your other devices. \(CleanupTrashPolicy.residualRisk)")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if let preparedAt { Text("Checked at \(preparedAt.formatted(date: .omitted, time: .standard)). Confirm within 60 seconds, or review it again.").font(.caption).foregroundStyle(.secondary) }
            }
            if override {
                Toggle(isOn: $accepted) { Text("I understand Storage Monitor hasn't confirmed this is safe to remove.").font(.callout) }
                    .toggleStyle(.checkbox).accessibilityIdentifier("inventory.cleanup.acceptWarnings")
            }
            }.frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { done(nil) }.keyboardShortcut(.cancelAction).accessibilityIdentifier("inventory.cleanup.cancelTrash")
                Button("Move to Trash", role: .destructive) { done(accepted) }
                    .disabled(override && !accepted)
                    .accessibilityIdentifier("inventory.cleanup.confirmTrash")
            }
        }
        .padding(20)
        .frame(width: 480, height: 600)
        .accessibilityIdentifier("inventory.cleanup.trashConfirmation")
    }

    /// Make control and bidirectional formatting characters visible in the exact confirmation target.
    static func displayPath(_ path: String) -> String {
        path.unicodeScalars.map { scalar in
            let value = scalar.value
            if value == 0x5c { return "\\\\" }
            switch scalar.properties.generalCategory {
            case .control, .format, .lineSeparator, .paragraphSeparator:
                return "\\u{\(String(value, radix: 16))}"
            default: return String(scalar)
            }
        }.joined()
    }
}
