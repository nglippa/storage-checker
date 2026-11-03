import Foundation
import CoreGraphics

// Storage Atlas: presentation logic for the spatial storage map, the Navigator and the Inspector, kept free
// of SwiftUI so it can be tested. Geometry comes from InventoryMapPlan unchanged: every plate's area stays
// proportional to its indexed allocated size; nothing here reshapes or rescales a region.

/// A colour as hue, saturation, brightness and opacity (0–1), turned into a SwiftUI colour by the view.
public struct AtlasTone: Equatable, Sendable {
    public let hue: Double, saturation: Double, brightness: Double, opacity: Double
    public init(hue: Double, saturation: Double, brightness: Double, opacity: Double = 1) {
        self.hue = hue; self.saturation = saturation; self.brightness = brightness; self.opacity = opacity
    }
}

/// How a plate is painted. Top-level folder regions take one of a few restrained hues so neighbouring
/// regions read as different places; the contents of a region keep its hue at a lighter step; files are
/// neutral graphite tinted by their region. Measurement states keep their own, hue-independent cues.
public enum AtlasPalette {
    /// Muted hues (degrees): slate blue, teal, violet, sage, clay, steel. Ordered so neighbours contrast.
    public static let regionHues: [Double] = [222, 176, 262, 138, 24, 200]

    public enum Treatment: Equatable, Sendable {
        case measured, partial, earlier, other, residual
    }

    public static func treatment(_ node: InventoryNode) -> Treatment {
        switch node.status {
        case .lowerBound: return .partial
        case .stale: return .earlier
        default: return .measured
        }
    }

    /// The hue of top-level region `index` (map order, so the same folder keeps its hue while its rank holds).
    public static func regionHue(_ index: Int) -> Double { regionHues[((index % regionHues.count) + regionHues.count) % regionHues.count] / 360 }

    /// - Parameters:
    ///   - depth: 0 for a top-level plate, 1 for a plate inside a region.
    ///   - dark: dark appearance.
    public static func tone(hue: Double, isFolder: Bool, depth: Int, treatment: Treatment, dark: Bool) -> AtlasTone {
        switch treatment {
        case .other: return AtlasTone(hue: hue, saturation: 0.05, brightness: dark ? 0.30 : 0.86)
        case .residual: return AtlasTone(hue: hue, saturation: 0.04, brightness: dark ? 0.17 : 0.93)
        default: break
        }
        var saturation = isFolder ? (dark ? 0.42 : 0.30) : (dark ? 0.12 : 0.08)
        var brightness = isFolder ? (dark ? 0.40 : 0.80) : (dark ? 0.33 : 0.88)
        if depth > 0 { brightness += dark ? 0.08 : 0.06; saturation -= 0.04 }
        // An earlier (stale) size is drawn a little quieter, never in a different hue; its dashed edge (or the
        // folder's shared note) carries the meaning.
        if treatment == .earlier { saturation *= 0.82; brightness = dark ? brightness - 0.04 : brightness + 0.03 }
        return AtlasTone(hue: hue, saturation: max(0, saturation), brightness: min(1, max(0, brightness)))
    }
}

/// The zoom used when entering or leaving a folder. Uniform scaling only: proportions between plates are
/// never distorted, and Reduce Motion replaces it with a cross-fade.
public struct AtlasZoom: Equatable, Sendable {
    public let scale: Double
    public let offset: CGSize

    public static let identity = AtlasZoom(scale: 1, offset: .zero)

    public init(scale: Double, offset: CGSize) { self.scale = scale; self.offset = offset }

    /// The starting transform of the new view. Entering: the new folder starts small, inside the plate it
    /// occupied (`rect`). Leaving: the parent starts enlarged so the folder you left fills the view.
    public static func start(entering: Bool, rect: CGRect, in size: CGSize) -> AtlasZoom {
        guard size.width > 0, size.height > 0, rect.width > 0, rect.height > 0 else { return .identity }
        if entering {
            let s = min(rect.width / size.width, rect.height / size.height)
            // Centre the scaled view in the plate.
            let x = rect.midX - size.width * s / 2, y = rect.midY - size.height * s / 2
            return AtlasZoom(scale: s, offset: CGSize(width: x, height: y))
        } else {
            let s = min(size.width / rect.width, size.height / rect.height)
            let x = size.width / 2 - rect.midX * s, y = size.height / 2 - rect.midY * s
            return AtlasZoom(scale: s, offset: CGSize(width: x, height: y))
        }
    }

    /// Interpolates towards identity: `progress` 0 is `self`, 1 is identity.
    public func interpolated(_ progress: Double) -> AtlasZoom {
        let p = min(1, max(0, progress))
        return AtlasZoom(scale: scale + (1 - scale) * p, offset: CGSize(width: offset.width * (1 - p), height: offset.height * (1 - p)))
    }

    /// Where a point of the view lands under this transform (top-leading anchor).
    public func apply(_ point: CGPoint) -> CGPoint { CGPoint(x: point.x * scale + offset.width, y: point.y * scale + offset.height) }

    /// Reduce Motion: no spatial movement at all, only a short cross-fade.
    public static func animates(reduceMotion: Bool) -> Bool { !reduceMotion }
}

/// What lies under a point of the Atlas: a top-level plate, or a plate inside a region.
public struct AtlasHit: Equatable, Sendable {
    public let tile: Int64
    /// The region (top-level folder) holding a nested plate; nil for a top-level plate.
    public let region: Int64?
}

public enum AtlasHitTest {
    /// `nested` maps a region's tile id to its inner plan and the inner plan's origin within the map.
    public static func hit(_ point: CGPoint, plan: InventoryMapPlan, nested: [Int64: (plan: InventoryMapPlan, origin: CGPoint)]) -> AtlasHit? {
        guard let tile = plan.tiles.first(where: { $0.rect.contains(point) }) else { return nil }
        if let inner = nested[tile.id] {
            let local = CGPoint(x: point.x - inner.origin.x, y: point.y - inner.origin.y)
            if let child = inner.plan.tiles.first(where: { $0.rect.contains(local) }) { return AtlasHit(tile: child.id, region: tile.id) }
        }
        return AtlasHit(tile: tile.id, region: nil)
    }
}

/// What the Inspector shows for a selection (or the current folder when nothing is selected).
public struct InventoryInspectorPresentation: Equatable, Sendable {
    public let name: String
    public let kind: String
    public let path: String
    public let allocated: String
    public let logical: String
    /// Share of the enclosing folder's allocated size (0–1), when both are measured.
    public let shareOfParent: Double?
    public let shareText: String?
    public let measurement: String
    public let explanation: String?
    public let contents: String?
    public let measured: Date?

    public init(node: InventoryNode, parent: InventoryNode?, typeDescription: String? = nil, formatter: (Int64) -> String) {
        name = node.parentID == nil ? "Startup Data" : node.name
        switch node.kind {
        case .directory: kind = typeDescription ?? "Folder"
        case .symlink: kind = "Symbolic link"
        default: kind = typeDescription ?? "File"
        }
        path = node.path
        let weight = InventoryMapPlan.weight(node)
        allocated = InventoryNodePresentation.size(weight, node: node, formatter: formatter)
        logical = node.status == .unknown ? "—" : InventoryNodePresentation.size(node.objectLogicalBytes ?? node.logicalBytes ?? node.previousLogicalBytes, node: node, formatter: formatter)
        if let weight, let parentWeight = parent.flatMap(InventoryMapPlan.weight), parentWeight > 0 {
            let share = min(1, Double(weight) / Double(parentWeight))
            shareOfParent = share
            let percent = share * 100
            shareText = (percent > 0 && percent < 0.1 ? "less than 0.1%" : String(format: percent < 10 ? "%.1f%%" : "%.0f%%", percent)) + " of \(parent!.parentID == nil ? "Startup Data" : parent!.name)"
        } else { shareOfParent = nil; shareText = nil }
        measurement = InventoryNodePresentation.coverage(node)
        explanation = Self.explanation(node)
        if node.kind == .directory, node.status != .unknown {
            contents = "\(node.childCount.formatted()) items · \(node.descendantFiles.formatted()) files and \(node.descendantDirectories.formatted()) folders inside"
        } else { contents = nil }
        measured = node.measuredAt
    }

    private static func explanation(_ node: InventoryNode) -> String? {
        let coverage = InventoryNodePresentation.coverage(node)
        switch coverage {
        case "Complete": return nil
        case "Includes earlier sizes": return "This folder was listed recently, but some subfolders still show their earlier sizes while they are rechecked."
        case "Previously measured": return "This size is from the last completed measurement. The folder is waiting to be checked again."
        case "Waiting to be rechecked": return "Nothing has been measured here yet; it is queued for a recheck."
        case "Kept changing · earlier size": return "This folder changed during every attempt to list it, so its earlier size is shown."
        case "Access restricted": return "macOS did not allow Storage Monitor to read this folder, so its size is unknown, not zero."
        default: return node.statusReason
        }
    }
}

/// The Navigator's compact state glyph: nothing for measured entries, a symbol otherwise.
public enum InventoryNavigatorGlyph: String, Sendable {
    case partial = "circle.lefthalf.filled"
    case earlier = "clock.arrow.circlepath"
    case restricted = "lock"
    case waiting = "hourglass"
    case changing = "arrow.triangle.2.circlepath"

    public static func glyph(_ node: InventoryNode) -> InventoryNavigatorGlyph? {
        switch InventoryNodePresentation.coverage(node) {
        case "Complete", "Hard-link alias": return nil
        case "Access restricted", "Unavailable", "Not available": return .restricted
        case "Kept changing · earlier size": return .changing
        case "Waiting to be rechecked", "Discovered", "Indexing", "Not measured": return .waiting
        case "Previously measured", "Includes earlier sizes": return .earlier
        default: return node.status == .lowerBound ? .partial : .waiting
        }
    }
}

/// Middle truncation used by Atlas labels: keeps the start and the end of a name (file extensions and hash
/// suffixes stay readable). `keeping` counts visible characters including the ellipsis.
public func atlasMiddleTruncated(_ text: String, keeping count: Int) -> String {
    guard text.count > count else { return text }
    guard count >= 2 else { return count == 1 ? "…" : "" }
    let head = (count - 1 + 1) / 2, tail = count - 1 - head
    return String(text.prefix(head)) + "…" + String(text.suffix(tail))
}

/// Keys in order of last use with a fixed capacity: what the nested Atlas cache keeps.
public struct InventoryRecency: Equatable, Sendable {
    public private(set) var keys = [Int64]()
    public let capacity: Int
    public init(capacity: Int) { self.capacity = capacity }

    /// Marks `key` as used; returns the keys dropped to stay within capacity (least recently used first).
    @discardableResult
    public mutating func use(_ key: Int64) -> [Int64] {
        keys.removeAll { $0 == key }
        keys.append(key)
        guard keys.count > capacity else { return [] }
        let dropped = Array(keys.prefix(keys.count - capacity))
        keys.removeFirst(dropped.count)
        return dropped
    }
}
