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
