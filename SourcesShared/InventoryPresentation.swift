import Foundation

/// Honest first-pass progress. The total is unknown while folders are still being discovered, so no
/// percentage is ever derived from the growing catalog. The estimate divides the queued folder
/// listings by the rate that queue is shrinking, fitted over its draining stretch within the last ten
/// minutes of persisted worker samples (so it survives worker slices), and is withheld unless that fit
/// is consistent.
/// Files and folders in use on the volume mounted exactly at `root` (statfs), or nil when `root` is not
/// a mount point: a subfolder's work is unrelated to its volume's object count.
public func inventoryVolumeObjectCount(root: String?) -> Int64? {
    guard let root else { return nil }
    var info = statfs()
    guard statfs(root, &info) == 0, info.f_files > info.f_ffree else { return nil }
    let mount = withUnsafeBytes(of: info.f_mntonname) { String(decoding: $0.prefix(while: { $0 != 0 }), as: UTF8.self) }
    guard (mount as NSString).standardizingPath == (root as NSString).standardizingPath else { return nil }
    return Int64(info.f_files - info.f_ffree)
}

public struct InventoryProgressEstimate: Sendable, Equatable {
    /// Items indexed per second over roughly the last two minutes, including any gaps between slices.
    public let itemsPerSecond: Double?
    /// Seconds remaining, or nil while no estimate is defensible.
    public let remainingSeconds: Double?
    /// Lower end of a rough range: the volume bound at the pass's average rate and at its recent rate.
    public let remainingLowerSeconds: Double?
    /// True while the estimate rests only on the volume's object count, before the queue's drain is measurable.
    public let isRough: Bool

    /// `volumeObjects` is the number of files and folders the volume reports in use (statfs), passed only
    /// when the inventory root is that volume's mount point. Indexed entries never exceed it in practice
    /// (unreadable folders, hard links and system files make it larger), so it bounds the work left from the
    /// first samples onward, long before the queue's drain rate is measurable.
    public init(samples: [InventoryProgressSample], volumeObjects: Int64? = nil, now: Date = Date()) {
        let recent = samples.filter { $0.sampledAt > now.addingTimeInterval(-120) && $0.sampledAt <= now.addingTimeInterval(5) }
        itemsPerSecond = Self.slope(recent.map { ($0.sampledAt.timeIntervalSince1970, Double($0.nodes)) }).map { max(0, $0.slope) }
        // Each estimate is computed as of the last few samples and projected to now; the median damps
        // single-sample swings such as a burst of newly discovered folders.
        let usable = samples.filter { $0.sampledAt <= now.addingTimeInterval(5) }
        var projected = [(seconds: Double, lower: Double?, rough: Bool)]()
        for anchor in usable.suffix(9) {
            guard let raw = Self.raw(usable.filter { $0.sampledAt <= anchor.sampledAt }, volumeObjects: volumeObjects, now: anchor.sampledAt) else { continue }
            let elapsed = now.timeIntervalSince(anchor.sampledAt)
            projected.append((max(0, raw.seconds - elapsed), raw.lower.map { max(0, $0 - elapsed) }, raw.rough))
        }
        guard let last = usable.last, now.timeIntervalSince(last.sampledAt) <= 120, !projected.isEmpty,
              projected.count * 2 > min(9, usable.count) else {
            remainingSeconds = nil; remainingLowerSeconds = nil; isRough = false; return
        }
        let sorted = projected.sorted { $0.seconds < $1.seconds }, median = sorted[sorted.count / 2]
        remainingSeconds = median.seconds
        remainingLowerSeconds = median.lower
        isRough = median.rough
    }

    private static func slope(_ points: [(Double, Double)]) -> (slope: Double, r2: Double)? {
        guard points.count >= 2 else { return nil }
        let n = Double(points.count), mx = points.map(\.0).reduce(0, +) / n, my = points.map(\.1).reduce(0, +) / n
        let sxx = points.reduce(0) { $0 + ($1.0 - mx) * ($1.0 - mx) }, sxy = points.reduce(0) { $0 + ($1.0 - mx) * ($1.1 - my) }
        let syy = points.reduce(0) { $0 + ($1.1 - my) * ($1.1 - my) }
        guard sxx > 0 else { return nil }
        return (sxy / sxx, syy > 0 ? (sxy * sxy) / (sxx * syy) : 1)
    }

    /// The estimate as of `now` from `samples` alone.
    private static func raw(_ samples: [InventoryProgressSample], volumeObjects: Int64?, now: Date) -> (seconds: Double, lower: Double?, rough: Bool)? {
        guard let last = samples.last else { return nil }
        // Volume bound: objects not yet indexed at the average rate of this pass. Gaps over five minutes
        // (between worker runs, or while the Mac slept) are not indexing time.
        var boundRange: (low: Double, high: Double)?
        if let volumeObjects, Double(volumeObjects) > Double(last.nodes) * 1.02 {
            var items = 0.0, seconds = 0.0
            for (a, b) in zip(samples, samples.dropFirst()) {
                let dt = b.sampledAt.timeIntervalSince(a.sampledAt)
                if dt > 0, dt <= 300, b.nodes >= a.nodes { items += Double(b.nodes - a.nodes); seconds += dt }
            }
            if seconds >= 30, items / seconds >= 1 {
                let left = Double(volumeObjects - last.nodes), average = left / (items / seconds)
                let recentPoints = samples.filter { $0.sampledAt > now.addingTimeInterval(-120) }.map { ($0.sampledAt.timeIntervalSince1970, Double($0.nodes)) }
                let current = slope(recentPoints).flatMap { $0.slope >= 1 ? left / $0.slope : nil } ?? average
                boundRange = (min(average, current), max(average, current))
            }
        }
        // Drain fit: discovery first grows the queue, then it drains. Only the stretch since the queue's
        // latest peak is evidence of how fast it drains (STORAGE-MONITOR-1.0.3-STABILIZATION.md).
        var drain: Double?
        let window = samples.filter { $0.sampledAt > now.addingTimeInterval(-600) }
        var peak = 0
        for index in window.indices where window[index].queuedListings >= window[peak].queuedListings { peak = index }
        let draining = window.isEmpty ? [] : Array(window[peak...])
        if draining.count >= 6, let first = draining.first, let end = draining.last,
           end.sampledAt.timeIntervalSince(first.sampledAt) >= 120, end.queuedListings > 0, end.queuedListings < first.queuedListings,
           let fit = slope(draining.map { ($0.sampledAt.timeIntervalSince1970, Double($0.queuedListings)) }), fit.slope < 0, fit.r2 >= 0.7 {
            drain = Double(end.queuedListings) / -fit.slope
        }
        // Once the drain is measurable it is the better guess: the volume count includes everything that
        // cannot be read without Full Disk Access, which made the bound err long by 15 minutes near the end
        // of the real Mac mini pass.
        let result: (seconds: Double, lower: Double?, rough: Bool)
        if let drain { result = (drain, nil, false) }
        else if let boundRange { result = (boundRange.high, boundRange.low, true) }
        else { return nil }
        return result.seconds <= 48 * 3600 ? result : nil
    }

    /// What the panel shows: a rough range early, a single coarse figure once the drain is measured.
    public var text: String {
        guard let high = remainingSeconds else { return Self.remainingText(nil) }
        guard isRough else { return Self.remainingText(high) }
        let low = remainingLowerSeconds ?? high
        let a = Self.coarse(low), b = Self.coarse(high)
        return a == b ? "Rough estimate: about \(b) remaining" : "Rough estimate: \(Self.range(a, b)) remaining"
    }
    /// "20–30 minutes" rather than "20 minutes–30 minutes"; mixed units stay spelled out.
    private static func range(_ a: String, _ b: String) -> String {
        let x = a.split(separator: " "), y = b.split(separator: " ")
        if x.count == 2, y.count == 2, x[1].hasPrefix("minute") == y[1].hasPrefix("minute"), x[1].hasPrefix("hour") == y[1].hasPrefix("hour") { return "\(x[0])–\(y[0]) \(y[1])" }
        return "\(a) to \(b)"
    }
    private static func coarse(_ seconds: Double) -> String {
        let text = remainingText(seconds)
        return text.hasPrefix("Estimated remaining: about ") ? String(text.dropFirst("Estimated remaining: about ".count)) : String(text.dropFirst("Estimated remaining: ".count))
    }

    /// Coarse wording, so small changes in the estimate do not change what is shown.
    public static func remainingText(_ seconds: Double?) -> String {
        guard let seconds else { return "Estimating time remaining…" }
        if seconds < 60 { return "Estimated remaining: less than a minute" }
        let minutes = Int((seconds / 60).rounded(.up))
        if minutes <= 5 { return "Estimated remaining: about \(minutes) minute\(minutes == 1 ? "" : "s")" }
        if minutes < 55 { return "Estimated remaining: about \(Int((Double(minutes) / 5).rounded()) * 5) minutes" }
        if minutes < 90 { return "Estimated remaining: about 1 hour" }
        return "Estimated remaining: about \(Int((Double(minutes) / 60).rounded())) hours"
    }
}

/// The first-pass panel follows the engine's durable milestone, never a transient observation,
/// and never derives a completion percentage from a growing catalog.
public struct InventoryInitializationPresentation: Sendable {
    public let isVisible: Bool
    /// Duration guidance is shown only once the database confirms a first pass is starting or running.
    public let showsGuidance: Bool
    public let title: String
    public let elapsed: String?
    public let counts: String?
    /// Current processing rate, when recent samples show one.
    public let rate: String?
    /// "Estimated remaining: …", "Estimating time remaining…", or why there is no estimate.
    public let remaining: String?
    public let accessibilityValue: String
    public static let durationGuidance = "Storage Monitor is discovering files and folders across your disk. Large inventories may take some time — a disk with millions of files can take hours — but you can explore results as they're discovered."
    public static let laterChecksGuidance = "After this first pass, updates normally revisit only changed areas. Gaps in filesystem event history can require a broader check."

    public init(status: InventoryStatus?, requested: Bool = false, paused: Bool = false, progress: [InventoryProgressSample] = [], volumeObjects: Int64? = nil, now: Date = Date()) {
        // Folders deferred because they keep changing are reported by the status line, not as a first pass.
        let onlyDeferredRemain = status.map { $0.deferredDirectories > 0 && !$0.hasInitialDiscoveryWork } ?? false
        isVisible = status == nil || (requested && status?.generation == nil) || (status?.initialCompletion == .inProgress && !onlyDeferredRemain)
        showsGuidance = isVisible && status != nil
        let started = status?.generation != nil
        let lowSpace = status?.lowSpacePaused == true
        if status == nil { title = "Checking inventory status…" }
        else if !started { title = "Preparing your storage inventory…" }
        else if lowSpace { title = "Indexing paused: disk space is low" }
        else if paused { title = "Inventory building paused" }
        else { title = "Building your storage inventory" }
        let estimate = InventoryProgressEstimate(samples: progress, volumeObjects: volumeObjects, now: now)
        if let status, started {
            let bytes = progress.last.map { " · " + ByteCountFormatter.string(fromByteCount: $0.allocatedBytes, countStyle: .file) + " examined" } ?? ""
            counts = "\(status.totalNodes.formatted()) items indexed\(bytes) · \(status.completedDirectories.formatted()) folders completed · \(max(0, status.queuedDirectoryJobs - status.deferredDirectories).formatted()) folders queued"
        } else { counts = nil }
        if started, !paused, !lowSpace, let perSecond = estimate.itemsPerSecond, perSecond >= 1 {
            rate = "\(Int(perSecond.rounded()).formatted()) items/sec"
        } else { rate = nil }
        if !started { remaining = nil }
        else if lowSpace { remaining = "No estimate while paused. Indexing resumes automatically when space is available." }
        else if paused { remaining = "No estimate while paused." }
        else { remaining = estimate.text }
        accessibilityValue = (paused || lowSpace) && started ? "Paused; saved results remain available"
            : (started && estimate.remainingSeconds != nil ? remaining! : "Total work is still being discovered; no completion estimate yet")
        if let began = status?.createdAt {
            let seconds = max(0, now.timeIntervalSince(began))
            let hours = Int(seconds / 3600), minutes = Int(seconds.truncatingRemainder(dividingBy: 3600) / 60)
            let duration = hours > 0 ? "\(hours)h \(minutes)m" : minutes > 0 ? "\(minutes)m \(Int(seconds.truncatingRemainder(dividingBy: 60)))s" : "\(Int(seconds))s"
            elapsed = "Elapsed \(duration)"
        } else { elapsed = nil }
    }
}

public enum InventoryProgressPhase: String, Sendable {
    case unavailable
    case discovering
    case reconciling
    case updating
    case idle
}

/// What the durable inventory state means for the person reading it (STORAGE-MONITOR-INSTALL-READINESS.md).
public enum InventoryCondition: String, Sendable {
    case notStarted
    /// A. The first pass has not finished.
    case initialInventory
    /// B. The first pass finished and nothing is waiting.
    case current
    /// C. The first pass finished; some folders show previous sizes (deferred, stale or being updated).
    case staleDirectories
    /// D. File-event history had a gap or cleanup is pending; folders are being rechecked.
    case needsReconciliation
    /// E. Changes cannot be tracked (file-event history unavailable). A reader failure is shown by the view.
    case unavailable
    /// Indexing paused itself because free space is low; it resumes automatically.
    case paused
}

public struct InventoryStatusPresentation: Sendable {
    public let phase: InventoryProgressPhase
    public let condition: InventoryCondition
    public let foundFolders: Int64
    public let headline: String
    public let detail: String
    public let rankingsArePartial: Bool
    /// Folders behind a C condition (deferred if any, otherwise stale or queued); 0 otherwise.
    public let affectedDirectories: Int64
    /// Queued listings the worker will run, excluding deferred folders that only retry on the next update.
    public let activeListings: Int64
    /// Neutral note when the first-pass milestone is not recorded for this inventory.
    public let completionNote: String?

    /// False only when current service evidence proves monitoring is off. Nil retains catalog-only semantics.
    public let updatesAreWaiting: Bool

    public init(status: InventoryStatus, monitoringEnabled: Bool? = nil, independentIndexing: Bool = false) {
        updatesAreWaiting = monitoringEnabled == false && status.generation != nil &&
            (status.hasReconciliationWork || status.hasInitialDiscoveryWork || status.initialCompletion == .inProgress ||
             status.queuedDirectoryJobs > 0 || status.pendingDirectories > 0 || status.staleDirectories > 0)
        foundFolders = status.completedDirectories + status.pendingDirectories + status.staleDirectories + status.unknownDirectories
        rankingsArePartial = status.completeness != .complete
        activeListings = max(0, status.queuedDirectoryJobs - status.deferredDirectories)
        switch status.initialCompletion {
        case .unknown where status.generation != nil:
            completionNote = "This inventory was created by an earlier version, so whether its first full pass finished isn't recorded yet. It's confirmed automatically once no unlisted folders remain."
        case .unsupported where status.generation != nil:
            completionNote = "This inventory's background indexer predates first-pass tracking, so whether its first full pass finished isn't recorded."
        default: completionNote = nil
        }
        func folders(_ count: Int64) -> String { count == 1 ? "1 folder" : "\(count.formatted()) folders" }

        if status.generation == nil {
            phase = .unavailable; condition = .notStarted; affectedDirectories = 0
            headline = "Inventory has not started"
            detail = "Measured files and folders will appear after indexing begins."
        } else if updatesAreWaiting {
            // Preserve durable coverage/queue facts; stopping the service does not finish or discard work.
            let recorded = InventoryStatusPresentation(status: status)
            condition = recorded.condition; affectedDirectories = recorded.affectedDirectories
            if recorded.condition == .paused || recorded.condition == .unavailable {
                phase = recorded.phase; headline = recorded.headline
                detail = recorded.detail + (independentIndexing ? " Indexing is stopped. Choose Start Index to continue; background monitoring is optional." : " Background indexing is also off. Enable or repair monitoring in Settings before indexing can resume.")
            } else {
                phase = .idle
                headline = status.initialCompletion == .inProgress ? "Indexing is waiting" : "Folder updates are waiting"
                detail = independentIndexing ? "Indexing is stopped. Choose Start Index to continue. Previous measurements and queued work are kept; background monitoring is optional." : "Background indexing is off. Enable or repair monitoring in Settings to continue. Previous measurements and queued work are kept."
            }
        } else if status.lowSpacePaused {
            phase = .unavailable; condition = .paused; affectedDirectories = 0
            headline = "Indexing paused: disk space is low"
            detail = "Indexing stops while free space is very low, so its database cannot fill your disk. Results so far remain available, and indexing resumes automatically once space is freed."
        } else if status.eventHistoryUnavailable && !status.hasReconciliationWork {
            phase = .unavailable; condition = .unavailable; affectedDirectories = 0
            headline = "Changes can't be tracked right now"
            detail = "macOS isn't providing file-event history for this volume, so sizes are shown as last measured and may be out of date. Tracking resumes automatically when history is available again."
        } else if status.hasReconciliationWork && status.hasEventGapRecheck {
            phase = .reconciling; condition = .needsReconciliation; affectedDirectories = 0
            headline = "Rechecking after missed file events"
            detail = "Filesystem event history had a gap, so indexed folders are being checked again. Results remain available; some sizes may change."
        } else if status.hasReconciliationWork && status.refreshIsManual {
            phase = .reconciling; condition = .needsReconciliation; affectedDirectories = 0
            headline = "Refreshing the entire inventory" + (status.refreshFraction.map { " · about \(Int(($0 * 100).rounded(.down)))% rechecked" } ?? "")
            detail = "Every folder is being listed again. Results remain available meanwhile; on a large disk this can take a while."
        } else if status.hasReconciliationWork {
            phase = .reconciling; condition = .needsReconciliation; affectedDirectories = 0
            headline = "Reconciling filesystem changes"
            detail = "Committed results remain available; some previously measured sizes may change."
        } else if activeListings > 0 || status.pendingDirectories > 0 {
            // After the recorded first pass, newly created folders are ordinary updates.
            if status.initialCompletion == .complete || !status.hasInitialDiscoveryWork {
                phase = .updating; condition = .staleDirectories; affectedDirectories = activeListings
                headline = "Updating changed folders"
                detail = "Committed results remain available while queued folder listings run."
            } else {
                phase = .discovering; condition = .initialInventory; affectedDirectories = 0
                headline = "Discovering files and folders"
                detail = "Results are available as each folder listing is committed."
            }
        } else if status.deferredDirectories > 0 {
            // One unstable folder (typically a browser cache) is reported, not hidden, and does not
            // make the whole inventory look unfinished.
            phase = .idle; condition = .staleDirectories; affectedDirectories = status.deferredDirectories
            headline = "Up to date except \(folders(status.deferredDirectories)) that \(status.deferredDirectories == 1 ? "keeps" : "keep") changing"
            detail = "\(status.deferredDirectories == 1 ? "This folder" : "These folders") changed during every attempt to list \(status.deferredDirectories == 1 ? "it" : "them"), so earlier sizes are shown as previous measurements. Each background update tries again."
        } else if status.staleDirectories > 0 {
            phase = .updating; condition = .staleDirectories; affectedDirectories = status.staleDirectories
            headline = "Updates are pending"
            detail = "Previously measured sizes are shown for \(folders(status.staleDirectories)) until they're listed again."
        } else {
            phase = .idle; affectedDirectories = 0
            condition = status.initialCompletion == .inProgress ? .initialInventory : .current
            headline = status.completeness == .complete ? "Inventory is up to date" : "Showing available measurements"
            detail = status.unknownDirectories > 0 ? "Some folders are inaccessible or have not produced a size." : "No folder listings are currently queued."
        }
    }
}

public enum InventoryNodePresentation {
    /// A stale folder whose own listing is current: its total is today's listing plus earlier sizes of
    /// some subfolders (D11). Shown as a value that includes earlier sizes, not as wholly previous.
    public static func includesEarlierSizes(_ node: InventoryNode) -> Bool {
        node.status == .stale && node.kind == .directory && node.statusReason == inventoryDescendantStaleReason
    }

    public static func coverage(_ node: InventoryNode) -> String {
        // A folder that kept changing during every listing attempt keeps its last measured size.
        if node.statusReason == inventoryDeferredReason { return "Kept changing · earlier size" }
        if includesEarlierSizes(node) { return "Includes earlier sizes" }
        // Stale with no earlier value (a protected folder queued again by a refresh): nothing was measured.
        if node.status == .stale && node.previousAllocatedBytes == nil && node.allocatedBytes == nil { return "Waiting to be rechecked" }
        if node.status == .stale { return "Previously measured" }
        if node.coverageState == "excluded" { return "Outside measured scope" }
        if node.listingState == "enumerating" || node.coverageState == "enumerating" { return "Indexing" }
        if node.listingState == "pending" || node.coverageState == "pending" {
            return node.allocatedBytes == nil && node.childCount == 0 ? "Discovered" : "Partial · waiting"
        }
        switch node.status {
        case .complete: return node.isHardlinkAlias ? "Hard-link alias" : "Complete"
        case .stale: return "Previously measured"
        case .unknown: return unavailableLabel(node)
        case .lowerBound: return node.measuredAt == nil ? "Not measured" : "Partial measurement"
        }
    }

    /// A size without the "Previously" or "≈" prefix, for views that state an earlier-size state once (in a
    /// shared note or the status column) instead of on every value. Partial values keep "Partial": a lower
    /// bound changes what the number means.
    public static func compactSize(_ value: Int64?, node: InventoryNode, formatter: (Int64) -> String) -> String {
        guard node.status == .stale, let value else { return size(value, node: node, formatter: formatter) }
        return formatter(value)
    }

    /// The earlier-size note shared by most of a folder's entries, stated once above the explorer instead
    /// of on every row; entries with a different state keep their own note.
    public static func sharedFreshness(_ nodes: [InventoryNode]) -> String? {
        let notes = nodes.compactMap { explorerNote($0) }.filter { $0 == "Previously measured" || $0 == "Includes earlier sizes" }
        guard nodes.count >= 3, let common = Dictionary(grouping: notes, by: { $0 }).max(by: { $0.value.count < $1.value.count }),
              common.value.count * 2 >= nodes.count else { return nil }
        return common.key
    }

    /// The sentence that states a shared earlier-size note once, for the explorer and the map.
    public static func sharedFreshnessText(_ note: String?) -> String? {
        switch note {
        case "Previously measured"?: return "Most sizes here are from the last completed measurement and may have changed"
        case "Includes earlier sizes"?: return "Most folders here include earlier sizes of some subfolders; those folders need rechecking"
        default: return nil
        }
    }

    /// The explorer's quiet state column: nothing for fully measured entries, the coverage wording otherwise.
    public static func explorerNote(_ node: InventoryNode) -> String? {
        let text = coverage(node)
        return text == "Complete" ? nil : text
    }

    public static func size(_ value: Int64?, node: InventoryNode, formatter: (Int64) -> String) -> String {
        if node.status != .complete, node.kind == .directory, value == 0 { return "No size yet" }
        guard let value else {
            if node.coverageState == "excluded" { return "Not measured" }
            if node.status == .unknown { return unavailableLabel(node) }
            return node.measuredAt == nil ? "No size yet" : "Not measured"
        }
        let rendered = formatter(value)
        if includesEarlierSizes(node) { return "≈ \(rendered)" }
        switch node.status {
        case .stale: return "Previously \(rendered)"
        case .lowerBound: return "Partial \(rendered)"
        case .complete, .unknown: return rendered
        }
    }

    private static func unavailableLabel(_ node: InventoryNode) -> String {
        let reason = (node.statusReason ?? "").lowercased()
        if ["permission", "privacy", "consent", "denied", "access"].contains(where: reason.contains) { return "Access restricted" }
        if ["blocked", "i/o", "input/output", "error", "unavailable"].contains(where: reason.contains) { return "Unavailable" }
        return "Not available"
    }
}

/// One APFS volume's space in use, from the monitor's capacity reading (`diskutil apfs list`).
public struct StorageVolumeUsage: Sendable, Equatable {
    public let name: String
    public let roles: [String]
    public let bytes: Int64
    public init(name: String, roles: [String], bytes: Int64) { self.name = name; self.roles = roles; self.bytes = bytes }
}

/// Reconciles macOS-reported disk use with what the inventory attributes to files, without forcing the
/// numbers to agree. Every figure is in bytes and shown with decimal units, as macOS does. The inventory
/// indexes only the Data volume, so the comparison is made against that volume's APFS space in use.
public struct StorageAccountingPresentation: Sendable, Equatable {
    public struct Row: Sendable, Equatable {
        public let label: String
        public let value: String
        public let detail: String?
    }
    public let summary: String
    public let rows: [Row]
    public let notes: [String]
    /// Data-volume space not attributed to indexed files; negative when indexed sizes exceed it.
    public let unattributed: Int64?
    public let needsFullDiskAccess: Bool

    public init(used: Int64, free: Int64, volumes: [StorageVolumeUsage], inventory: InventoryAccounting?, ownDataBytes: Int64? = nil, firstPassComplete: Bool = true) {
        func size(_ bytes: Int64) -> String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }
        let data = volumes.first { $0.roles.contains("Data") }
        let others = volumes.filter { !$0.roles.contains("Data") && $0.bytes > 0 }.sorted { $0.bytes > $1.bytes }
        var rows = [Row(label: "Used on disk", value: size(used), detail: "of \(size(used + free)) · \(size(free)) free (APFS container, all volumes)")]
        if let data {
            rows.append(Row(label: "macOS and other volumes", value: size(max(0, used - data.bytes)),
                            detail: others.isEmpty ? "Space outside the Data volume" : others.map { "\($0.name) \(size($0.bytes))" }.joined(separator: " · ") + " · container metadata"))
            rows.append(Row(label: "Data volume", value: size(data.bytes), detail: "Your files and apps; the volume the inventory indexes"))
        }
        var notes = [String](), unattributed: Int64? = nil
        let needsAccess = (inventory?.protectedFolders ?? 0) > 0 && inventory?.fullDiskAccess != "granted"
        if let inventory, let data {
            rows.append(Row(label: "In indexed files", value: size(inventory.indexedAllocated), detail: "Sum of each indexed file's allocated size; hard links counted once"))
            let difference = data.bytes - inventory.indexedAllocated
            unattributed = difference
            if difference >= 0 {
                rows.append(Row(label: "Not attributed to indexed files", value: size(difference), detail: "Data volume space no indexed file accounts for. Not necessarily reclaimable."))
            } else {
                rows.append(Row(label: "Indexed sizes exceed the Data volume by", value: size(-difference), detail: "APFS clones share blocks but are counted once per file"))
            }
            // Used and free space are shown beside this line; it says what the index has found, plainly. Exact rows are in Details.
            summary = "Files found: \(size(inventory.indexedAllocated))" + (difference >= 0 ? " · \(size(difference)) of your files' space not matched to a file yet" : " · more than the disk reports, because copies that share storage count once per file")
            if !firstPassComplete { notes.append("The first pass is still running, so more files will be attributed.") }
            if inventory.protectedFolders > 0 {
                notes.append("\(inventory.protectedFolders.formatted()) folder\(inventory.protectedFolders == 1 ? " is" : "s are") protected by macOS privacy controls and \(inventory.protectedFolders == 1 ? "was" : "were") not opened" + (needsAccess ? "; Full Disk Access is not granted to the background monitor." : "."))
            }
            if inventory.unavailableFolders > 0 { notes.append("\(inventory.unavailableFolders.formatted()) folder\(inventory.unavailableFolders == 1 ? " is" : "s are") unavailable (owned by another user, protected by the system, or unreadable).") }
            if inventory.unreadableEntries > 0 { notes.append("\(inventory.unreadableEntries.formatted()) item\(inventory.unreadableEntries == 1 ? "'s" : "s'") size could not be read.") }
            if inventory.excludedFolders > 0 { notes.append("\(inventory.excludedFolders.formatted()) location\(inventory.excludedFolders == 1 ? " is" : "s are") outside the index (other file systems, cloud placeholders, Storage Monitor's own data).") }
            if let ownDataBytes, ownDataBytes > 0 { notes.append("Storage Monitor's own data folder (\(size(ownDataBytes))) is not indexed.") }
            notes.append("APFS snapshots, file-system metadata, and files deleted while still open also use space that no indexed file accounts for. Compression, sparse files and clones make file sizes differ from physical use in either direction.")
        } else {
            summary = "\(size(used)) used of \(size(used + free))"
        }
        self.rows = rows; self.notes = notes; self.unattributed = unattributed; self.needsFullDiskAccess = needsAccess
    }

    public static let fullDiskAccessGuidance = "Indexing and Atlas work without background monitoring. For protected folders, open System Settings → Privacy & Security → Full Disk Access and add Storage Monitor (this app), then reopen it and choose Start Index. Indexing still works without Full Disk Access, with inaccessible folders marked. Scheduled background indexing separately uses ~/Applications/MacBook Storage Monitor.app. After an ad-hoc app update, an existing permission entry may need to be removed and added again."
}

/// What the results area shows when there is no folder to list yet. It depends only on the status, which
/// stays the same across the periodic reloads; keying it on `loading` made the empty state blink every
/// two seconds while no inventory existed.
public enum InventoryPlaceholder: Equatable, Sendable {
    case none, checking, waiting, notStarted, loadingResults
    public init(hasRoot: Bool, status: InventoryStatus?, requested: Bool, failed: Bool) {
        if hasRoot { self = .none }
        else if requested && !failed { self = .waiting }
        else if status == nil { self = failed ? .notStarted : .checking }
        else if status?.generation == nil { self = .notStarted }
        else { self = .loadingResults }
    }
}

/// Lifecycle is resolved before choosing Explorer, rankings or Review, so every renderer has a usable first run.
public struct InventoryLifecyclePresentation: Equatable, Sendable {
    public enum State: Equatable, Sendable { case checking, monitoringOff, notCreated, indexing, waiting, available, temporarilyUnavailable, failed, stale }
    public enum Action: Equatable, Sendable { case openSettings, startIndexing, retry }
    public let state: State
    public let showsBrowser: Bool
    public let title: String
    public let detail: String
    public let action: Action?
    public var showsProgress: Bool { state == .checking || state == .indexing }
    public init(hasRoot: Bool, status: InventoryStatus?, requested: Bool, loading: Bool, error: String?, monitoringConfigured: Bool?, indexingFailure: String? = nil, monitoringEnabled: Bool? = nil, independentIndexing: Bool = false) {
        showsBrowser = hasRoot
        if let error = error ?? (!hasRoot ? indexingFailure : nil) {
            state = hasRoot ? .temporarilyUnavailable : .failed
            title = hasRoot ? "Inventory could not be updated" : "Inventory unavailable"
            detail = error + (hasRoot ? " Previous catalog results remain visible. Reload to try again." : independentIndexing ? " Choose Start Index to try again, or check folder access." : " Reload to try again, or check Background Monitoring in Settings.")
            action = .retry
        } else if monitoringEnabled == false && ((!hasRoot && (requested || status?.initialCompletion == .inProgress)) || status.map { InventoryStatusPresentation(status: $0, monitoringEnabled: false).updatesAreWaiting } == true) {
            state = .waiting; title = "Indexing is waiting"
            detail = independentIndexing ? "Indexing is stopped. Choose Start Index to continue. Previous measurements and queued work are kept; background monitoring is optional." : "Background indexing is off. Enable or repair monitoring in Settings to continue indexing. Previous measurements and queued work are kept."
            action = independentIndexing ? .startIndexing : .openSettings
        } else if hasRoot {
            if status?.initialCompletion == .inProgress { state = .indexing; title = "Building your storage inventory" }
            else if status?.completeness == .stale || status?.eventHistoryUnavailable == true { state = .stale; title = "Previous inventory measurements" }
            else { state = .available; title = "Inventory available" }
            detail = status.map { InventoryStatusPresentation(status: $0).detail } ?? "Catalog results remain qualified by coverage."
            action = nil
        } else if requested || status?.initialCompletion == .inProgress {
            state = .indexing; title = "Building your storage inventory"
            detail = "Waiting for the indexer's first results. Large inventories can take hours; you can browse results as they are discovered. Full Disk Access is optional."
            action = independentIndexing ? nil : .openSettings
        } else if status?.generation != nil {
            state = .temporarilyUnavailable; title = "Inventory folder unavailable"
            detail = "The catalog exists, but its folder results could not be loaded. Reload the inventory, or check Background Monitoring and folder access in Settings."
            action = .retry
        } else if status == nil && loading {
            state = .checking; title = "Checking inventory status…"; detail = "Reading the local catalog."; action = nil
        } else if independentIndexing {
            state = .notCreated; title = "Start your storage index"
            detail = "Choose Start Index to discover files and folders, then explore them in Atlas or the browser as results arrive. Full Disk Access is optional for protected folders. Background monitoring is not required."
            action = .startIndexing
        } else if monitoringConfigured == false {
            state = .monitoringOff; title = "Background monitoring is not configured"
            detail = "Enable Background Monitoring in Settings to record capacity and build your disk inventory. Storage Monitor asks before setting up the MacBook Storage Monitor helper for your account. The first inventory can take hours. Full Disk Access is optional."
            action = .openSettings
        } else {
            state = .notCreated; title = "No disk inventory yet"
            detail = monitoringConfigured == true ? "Background monitoring is configured, but the inventory has not started. Start indexing to discover files and folders. The first pass can take hours; Full Disk Access is optional." : "The local inventory has not been created. Check Background Monitoring in Settings to enable or repair the helper. The first pass can take hours; Full Disk Access is optional."
            action = monitoringConfigured == true ? .startIndexing : .openSettings
        }
    }
}
