import Foundation

/// What the Inspector's Cleanup section shows for one inspection, independent of SwiftUI. Ordinary items produce
/// no section (`nil`), so the Inspector is unchanged for them.
public struct CleanupInspectorPresentation: Equatable, Sendable {
    public struct Row: Equatable, Sendable { public let label: String; public let value: String; public init(_ label: String, _ value: String) { self.label = label; self.value = value } }

    public let title: String
    /// "Claude Code release · Claude Code".
    public let subtitle: String
    public let characteristics: String
    public let confidence: String
    public let status: CleanupStatus
    public let statusTitle: String
    public let summary: String
    public let reasons: [String]
    /// The first few observations, shown without expanding.
    public let evidence: [String]
    /// Everything, for the expanded view: supporting, contradicting, unknowns, incomplete collection.
    public let allEvidence: [String]
    public let contradicting: [String]
    public let unknowns: [String]
    public let hasMoreEvidence: Bool
    public let storage: [Row]
    public let recovery: String
    public let recoveryBasis: String?
    public let risks: [String]
    public let related: [Row]
    public let collected: String
    /// The preview is offered for review candidates only.
    public let offersPreview: Bool

    public static let visibleEvidence = 4

    public init?(_ inspection: ArtifactInspection, formatter: (Int64) -> String) {
        guard let assessment = inspection.assessment else { return nil }
        let c = inspection.classification
        title = c?.title ?? (inspection.path as NSString).lastPathComponent
        subtitle = c.map { c in
            if c.kind == .protectedLocation { return c.kind.title }
            return c.title == c.kind.title ? c.tool.rawValue : c.kind.title + " · \(c.tool.rawValue)"
        } ?? (inspection.identity == .missing ? "No longer present" : "Not examined")
        characteristics = c?.characteristics.sorted().map(\.title).joined(separator: " · ") ?? ""
        confidence = c?.confidence.title ?? ArtifactConfidence.unknown.title
        status = assessment.status
        statusTitle = assessment.status.title
        summary = assessment.summary
        reasons = assessment.reasons
        let supporting = c?.supporting.map(\.text) ?? []
        contradicting = c?.contradicting.map(\.text) ?? []
        unknowns = (c?.unknowns ?? []) + inspection.incomplete.map { "Incomplete: \($0)." }
        evidence = Array(supporting.prefix(Self.visibleEvidence))
        allEvidence = supporting + contradicting.map { "Against: \($0)" } + unknowns.map { "Unknown: \($0)" }
        hasMoreEvidence = allEvidence.count > evidence.count
        let s = inspection.storage
        var rows = [Row("Logical", s.logicalBytes.map(formatter) ?? "Unknown"), Row("Indexed allocation", s.indexedAllocatedBytes.map(formatter) ?? "Unknown")]
        rows.append(Row("Measurement", s.measurement + (s.measuredAt.map { " · \($0.formatted(date: .abbreviated, time: .shortened))" } ?? "")))
        storage = rows
        switch s.recovery {
        case .unknown(let why): recovery = "Recovery amount unknown"; recoveryBasis = why == "Recovery amount unknown." ? nil : why
        case .estimated(let bytes, let basis): recovery = "About \(formatter(bytes)) estimated"; recoveryBasis = basis
        }
        risks = assessment.risks
        related = (c?.related ?? []).prefix(8).map { Row($0.label, $0.roles.map(\.rawValue).joined(separator: ", ")) }
        collected = "Evidence collected \(inspection.collectedAt.formatted(date: .omitted, time: .standard))"
        offersPreview = assessment.status == .reviewCandidate && c != nil
    }
}

/// Plain-language guidance for a Move to Trash refusal: whether it is a permanent restriction or something the
/// person can act on, and the next step. The exact refusal reason is always shown beside it.
public enum CleanupTrashGuidance {
    public enum Kind: Equatable, Sendable { case neverMoved, inUse, needsReview, tooLarge, notYours, unsavedWork, notConfirmed, qaCopy }

    public static func explain(_ reason: String) -> (kind: Kind, title: String, nextStep: String?) {
        // Refusals end with the affected path ("…: /path" or "… (/path)"); folder names are the person's own words and
        // must not decide the category, so only the text before the path is matched.
        let cut = [": /", " (/"].compactMap { reason.range(of: $0)?.lowerBound }.min()
        let r = (cut.map { String(reason[..<$0]) } ?? reason).lowercased()
        func has(_ words: String...) -> Bool { words.contains { r.contains($0) } }
        if has("qa build", "qa session", "qa profile", "qa-bound") { return (.qaCopy, "Not available in test builds", "Test builds read a copy of the catalog, so they never move real files.") }
        // A read the person's permissions refused, reported by a budgeted check: size is not the problem.
        if has("macos did not allow reading") {
            return (.notYours, "macOS doesn't allow moving it from here", "Only items you own and can change are moved from Storage Monitor. You can still reveal it in Finder.")
        }
        if has("uncommitted", "untracked", "unmerged", "stashed", "local commits", "worktree dependencies", "worktree is locked", "worktree lock") {
            return (.unsavedWork, "Contains unsaved Git work", "Commit, push or stash the work first, or keep this folder.")
        }
        if has("running process", "in active use", "is open by", "became active", "started using", "active executable") {
            return (.inUse, "In use right now", "Quit the app or command that is using it, then choose Move to Trash… again.")
        }
        if has("safety budget", "exceeded", "time budget") {
            return (.tooLarge, "Too large to check in one go", "Open the folder and move the larger items inside it one at a time.")
        }
        if has("changed", "no longer", "nothing is at", "disappeared", "expired", "already been used", "cancelled", "stale", "review it again", "review the item again", "still running", "another move to trash", "observation", "confirm it again", "refers to a different item", "could not be reliably assessed", "could not be resolved for database safety") {
            return (.needsReview, "Needs a fresh review", "Select the item again so Storage Monitor can recheck it.")
        }
        if has("ownership", "not owned", "does not permit", "immutable", "restricted", "not locally materialized", "listing is incomplete", "could not be examined", "unreadable") {
            return (.notYours, "macOS doesn't allow moving it from here", "Only items you own and can change are moved from Storage Monitor. You can still reveal it in Finder.")
        }
        if has("could not be confirmed", "not confirmed", "outcome is", "unverified", "uncertain") {
            return (.notConfirmed, "Result not confirmed", "Check the original location and the Trash before trying again.")
        }
        return (.neverMoved, "Storage Monitor never moves this", nil)
    }
}

public extension CleanupTrashGuidance {
    static let notConfirmedSafe = "Storage Monitor has not confirmed that this is safe to remove."

    /// The confirmation's warning list without repeats: the "not established as safe" sentences are stated once by the
    /// sheet, and the long scoped-observation sentence is said plainly. Every specific risk is kept, in order.
    static func presentedWarnings(_ warnings: [String]) -> [String] {
        var seen = Set<String>()
        return warnings.compactMap { warning -> String? in
            let text: String
            if warning == "Storage Monitor has not established whether this item is safe to remove." { return nil }
            else if warning.hasPrefix("Storage Monitor has not assessed this item") { text = "It isn't a kind of item Storage Monitor recognizes, so what depends on it is unknown." }
            else if warning.hasPrefix("Current-user active-use observations were partial") { text = "Storage Monitor could only partly see which of your apps are running. Nothing was seen using this item, but that is not proof." }
            else { text = warning }
            return seen.insert(text).inserted ? text : nil
        }
    }
}
