import Foundation

public enum StructuredExplorerFilterPresentation: String, CaseIterable, Sendable {
    case dim, hide
}

public enum StructuredExplorerFocus: String, CaseIterable, Sendable {
    case off, subtree, path
}

public struct StructuredExplorerFilter: Equatable, Hashable, Sendable {
    public var minimumBytes: Int64
    public var presentation: StructuredExplorerFilterPresentation
    public var focus: StructuredExplorerFocus
    /// Migration Review: match only the folders and files that lead to detected sparse-storage items.
    public var migrationReview: Bool

    public init(minimumBytes: Int64 = 0, presentation: StructuredExplorerFilterPresentation = .dim, focus: StructuredExplorerFocus = .off, migrationReview: Bool = false) {
        self.minimumBytes = max(0, minimumBytes)
        self.presentation = presentation
        self.focus = focus
        self.migrationReview = migrationReview
    }

    public var isActive: Bool { minimumBytes > 0 || focus != .off || presentation != .dim || migrationReview }
    /// Whether some nodes do not match (a size threshold or Migration Review).
    public var narrows: Bool { minimumBytes > 0 || migrationReview }
}

public enum StructuredExplorerSizePreset: String, CaseIterable, Sendable {
    case all, mb100, mb500, gb1, gb5, gb10, custom

    public var title: String {
        switch self {
        case .all: return "All"
        case .mb100: return "100 MB"
        case .mb500: return "500 MB"
        case .gb1: return "1 GB"
        case .gb5: return "5 GB"
        case .gb10: return "10 GB"
        case .custom: return "Custom"
        }
    }

    public var bytes: Int64? {
        switch self {
        case .all: return 0
        case .mb100: return 100_000_000
        case .mb500: return 500_000_000
        case .gb1: return 1_000_000_000
        case .gb5: return 5_000_000_000
        case .gb10: return 10_000_000_000
        case .custom: return nil
        }
    }
}

public enum StructuredExplorerSizeUnit: String, CaseIterable, Sendable {
    case mb, gb
    public var title: String { rawValue.uppercased() }
    public var multiplier: Int64 { self == .mb ? 1_000_000 : 1_000_000_000 }
}

public enum StructuredExplorerThreshold {
    public static func parse(_ text: String, unit: StructuredExplorerSizeUnit) -> Int64? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.allSatisfy({ ("0"..."9").contains($0) || $0 == "." }), value.filter({ $0 == "." }).count <= 1,
              value.contains(where: \.isNumber), let decimal = Decimal(string: value, locale: Locale(identifier: "en_US_POSIX")), decimal > 0 else { return nil }
        let bytes = decimal * Decimal(unit.multiplier)
        guard bytes >= 1, bytes <= Decimal(Int64.max) else { return nil }
        var source = bytes, rounded = Decimal()
        NSDecimalRound(&rounded, &source, 0, .down)
        let number = NSDecimalNumber(decimal: rounded)
        guard number != .notANumber else { return nil }
        return number.int64Value
    }
}

public struct StructuredExplorerVisibility: Sendable {
    public let visible: Set<LivingTreeKey>
    public let matching: Set<LivingTreeKey>
    public let context: Set<LivingTreeKey>
    public let selectionExceptions: Set<LivingTreeKey>
    public let prominent: Set<LivingTreeKey>
    public let availableFolders: Int
    public let visibleFolders: Int
    public let matchingFolders: Int
    public let contextFolders: Int
    public let selectedBelowThreshold: Bool
    public let noMatches: Bool
    /// Shown nodes that are, or most closely contain, a detected migration-review item (empty when the filter is off).
    public let reviewHighlights: Set<LivingTreeKey>
    /// Shown nodes on the path from the centre to a highlight, the highlights included (empty when the filter is off).
    public let reviewPaths: Set<LivingTreeKey>

    private let filter: StructuredExplorerFilter
    private let selection: LivingTreeKey?

    /// - Parameter migrationTargets: each detected item's catalog chain, root first and the item last. Items outside the
    ///   shown folder are ignored; an item that is not drawn is represented by its nearest shown ancestor. No catalog read.
    public init(layout: StructuredExplorerLayout, model: LivingTreeModel, filter: StructuredExplorerFilter, selection: LivingTreeKey?,
                migrationTargets: [[Int64]] = []) {
        self.filter = filter
        self.selection = selection
        let laidOut = Set(layout.nodes.map(\.key))
        let review: Set<LivingTreeKey>? = filter.migrationReview ? Self.migrationKeys(migrationTargets, layout: layout) : nil
        var matching = Set<LivingTreeKey>()
        for key in laidOut {
            guard let element = model[key] else { continue }
            let large = filter.minimumBytes == 0 || element.bytes.map({ $0 >= filter.minimumBytes }) == true
            // A grouped remainder matches only as Migration Review's stand-in for an item grouped in it.
            guard key.nodeID != nil || review?.contains(key) == true else { continue }
            if large && review.map({ $0.contains(key) }) ?? true { matching.insert(key) }
        }
        self.matching = matching

        func chain(_ key: LivingTreeKey) -> Set<LivingTreeKey> {
            let ancestry = model.ancestry(of: key)
            guard let rootIndex = ancestry.firstIndex(of: layout.rootKey) else { return [] }
            return Set(ancestry[rootIndex...]).intersection(laidOut)
        }

        var context: Set<LivingTreeKey> = [layout.rootKey]
        for key in matching { context.formUnion(chain(key)) }
        var exceptions = Set<LivingTreeKey>()
        if let selection, laidOut.contains(selection), !matching.contains(selection) { exceptions = chain(selection) }
        context.formUnion(exceptions)
        self.context = context
        selectionExceptions = exceptions

        if filter.presentation == .hide, filter.narrows {
            visible = matching.union(context).union(exceptions)
        } else {
            visible = laidOut
        }

        var focusSet = Set<LivingTreeKey>()
        if let selection, laidOut.contains(selection) {
            switch filter.focus {
            case .off: break
            case .path: focusSet = chain(selection)
            case .subtree: focusSet = chain(selection).union(model.subtree(of: selection)).intersection(laidOut)
            }
        }
        if !focusSet.isEmpty { prominent = focusSet.intersection(visible) }
        else if filter.narrows {
            var priority = matching.intersection(visible)
            if let selection, visible.contains(selection) { priority.insert(selection) }
            prominent = priority
        } else { prominent = [] }

        func isFolder(_ key: LivingTreeKey) -> Bool { key != layout.rootKey && model[key]?.isFolder == true && key.nodeID != nil }
        availableFolders = laidOut.filter(isFolder).count
        visibleFolders = visible.filter(isFolder).count
        matchingFolders = matching.filter(isFolder).count
        contextFolders = context.subtracting(matching).filter(isFolder).count
        let highlights = filter.migrationReview ? matching.intersection(visible) : []
        var paths = Set<LivingTreeKey>()
        for key in highlights { paths.formUnion(chain(key)) }
        reviewHighlights = highlights
        reviewPaths = paths.intersection(visible)
        // With Migration Review alone, a folder on a review path is not "excluded" even though only the deepest node matches.
        selectedBelowThreshold = filter.narrows && (selection.map { laidOut.contains($0) && !matching.contains($0)
            && !(filter.migrationReview && filter.minimumBytes == 0 && paths.contains($0)) } ?? false)
        noMatches = filter.narrows && (filter.migrationReview ? matching.isEmpty : matchingFolders == 0)
    }

    /// The deepest shown node on each chain that passes through the layout's root. When that is the centre itself, the
    /// centre's grouped remainder stands in for the item when it is shown.
    public static func migrationKeys(_ targets: [[Int64]], layout: StructuredExplorerLayout) -> Set<LivingTreeKey> {
        guard let root = layout.rootKey.nodeID else { return [] }
        var keys = Set<LivingTreeKey>()
        for chain in targets {
            guard let start = chain.firstIndex(of: root), let deepest = chain[start...].reversed().first(where: { layout.index[.node($0)] != nil }) else { continue }
            if deepest != root { keys.insert(.node(deepest)) }
            else if chain.count > start + 1, layout.index[.rest(root)] != nil { keys.insert(.rest(root)) }
        }
        return keys
    }

    public func opacity(_ key: LivingTreeKey) -> Double {
        guard visible.contains(key) else { return 0 }
        if key == selection { return 1 }
        if filter.focus != .off, selection != nil { return prominent.contains(key) ? 1 : 0.2 }
        guard filter.narrows else { return 1 }
        if matching.contains(key) { return 1 }
        if context.contains(key) { return 0.8 }
        return 0.2
    }

    public func labelOpacity(_ key: LivingTreeKey) -> Double { opacity(key) }
}
