import Foundation
import CoreGraphics

/// The storage map of one folder window: the largest measured children as area-proportional tiles, and
/// everything after them grouped into one "Other items" region whose size is the exact indexed sum.
/// Entries without a measured size are counted, never drawn: an area would imply a size.
public struct InventoryMapPlan: Sendable {
    public struct Other: Equatable, Sendable {
        public let count: Int64
        public let allocated: Int64
        /// Entries in the group with no indexed size (protected, unreadable or not yet listed).
        public let unmeasured: Int64
        /// Window start that shows this group's entries as tiles.
        public let nextStart: Int
        /// False when the group lies beyond the entries the explorer may load for one folder.
        public let canDrill: Bool
    }
    public struct Tile: Identifiable, Sendable {
        public enum Content: Sendable {
            case node(InventoryNode), other(Other)
            /// Bytes the folder's own total holds beyond its listed children (nested maps only).
            case residual
        }
        public let id: Int64
        public let content: Content
        public let bytes: Int64
        public let rect: CGRect
        public var node: InventoryNode? { if case .node(let node) = content { return node } else { return nil } }
    }

    public static let otherID: Int64 = -1
    public static let residualID: Int64 = -2

    public let tiles: [Tile]
    public let other: Other?
    /// Bytes represented by drawn area (tiles plus the other region when it has indexed bytes).
    public let drawnBytes: Int64

    /// The allocated size the map uses for an entry: its current value, or its earlier value while stale.
    public static func weight(_ node: InventoryNode) -> Int64? {
        node.status == .unknown ? nil : (node.allocatedBytes ?? node.previousAllocatedBytes)
    }

    /// - Parameters:
    ///   - items: the folder's loaded children in explorer order (largest first, unmeasured last).
    ///   - start: first entry of this window (0, or a drilled-into "Other items" group).
    ///   - beyond: exact totals of the children after `items` (nil when the folder is fully loaded).
    ///   - canLoadMore: whether the explorer may load more of this folder.
    public init(items: [InventoryNode], start: Int, beyond: InventoryChildRemainder?, canLoadMore: Bool,
                in rect: CGRect, maxTiles: Int = 120, minShare: Double? = nil, residual: Int64 = 0) {
        // An entry is drawn when its region would be at least about 13 × 13 points; a fixed share hid
        // every file of a folder of many similar files (1,234 files drew one region).
        let minShare = minShare ?? (rect.width * rect.height > 0 ? 160 / Double(rect.width * rect.height) : 1)
        let window = start < items.count ? Array(items[start...]) : []
        let windowKnown = window.reduce(Int64(0)) { $0 + (Self.weight($1) ?? 0) }
        let total = windowKnown + (beyond?.allocated ?? 0)
        var shown = [InventoryNode]()
        for node in window {
            guard shown.count < maxTiles, let weight = Self.weight(node), weight > 0, total > 0 else { break }
            // Always draw the largest entry; below it, entries under the minimum share join the group.
            if !shown.isEmpty && Double(weight) / Double(total) < minShare { break }
            shown.append(node)
        }
        let rest = window.dropFirst(shown.count)
        let restCount = Int64(rest.count) + (beyond?.count ?? 0)
        var other: Other?
        if restCount > 0 {
            let nextStart = start + shown.count
            other = Other(count: restCount,
                          allocated: rest.reduce(Int64(0)) { $0 + (Self.weight($1) ?? 0) } + (beyond?.allocated ?? 0),
                          unmeasured: Int64(rest.filter { Self.weight($0) == nil }.count) + (beyond?.unmeasured ?? 0),
                          nextStart: nextStart,
                          // Drilling must show something new: with no tile drawn the next window is this one.
                          canDrill: !shown.isEmpty && (nextStart < items.count || canLoadMore))
        }
        var entries = shown.map { (id: $0.id, content: Tile.Content.node($0), bytes: Self.weight($0)!) }
        if let other, other.allocated > 0 { entries.append((Self.otherID, .other(other), other.allocated)) }
        if residual > 0 { entries.append((Self.residualID, .residual, residual)) }
        let rects = Self.squarify(entries.map { Double($0.bytes) }, in: rect)
        tiles = zip(entries, rects).map { Tile(id: $0.id, content: $0.content, bytes: $0.bytes, rect: $1) }
        self.other = other
        drawnBytes = entries.reduce(0) { $0 + $1.bytes }
    }

    /// The tile that holds `selection`: the entry itself, or its ancestor drawn at this level, so a row
    /// selected anywhere in the outline is outlined on the map.
    public func tile(holding selection: Int64?, parent: (Int64) -> Int64?) -> Int64? {
        let ids = Set(tiles.map(\.id))
        var current = selection, steps = 0
        while let id = current, steps < 1024 {
            if ids.contains(id) { return id }
            current = parent(id); steps += 1
        }
        return nil
    }

    /// Squarified treemap (Bruls, Huizing, van Wijk). Keeps the input order, so equal inputs always give
    /// equal layouts, and each rectangle's area is proportional to its weight.
    public static func squarify(_ weights: [Double], in rect: CGRect) -> [CGRect] {
        let total = weights.reduce(0, +)
        guard total > 0, rect.width > 0, rect.height > 0 else { return weights.map { _ in .zero } }
        let scale = Double(rect.width * rect.height) / total
        var result = [CGRect](repeating: .zero, count: weights.count)
        var remaining = rect
        var index = 0
        func worst(_ row: [Double], side: Double) -> Double {
            let sum = row.reduce(0, +), largest = row.max() ?? 0, smallest = row.min() ?? 0
            guard sum > 0, smallest > 0 else { return .infinity }
            return max(side * side * largest / (sum * sum), (sum * sum) / (side * side * smallest))
        }
        while index < weights.count {
            let side = Double(min(remaining.width, remaining.height))
            var row = [weights[index] * scale]
            var end = index + 1
            while end < weights.count {
                let candidate = row + [weights[end] * scale]
                if worst(candidate, side: side) > worst(row, side: side) { break }
                row = candidate; end += 1
            }
            let rowArea = row.reduce(0, +)
            if remaining.width >= remaining.height {
                // Lay the row out as a column on the left.
                let width = remaining.height > 0 ? rowArea / Double(remaining.height) : 0
                var y = Double(remaining.minY)
                for (offset, area) in row.enumerated() {
                    let height = width > 0 ? area / width : 0
                    result[index + offset] = CGRect(x: Double(remaining.minX), y: y, width: width, height: height)
                    y += height
                }
                remaining = CGRect(x: remaining.minX + width, y: remaining.minY, width: max(0, remaining.width - width), height: remaining.height)
            } else {
                // Lay the row out along the top.
                let height = remaining.width > 0 ? rowArea / Double(remaining.width) : 0
                var x = Double(remaining.minX)
                for (offset, area) in row.enumerated() {
                    let width = height > 0 ? area / height : 0
                    result[index + offset] = CGRect(x: x, y: Double(remaining.minY), width: width, height: height)
                    x += width
                }
                remaining = CGRect(x: remaining.minX, y: remaining.minY + height, width: remaining.width, height: max(0, remaining.height - height))
            }
            index = end
        }
        return result
    }
}
