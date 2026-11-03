import Foundation

/// Keeps a reload requested while a load is in flight, so it runs when that load ends instead of being dropped.
/// The browser reloads when its query changes; a refresh that arrives mid-load changes nothing, so without this
/// the view kept showing pre-refresh data until the next background tick.
public struct InventoryReloadGate: Sendable {
    public private(set) var pending = false
    public init() {}

    /// True when the reload can run now. While `loading`, the request is remembered and false is returned.
    public mutating func request(loading: Bool) -> Bool {
        if loading { pending = true; return false }
        return true
    }

    /// Call when a load ends. True when a reload was requested during it; the request is then consumed.
    public mutating func finish() -> Bool {
        defer { pending = false }
        return pending
    }
}

/// The name a confirmation should use for a folder: the index root reads "Startup Data", others their last component.
public func inventoryFolderName(path: String, rootPath: String?) -> String {
    if let rootPath, path == rootPath { return "Startup Data" }
    let name = URL(fileURLWithPath: path).lastPathComponent
    return name.isEmpty ? path : name
}
