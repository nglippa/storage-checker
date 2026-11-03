import Foundation

// Classification is advisory. User-directed single-item Trash requires a prepared, explicitly approved
// token and mandatory protection checks. The final pathname replacement interval remains non-atomic.

public enum CleanupTrashDecision: Equatable, Sendable {
    /// Cannot be moved; the reason is shown instead of the action.
    case blocked(String)
    /// Advisory eligibility only; preparation and explicit confirmation are still required. `override`: the assessment did not
    /// mark it as a review candidate, so a review confirmation requires explicit warning acceptance.
    case allowed(override: Bool, warnings: [String])
}

public enum CleanupTrashOutcome: Equatable, Sendable {
    case moved(trashPath: String?)
    case refused(String)
    /// The system operation or its result could not be confirmed. A partial move is possible; never retry automatically.
    case failed(String)

    public var needsReconciliation: Bool {
        switch self { case .moved, .failed: return true; case .refused: return false }
    }
}

public enum CleanupTrashUnavailableError: LocalizedError {
    case confirmationRequired
    public var errorDescription: String? { CleanupTrashPolicy.unavailableReason }
}

public enum CleanupTrashPolicy {
    public static let unavailableReason = "Move to Trash requires the current explicit confirmation. Review the item and confirm it again."
    public static let residualRisk = "Preflight checks reduce risk but cannot eliminate a pathname replacement race between the final check and the macOS Trash operation."

    /// Folders too broad to move as one item (relative to the home folder, or absolute).
    static let broadHomeFolders: Set<String> = ["", "Library", "Desktop", "Documents", "Downloads", "Movies", "Music", "Pictures", "Applications", "Public", "Sites"]
    static let broadAbsolute: Set<String> = ["/", "/Users", "/Applications", "/Library", "/System", "/private", "/usr", "/opt", "/Volumes", "/cores"]

    /// - Parameters:
    ///   - inspection: the Cleanup Inspector's result for this item, or nil when it was not examined.
    ///   - examined: false while an inspection is still running (the person waits for its result).
    public static func decide(node: InventoryNode, inspection: ArtifactInspection?, examined: Bool, home: String) -> CleanupTrashDecision {
        let logical = ArtifactPaths.logical(node.path)
        if node.parentID == nil || broadAbsolute.contains(logical) { return .blocked("This folder is too broad to move to the Trash as one item.") }
        let homeParts = ArtifactPaths.components(home), parts = ArtifactPaths.components(node.path)
        if parts.count >= homeParts.count, Array(parts.prefix(homeParts.count)) == homeParts {
            let rest = parts.dropFirst(homeParts.count)
            if rest.count <= 1, broadHomeFolders.contains(rest.first ?? "") { return .blocked("Your home folder and its main folders cannot be moved to the Trash from here.") }
        } else if homeParts.count >= parts.count, Array(homeParts.prefix(parts.count)) == parts { return .blocked("This folder contains your home folder.") }
        if node.isHardlinkAlias { return .blocked("This entry is another name for a file stored elsewhere (a hard link); review the file itself.") }
        guard examined else { return .blocked("The review of this item is still running.") }
        let contentsWarning = node.kind == .directory ? ["This moves the entire directory, including all of its contents, to Trash."] : []
        guard let inspection else {
            return .allowed(override: true, warnings: ["Storage Monitor has not assessed this item and has not established whether it is safe to remove. It is not one of the kinds it recognizes; its dependencies are unknown."] + contentsWarning)
        }
        switch inspection.identity {
        case .missing: return .blocked("This item is no longer at this path.")
        case .changed: return .blocked("The path now refers to a different item than the one reviewed.")
        case .unavailable(let why): return .blocked("The item could not be examined: \(why)")
        case .verified: break
        }
        guard let assessment = inspection.assessment else {
            return .allowed(override: true, warnings: ["Storage Monitor has not assessed this item and has not established whether it is safe to remove. It is not one of the kinds it recognizes; its dependencies are unknown."] + contentsWarning)
        }
        if let reason = hardBlock(inspection.classification?.facts) { return .blocked(reason) }
        switch assessment.status {
        case .protected:
            return .blocked("Protected: \(assessment.reasons.first ?? "excluded from cleanup").")
        case .reviewCandidate:
            return .allowed(override: false, warnings: contentsWarning + assessment.risks)
        case .preserve:
            return .allowed(override: true, warnings: ["Storage Monitor has not established whether this item is safe to remove.", "Marked Preserve: " + assessment.reasons.joined(separator: " ")] + contentsWarning + assessment.risks)
        case .insufficientEvidence:
            return .allowed(override: true, warnings: ["Storage Monitor has not established whether this item is safe to remove.", "Insufficient evidence: " + assessment.reasons.joined(separator: " ")] + contentsWarning + assessment.risks)
        }
    }

    static func hardBlock(_ facts: ArtifactFacts?) -> String? {
        guard let f = facts else { return nil }
        if f.protectedScope { return "Protected location." }
        if f.isRunning == true { return "A running process executes this item." }
        if f.isResolved == true || f.isCurrent == true || f.containsActive == true || f.linkedFromPath == true { return "Verified active executable references depend on this item." }
        if f.openByProcess == true || f.referencedByProcess == true { return "A running process currently uses this item or its project." }
        if f.worktreeLocked == true { return "This Git worktree is locked." }
        if (f.uncommittedChanges ?? 0) > 0 || (f.untrackedFiles ?? 0) > 0 || (f.unpushedCommits ?? 0) > 0 { return "This Git worktree contains uncommitted, untracked, or potentially unmerged work." }
        return nil
    }

    /// Compatibility entry point cannot create user consent. Only an explicitly approved prepared token can execute.
    public static func perform(node: InventoryNode, decision: CleanupTrashDecision, overrideAccepted: Bool, environment: ArtifactEnvironment,
                               trash: (URL) throws -> URL?) -> CleanupTrashOutcome {
        switch decision {
        case .blocked(let why): return .refused(why)
        case .allowed(let override, _): if override && !overrideAccepted { return .refused("The warning was not accepted.") }
        }
        switch prepare(node: node, environment: environment) {
        case .blocked(let reason): return .refused(reason)
        case .ready(let confirmation):
            defer { cancel(confirmation) }
            if case .allowed(let warning, _) = confirmation.decision, warning && !overrideAccepted { return .refused("The warning was not accepted.") }
            return .refused(unavailableReason)
        }
    }

    /// Raw path-based calls cannot bypass the user-confirmation and protection boundary.
    public static func systemTrash(_ url: URL) throws -> URL? {
        throw CleanupTrashUnavailableError.confirmationRequired
    }
}
