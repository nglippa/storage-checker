import Foundation
import SQLite3

actor HistoryReader {
    let path: String
    init(path: String) { self.path = path }
    /// Global helper health needs only the latest valid startup reading, regardless of the selected drive.
    func latestTimestamp() throws -> Date? {
        guard FileManager.default.fileExists(atPath: path) else { throw HistoryError.missing(path) }
        var db: OpaquePointer?, statement: OpaquePointer?
        defer { sqlite3_finalize(statement); sqlite3_close(db) }
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else { throw HistoryError.sqlite("Cannot read latest capacity timestamp") }
        sqlite3_busy_timeout(db, 2000)
        guard sqlite3_prepare_v2(db, "SELECT timestamp,free,used FROM readings ORDER BY timestamp DESC,id DESC LIMIT 1", -1, &statement, nil) == SQLITE_OK else { throw HistoryError.sqlite("Cannot query latest capacity timestamp") }
        let result = sqlite3_step(statement)
        if result == SQLITE_DONE { return nil }
        guard result == SQLITE_ROW, let timeText = sqlite3_column_text(statement, 0),
              let freeText = sqlite3_column_text(statement, 1), let usedText = sqlite3_column_text(statement, 2),
              let timestamp = Double(String(cString: timeText)), timestamp.isFinite,
              let free = Int64(String(cString: freeText)), let used = Int64(String(cString: usedText)),
              free >= 0, used >= 0, free <= Int64.max - used, free + used > 0 else { throw HistoryError.invalid("Invalid latest capacity reading") }
        return Date(timeIntervalSince1970: timestamp)
    }
    func load() throws -> HistorySnapshot {
        guard FileManager.default.fileExists(atPath: path) else { throw HistoryError.missing(path) }
        var handle: OpaquePointer?
        let rc = sqlite3_open_v2(path, &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil)
        defer { sqlite3_close(handle) }
        guard rc == SQLITE_OK, let db = handle else { throw HistoryError.sqlite(handle.map { String(cString: sqlite3_errmsg($0)) } ?? "Open failed") }
        sqlite3_busy_timeout(db, 2000)
        func execute(_ sql: String) throws { guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw HistoryError.sqlite(String(cString: sqlite3_errmsg(db))) } }
        func query(_ sql: String) throws -> [[String: String]] {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { throw HistoryError.sqlite(String(cString: sqlite3_errmsg(db))) }
            defer { sqlite3_finalize(stmt) }
            var rows = [[String: String]]()
            while true {
                let rc = sqlite3_step(stmt)
                if rc == SQLITE_DONE { return rows }
                guard rc == SQLITE_ROW else { throw HistoryError.sqlite(String(cString: sqlite3_errmsg(db))) }
                var row = [String: String]()
                for index in 0..<sqlite3_column_count(stmt) {
                    let key = String(cString:sqlite3_column_name(stmt,index))
                    if sqlite3_column_type(stmt,index) == SQLITE_FLOAT {
                        // SQLite's default REAL-to-text formatting can lose subsecond
                        // precision. Preserve the original IEEE value for event times.
                        row[key] = String(format:"%.17g",sqlite3_column_double(stmt,index))
                    } else if let text = sqlite3_column_text(stmt,index) { row[key] = String(cString:text) }
                }
                rows.append(row)
            }
        }
        // The existing writer uses DELETE journal mode. Short read-only transactions
        // preserve its contract; close the connection before parsing JSON/projecting UI.
        try execute("PRAGMA query_only=ON; BEGIN DEFERRED;")
        let rawReadings: [[String:String]], rawAlerts: [[String:String]], rawDiagnostics: [[String:String]], rawIntervals: [[String:String]], rawLifecycle: String?, rawCoverage: String?
        let segmentStarts: Set<Int64>
        do {
            rawReadings = try query("SELECT * FROM readings ORDER BY timestamp DESC,id DESC LIMIT 10000")
            rawAlerts = try query("SELECT * FROM alerts ORDER BY timestamp DESC,id DESC LIMIT 5000")
            rawDiagnostics = try query("SELECT * FROM diagnostics ORDER BY timestamp DESC,id DESC LIMIT 120")
            // Older databases do not have this table; it is optional.
            let hasIntervals = try !query("SELECT name FROM sqlite_master WHERE type='table' AND name='interval_evidence'").isEmpty
            rawIntervals = hasIntervals ? try query("SELECT reading_id,evidence FROM interval_evidence ORDER BY reading_id DESC LIMIT 10000") : []
            let hasState = try !query("SELECT name FROM sqlite_master WHERE type='table' AND name='state'").isEmpty
            rawLifecycle = hasState ? try query("SELECT value FROM state WHERE key='attribution_lifecycle'").first?["value"] : nil
            rawCoverage = hasState ? try query("SELECT value FROM state WHERE key='coverage_lifecycle'").first?["value"] : nil
            let hasSessions = try !query("SELECT name FROM sqlite_master WHERE type='table' AND name='external_capacity_sessions'").isEmpty
            segmentStarts = hasSessions ? Set(try query("SELECT reading_id FROM external_capacity_sessions").compactMap { $0["reading_id"].flatMap(Int64.init) }) : []
            try execute("COMMIT")
        } catch { try? execute("ROLLBACK"); throw error }
        // Finalize and close now, not while UI projection is doing JSON work.
        sqlite3_close(handle); handle = nil
        func integer(_ row: [String:String], _ name: String) throws -> Int64 { guard let value = Int64(row[name] ?? "") else { throw HistoryError.invalid("Missing integer \(name)") }; return value }
        func timestamp(_ row: [String:String]) throws -> Date { guard let value = Double(row["timestamp"] ?? ""), value.isFinite else { throw HistoryError.invalid("Invalid timestamp") }; return Date(timeIntervalSince1970: value) }
        let readings = try rawReadings.map { row -> Measurement in
            let free = try integer(row,"free"), used = try integer(row,"used")
            guard free >= 0, used >= 0, free <= Int64.max - used, free + used > 0, let container = row["container"] else { throw HistoryError.invalid("Invalid capacity") }
            let volumes = try JSONSerialization.jsonObject(with: Data((row["volumes"] ?? "[]").utf8))
            return Measurement(id: try integer(row,"id"), timestamp: try timestamp(row), container: container, free: free, used: used, volumes: EvidenceParser.volumes(volumes))
        }
        let alerts = try rawAlerts.map { row in AlertRecord(id: try integer(row,"id"), timestamp: try timestamp(row), severity: EventSeverity(recorded: row["severity"] ?? ""), reasons: row["reasons"] ?? "", free: try integer(row,"free"), delta: row["delta"].flatMap(Int64.init), notification: row["notification"] ?? "", rawSeverity:row["severity"] ?? "") }
        let diagnostics = try rawDiagnostics.map { row in try EvidenceParser.diagnostic(id: integer(row,"id"), timestamp: timestamp(row), json: row["snapshot"] ?? "{}") }
        var intervals = [Int64: IntervalEvidence]()
        for row in rawIntervals { if let id = Int64(row["reading_id"] ?? ""), let value = IntervalEvidence.parse(readingId: id, json: row["evidence"] ?? "") { intervals[id] = value } }
        var snapshot = EventProjector.project(measurements: readings, alerts: alerts, diagnostics: diagnostics, intervals: intervals, segmentStarts: segmentStarts)
        snapshot.folderMonitoring = rawLifecycle.flatMap(FolderMonitoringStatus.parse)
        snapshot.filesystemCoverage = rawCoverage.flatMap(FilesystemCoverageStatus.parse)
        return snapshot
    }
}
