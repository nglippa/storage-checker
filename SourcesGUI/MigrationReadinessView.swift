import SwiftUI
import AppKit

// Migration Readiness in the viewer: a compact status line in the Storage overview with a details popover, an
// Inspector section for detected items, and the Structured Explorer's Migration Review filter (fed from here).
// Everything is read-only. There is no delete, compact, prune, mount or exclude action anywhere in this file.

/// Runs the detector off the main thread and publishes its report. One pass at a time; requests that arrive while a
/// pass runs, or soon after one, are coalesced into a single later pass.
@MainActor final class MigrationReadinessController: ObservableObject {
    @Published private(set) var report: SparseStorageReport?
    @Published private(set) var scanning = false
    @Published private(set) var error: String?
    /// Set by the browser: receives each new report (the Structured Explorer's Migration Review targets).
    var onReport: ((SparseStorageReport) -> Void)?

    let enabled: Bool
    let detector: SparseStorageDetector
    /// Shortest time between two automatic passes.
    let minimumInterval: TimeInterval
    /// While the inventory's first pass is still running the change journal moves too fast to replay, so each pass would
    /// be a full catalog scan: automatic passes are then spaced at least five minutes apart.
    var interval: TimeInterval { report?.coverage.inventoryIncomplete == true ? max(minimumInterval, 300) : minimumInterval }
    private var task: Task<Void, Never>?
    private var deferred: Task<Void, Never>?
    private var lastStarted: Date?
    private var byID = [Int64: SparseStorageItem]()
    private(set) var passes = 0

    static let enabledKey = "inventory.migrationReadiness.enabled"

    init(database: String, defaults: UserDefaults = ViewerStore.viewPreferences, home: String? = FileManager.default.homeDirectoryForCurrentUser.path, minimumInterval: TimeInterval = 30) {
        enabled = defaults.object(forKey: Self.enabledKey) as? Bool ?? true
        detector = SparseStorageDetector(database: database, thresholds: Self.thresholds(defaults), home: home)
        self.minimumInterval = minimumInterval
    }

    /// Thresholds can be tuned with `defaults write` (decimal GiB and a ratio); invalid values keep the defaults.
    static func thresholds(_ defaults: UserDefaults) -> SparseStorageThresholds {
        let standard = SparseStorageThresholds.standard
        func gib(_ key: String, _ fallback: Int64) -> Int64 {
            guard let value = defaults.object(forKey: key) as? Double, value > 0, value < 1_000_000 else { return fallback }
            return Int64(value * Double(SparseStorageThresholds.gibibyte))
        }
        let ratio = (defaults.object(forKey: "inventory.migrationReadiness.reviewMinimumRatio") as? Double).flatMap { $0 >= 1 && $0 < 10_000 ? $0 : nil }
        return SparseStorageThresholds(reviewMinimumLogical: gib("inventory.migrationReadiness.reviewMinimumLogicalGiB", standard.reviewMinimumLogical),
                                       reviewMinimumGap: gib("inventory.migrationReadiness.reviewMinimumGapGiB", standard.reviewMinimumGap),
                                       reviewMinimumRatio: ratio ?? standard.reviewMinimumRatio,
                                       reportMinimumGap: gib("inventory.migrationReadiness.reportMinimumGapGiB", standard.reportMinimumGap),
                                       reportMinimumRatio: standard.reportMinimumRatio)
    }

    func item(_ id: Int64?) -> SparseStorageItem? { id.flatMap { byID[$0] } }

    /// Starts a pass unless one is running or one started within `minimumInterval` (then one pass is scheduled).
    func refresh(force: Bool = false) {
        guard enabled else { return }
        if task != nil { schedule(after: interval); return }
        if !force, let lastStarted, Date().timeIntervalSince(lastStarted) < interval {
            schedule(after: interval - Date().timeIntervalSince(lastStarted)); return
        }
        deferred?.cancel(); deferred = nil
        lastStarted = Date(); scanning = true
        let detector = detector
        task = Task(priority: .utility) { [weak self] in
            let result: Result<SparseStorageReport, Error>
            do { result = .success(try await detector.refresh()) } catch { result = .failure(error) }
            guard let self else { return }
            self.task = nil; self.scanning = false; self.passes += 1
            switch result {
            case .success(let report): self.publish(report); self.error = nil
            case .failure(let error) where error is CancellationError: break
            case .failure(let error): self.error = (error as? InventoryReaderError)?.description ?? error.localizedDescription
            }
        }
    }

    /// Waits for the pass in flight (tests and benchmarks).
    func waitForPass() async { await task?.value }

    func cancel() { task?.cancel(); deferred?.cancel(); deferred = nil }

    private func schedule(after seconds: TimeInterval) {
        guard deferred == nil else { return }
        deferred = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(0.05, seconds) * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            self.deferred = nil
            if self.task == nil { self.refresh(force: true) } else { self.schedule(after: self.interval) }
        }
    }

    /// Checks one item on disk again (an Inspector selection); cached for 15 seconds by the detector.
    func recheck(_ id: Int64) async {
        guard byID[id] != nil else { return }
        _ = await detector.recheck(id)
        if let report = await detector.report { publish(report) }
    }

    private func publish(_ report: SparseStorageReport) {
        self.report = report
        byID = Dictionary(report.items.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        onReport?(report)
    }

    /// Catalog chains for the Migration Review filter: review and unknown items (informational ones are not highlighted).
    static func targets(_ report: SparseStorageReport) -> [[Int64]] {
        report.items.filter { $0.severity != .informational }.map { $0.ancestors + [$0.id] }
    }
}

// MARK: Overview

/// One line in the Storage overview; details are a click away.
struct MigrationReadinessSummary: View {
    @ObservedObject var controller: MigrationReadinessController
    let browser: InventoryBrowserModel
    @State private var showingDetails = false

    var body: some View {
        if controller.enabled {
            HStack(spacing: 6) {
                Image(systemName: symbol).foregroundStyle(tint).imageScale(.small).accessibilityHidden(true)
                Text("Migration readiness:").font(.caption.weight(.medium))
                Text(status).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                if controller.scanning && controller.report == nil { ProgressView().controlSize(.mini) }
                if controller.report != nil {
                    Button("Details") { showingDetails = true }
                        .buttonStyle(.link).font(.caption).accessibilityIdentifier("migration.details")
                        .popover(isPresented: $showingDetails, arrowEdge: .bottom) {
                            if let report = controller.report {
                                MigrationReadinessPanel(report: report, browser: browser, close: { showingDetails = false })
                            }
                        }
                }
            }
            .accessibilityElement(children: .contain).accessibilityIdentifier("migration.summary")
            .help("Sparse disk images and virtual disks found in the disk inventory. Read-only; nothing is changed.")
        }
    }

    private var status: String {
        if let report = controller.report {
            guard report.coverage.inventoryAvailable else { return report.summary }
            var text = report.reviewCount > 0 || report.unknownCount > 0 ? report.summary : "No large sparse-storage discrepancies detected"
            if let headline = report.headline, report.reviewCount > 0 { text += " · " + headline.title }
            if !report.coverage.isComplete { text += " · coverage limited" }
            return text
        }
        if let error = controller.error { return "unavailable (\(error))" }
        return "checking indexed files…"
    }
    private var symbol: String {
        guard let report = controller.report, report.coverage.inventoryAvailable else { return "shippingbox" }
        return report.reviewCount > 0 ? "exclamationmark.triangle" : (report.unknownCount > 0 ? "questionmark.circle" : "checkmark.circle")
    }
    private var tint: Color {
        guard let report = controller.report else { return .secondary }
        return report.reviewCount > 0 ? .orange : .secondary
    }
}

/// The popover: the leading item with its measurements, other items, coverage limits and guidance.
struct MigrationReadinessPanel: View {
    let report: SparseStorageReport
    let browser: InventoryBrowserModel
    let close: () -> Void
    @State private var learnMore = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("MIGRATION READINESS").font(.caption.weight(.semibold)).foregroundStyle(.secondary).accessibilityAddTraits(.isHeader)
                Text(report.summary).font(.headline).fixedSize(horizontal: false, vertical: true)
                if let item = report.headline {
                    MigrationReadinessMeasurements(item: item)
                    if item.severity == .review {
                        Label {
                            Text(SparseStorageGuidance.reviewHeadline).foregroundStyle(.primary)
                        } icon: {
                            Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange).accessibilityHidden(true)
                        }.font(.callout.weight(.semibold))
                    }
                    Text(SparseStorageGuidance.explanation(item, bytes: AtlasText.bytes)).font(.callout).fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 10) {
                        Button("Reveal in Inspector") { reveal(item) }.accessibilityIdentifier("migration.reveal")
                        Button(learnMore ? "Hide Details" : "Learn More") { learnMore.toggle() }.accessibilityIdentifier("migration.learnMore")
                    }.controlSize(.small)
                    if learnMore { MigrationReadinessGuidance(kind: item.kind) }
                }
                let others = report.items.filter { $0.id != report.headline?.id }.prefix(6)
                if !others.isEmpty {
                    Divider()
                    Text(report.headline == nil ? "Sparse storage detected" : "Other detected items").font(.subheadline.weight(.semibold))
                    ForEach(Array(others), id: \.id) { item in
                        Button { reveal(item) } label: {
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(item.severity.title).font(.caption2.weight(.semibold)).foregroundStyle(item.severity == .review ? Color.primary : Color.secondary).frame(width: 78, alignment: .leading)
                                Text(item.node.name).lineLimit(1).truncationMode(.middle)
                                Spacer(minLength: 4)
                                Text("gap " + AtlasText.bytes(item.allocation.gap)).monospacedDigit().foregroundStyle(.secondary)
                            }.font(.caption).contentShape(Rectangle())
                        }.buttonStyle(.plain).help(SparseStorageLocations.redacted(item.node.path, home: FileManager.default.homeDirectoryForCurrentUser.path))
                    }
                    let rest = report.reviewCount + report.unknownCount + report.informationalCount - others.count - (report.headline == nil ? 0 : 1)
                    if rest > 0 { Text("\(rest) more not shown.").font(.caption).foregroundStyle(.secondary) }
                }
                if !report.items.isEmpty {
                    Button("Show in Explorer with Migration Review") { showInExplorer() }
                        .controlSize(.small).disabled(MigrationReadinessController.targets(report).isEmpty)
                        .help("Opens the Structured Explorer at Startup Data with paths to items to review highlighted.")
                }
                if !report.coverage.notes.isEmpty {
                    Divider()
                    Text("Coverage").font(.subheadline.weight(.semibold))
                    ForEach(report.coverage.notes, id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                }
                Divider()
                Text("From the disk inventory, checked \(report.completedAt.formatted(date: .omitted, time: .shortened)). Read-only: nothing was changed, mounted or launched. Review: logical size ≥ \(Self.gib(report.thresholds.reviewMinimumLogical)), gap ≥ \(Self.gib(report.thresholds.reviewMinimumGap)), ratio ≥ \(report.thresholds.reviewMinimumRatio.formatted()) : 1. Sizes above are decimal (1 GB = 10⁹ bytes); thresholds are binary (1 GiB = 2³⁰ bytes).")
                    .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }.padding(16)
        }
        .frame(width: 440).frame(maxHeight: 560)
        .accessibilityIdentifier("migration.panel")
    }

    static func gib(_ bytes: Int64) -> String {
        (Double(bytes) / Double(SparseStorageThresholds.gibibyte)).formatted(.number.precision(.fractionLength(0...2))) + " GiB"
    }

    private func reveal(_ item: SparseStorageItem) {
        ViewerStore.viewPreferences.set(true, forKey: "inventory.explorer.inspector")
        browser.revealReviewCandidate(item.node)
        close()
    }

    private func showInExplorer() {
        ViewerStore.viewPreferences.set(InventoryVisualization.tree.rawValue, forKey: "inventory.explorer.visualization")
        ViewerStore.viewPreferences.set(true, forKey: "inventory.explorer.showMap")
        browser.mode = .explorer
        if let root = browser.root, browser.directory?.id != root.id { browser.navigate(root) }
        browser.structuredExplorer.filter.migrationReview = true
        close()
    }
}

/// Logical, allocated and gap, aligned; shared by the panel and the Inspector.
struct MigrationReadinessMeasurements: View {
    let item: SparseStorageItem
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(item.title).font(.callout.weight(.semibold))
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 4) {
                row(item.kind.isSparseBundle ? "Band data (logical)" : "Logical size", item.allocation.logical)
                row("Allocated on disk", item.allocation.allocated)
                row("Apparent gap", item.allocation.gap)
            }
        }
        .accessibilityElement(children: .combine)
    }
    private func row(_ label: String, _ value: Int64) -> some View {
        GridRow {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(AtlasText.bytes(value)).font(.callout.monospacedDigit()).gridColumnAlignment(.trailing)
        }
    }
}

struct MigrationReadinessGuidance: View {
    let kind: SparseStorageKind
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(SparseStorageGuidance.considerations(kind) + SparseStorageGuidance.general, id: \.self) { line in
                HStack(alignment: .firstTextBaseline, spacing: 6) { Text("•"); Text(line).fixedSize(horizontal: false, vertical: true) }
            }
        }.font(.caption).foregroundStyle(.secondary)
    }
}

// MARK: Inspector

/// Shown in the Inspector when the selected item was detected.
struct MigrationReadinessInspectorSection: View {
    let item: SparseStorageItem
    let filesystem: String?
    @State private var showingGuidance = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Migration readiness").font(.subheadline.weight(.semibold))
                Spacer()
                Text(item.severity.title).font(.caption.weight(.semibold)).foregroundStyle(item.severity == .review ? Color.primary : Color.secondary)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background((item.severity == .review ? Color.orange : Color.secondary).opacity(0.12), in: Capsule())
            }
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                row("Category", item.kind.category.title)
                if let format = item.kind.format { row("Format", format + " (from its name)") }
                if let app = item.kind.application { row("Likely application", app + " (from its location)") }
                row(item.kind.isSparseBundle ? "Band data (logical)" : "Logical size", AtlasText.bytes(item.allocation.logical))
                row("Allocated on disk", AtlasText.bytes(item.allocation.allocated))
                row("Apparent gap", AtlasText.bytes(item.allocation.gap))
                row("Allocation ratio", SparseStorageGuidance.ratio(item.allocation))
                if item.kind.isSparseBundle { row("Bundle capacity", item.bundle?.capacity.map(AtlasText.bytes) ?? "Unknown (Info.plist not read)") }
                else if item.kind.category != .sparseFile { row("Virtual capacity", "Unknown (the format is not parsed)") }
                if let filesystem { row("Filesystem", filesystem.uppercased() == "APFS" ? "APFS" : filesystem) }
                if item.indexed != item.allocation { row("When indexed", "\(AtlasText.bytes(item.indexed.logical)) logical · \(AtlasText.bytes(item.indexed.allocated)) allocated") }
            }
            Text(item.verification.summary).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if item.severity == .review {
                Label {
                    Text(SparseStorageGuidance.reviewHeadline).foregroundStyle(.primary)
                } icon: {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange).accessibilityHidden(true)
                }.font(.callout.weight(.medium))
            }
            Text(SparseStorageGuidance.explanation(item, bytes: AtlasText.bytes)).font(.callout).fixedSize(horizontal: false, vertical: true)
            Label { Text(SparseStorageGuidance.dataSafety(item.kind)).fixedSize(horizontal: false, vertical: true) } icon: { Image(systemName: "exclamationmark.shield") }
                .font(.caption).foregroundStyle(.primary)
                .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                .accessibilityIdentifier("migration.dataSafety")
            InspectorDisclosure("Migration considerations", isExpanded: $showingGuidance) { MigrationReadinessGuidance(kind: item.kind) }
        }
        .accessibilityIdentifier("migration.inspector")
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).font(.caption).foregroundStyle(.secondary).gridColumnAlignment(.leading)
            Text(value).font(.callout.monospacedDigit()).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }
    }
}
