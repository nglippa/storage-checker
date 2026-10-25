import Foundation
import Darwin
import SQLite3

public struct InventoryRequestBoundary: Codable, Sendable {
    public let generation: Int64
    public let generationCreatedAt: Double
    public let sequence: Int64
    public let endNodeID: Int64

    // Read-only capture linearizes the user request against listing starts. The
    // next start increments the clock; an already running listing cannot satisfy it.
    static func capture(database: String) throws -> InventoryRequestBoundary? {
        guard FileManager.default.fileExists(atPath: database) else { return nil }
        var db: OpaquePointer?, statement: OpaquePointer?
        defer { sqlite3_finalize(statement); sqlite3_close(db) }
        guard sqlite3_open_v2(database, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else { throw CocoaError(.fileReadUnknown) }
        sqlite3_busy_timeout(db, 100)
        guard sqlite3_prepare_v2(db, "SELECT name FROM pragma_table_info('inventory_generations') WHERE name='inventory_sequence'", -1, &statement, nil) == SQLITE_OK else { throw CocoaError(.fileReadUnknown) }
        let schema = sqlite3_step(statement)
        if schema == SQLITE_DONE { return nil } // Pre-inventory / legacy schema.
        guard schema == SQLITE_ROW else { throw CocoaError(.fileReadUnknown) }
        sqlite3_finalize(statement); statement = nil
        guard sqlite3_prepare_v2(db, "SELECT id,created_at,inventory_sequence,(SELECT COALESCE(MAX(id),0) FROM inventory_nodes) FROM inventory_generations WHERE active=1", -1, &statement, nil) == SQLITE_OK else { throw CocoaError(.fileReadUnknown) }
        let row = sqlite3_step(statement)
        if row == SQLITE_DONE { return nil }
        guard row == SQLITE_ROW, sqlite3_column_int64(statement, 2) < Int64.max else { throw CocoaError(.fileReadUnknown) }
        return InventoryRequestBoundary(generation: sqlite3_column_int64(statement, 0), generationCreatedAt: sqlite3_column_double(statement, 1), sequence: sqlite3_column_int64(statement, 2) + 1, endNodeID: sqlite3_column_int64(statement, 3))
    }
}

public struct InventoryWorkRequest: Codable, Sendable {
    public let id: UUID
    public let action: String
    public let path: String?
    public let requestedAt: Date
    public let boundary: InventoryRequestBoundary?
}

// The viewer writes operational requests, never inventory SQL. Immutable UUID files avoid
// overwriting an in-flight request; the worker only removes the exact file it consumed.
public enum InventoryRequests {
    public static func directory(database: String) -> URL {
        URL(fileURLWithPath: database).deletingLastPathComponent().appendingPathComponent("inventory-requests", isDirectory: true)
    }
    @discardableResult public static func enqueue(database: String, action: String, path: String? = nil) throws -> UUID {
        guard ["refresh", "pause", "resume", "focus"].contains(action) else { throw CocoaError(.validationMissingMandatoryProperty) }
        let folder = directory(database: database)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let boundary = action == "refresh" ? try InventoryRequestBoundary.capture(database: database) : nil
        let request = InventoryWorkRequest(id: UUID(), action: action, path: path, requestedAt: Date(), boundary: boundary)
        if action == "pause" {
            let cancel = folder.deletingLastPathComponent().appendingPathComponent("inventory.cancel")
            try Data("pause\n".utf8).write(to: cancel, options: .atomic)
            _ = chmod(cancel.path, 0o600)
        } else if action == "resume" {
            let cancel = folder.deletingLastPathComponent().appendingPathComponent("inventory.cancel")
            if FileManager.default.fileExists(atPath: cancel.path) { try FileManager.default.removeItem(at: cancel) }
        }
        let target = folder.appendingPathComponent(action == "focus" ? "focus.json" : request.id.uuidString + ".json")
        try JSONEncoder().encode(request).write(to: target, options: .atomic)
        _ = chmod(target.path, 0o600)
        return request.id
    }
}

// Serializes the viewer's latest selection before publishing the coalesced mailbox.
// Detached navigation tasks can otherwise finish out of order and restore old focus.
public actor InventoryFocusWriter {
    private var latest: UInt64 = 0
    public init() {}
    @discardableResult public func enqueue(database: String, path: String?, revision: UInt64) throws -> Bool {
        guard revision > latest else { return false }
        latest = revision
        _ = try InventoryRequests.enqueue(database: database, action: "focus", path: path)
        return true
    }
}
