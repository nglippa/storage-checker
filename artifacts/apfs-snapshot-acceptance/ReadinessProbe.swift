import Foundation
import SQLite3
import Darwin

/// Acceptance harness, never an installed command. Writes only explicitly supplied
/// disposable databases; live mode reads APFS metadata without filesystem traversal.
@main enum APFSReadinessProbe {
    static func main() async throws {
        let args = Array(CommandLine.arguments.dropFirst())
        try required(args.count == 2 && ["migrate", "live"].contains(args[0]), "Expected migrate|live and a disposable database path")
        let databasePath = args[1]
        let parent = (databasePath as NSString).deletingLastPathComponent
        guard let resolvedParent = realpath(parent, nil) else { throw Failure("Acceptance parent must exist") }
        defer { free(resolvedParent) }
        let canonical = String(cString: resolvedParent) + "/" + (databasePath as NSString).lastPathComponent
        try required(databasePath.hasPrefix("/private/tmp/storage-apfs-acceptance-") && canonical == databasePath,
                     "Acceptance database must be an unaliased disposable path")
        let path = URL(fileURLWithPath: databasePath)
        if args[0] == "migrate" {
            try required(FileManager.default.fileExists(atPath: databasePath), "Migration requires a prepared clone")
            let db = try Database(databasePath, noFollow: true)
            try required(!db.transactionActive, "Migration left a transaction active")
        } else {
            try required(!FileManager.default.fileExists(atPath: databasePath), "Live probe requires a fresh database")
            let db = try Database(databasePath, noFollow: true)
            for _ in 0..<2 {
                let current = try measure()
                let plan = try AlertPlan(db, current, evaluate(current, nil, []))
                let id = try persistStartupReading(current, plan: plan, db: db)
                // This is deliberately after the durable capacity commit.
                let observation = SnapshotObserver.capture(current)
                storeOptionalStorageObservation(observation, readingID: id, reading: current,
                                                db: db, logDirectory: path.deletingLastPathComponent())
            }
            try required(try db.rows("SELECT * FROM readings").count == 2 &&
                         db.rows("SELECT * FROM storage_observations").count == 2 && !db.transactionActive,
                         "Two actual readings and observations must be durable")
        }
        let history = try await HistoryReader(path: databasePath).load()
        var summary: [String: Any] = ["mode": args[0], "database": databasePath,
            "readings": history.measurements.count, "events": history.events.count,
            "capacity_history": history.measurements.map { ["id": $0.id, "timestamp": $0.timestamp.timeIntervalSince1970,
                "container": $0.container, "free": $0.free, "used": $0.used] as [String: Any] }]
        if args[0] == "live" {
            let latest = history.events.last!
            try required(latest.observationContinuous && latest.snapshotComparison.comparedVolumes > 0,
                         "Viewer must compare the same two actual observations")
            summary["continuous"] = latest.observationContinuous
            summary["compared_volumes"] = latest.snapshotComparison.comparedVolumes
            summary["snapshot_changes"] = latest.snapshotComparison.changes.count
            summary["inventories"] = latest.observation!.inventories.map {
                ["volume": $0.volumeUUID, "status": $0.status.rawValue,
                 "snapshots": $0.status == .complete ? $0.snapshots.count as Any : NSNull()] as [String: Any]
            }
            summary["observation_detail"] = latest.observation!.detail
            let liveCapacity = try LiveCapacityProbe.read()
            let recorded = latest.measurement!
            summary["free_comparison"] = [
                "recorded_diskutil_free": recorded.free,
                "live_statfs_free": liveCapacity.free,
                "difference_bytes": liveCapacity.free - recorded.free,
                "seconds_after_recorded": liveCapacity.timestamp.timeIntervalSince(recorded.timestamp),
                "foundation_available": liveCapacity.availableBytes.map { $0 as Any } ?? NSNull(),
                "foundation_important": liveCapacity.importantAvailableBytes.map { $0 as Any } ?? NSNull(),
                "foundation_opportunistic": liveCapacity.opportunisticAvailableBytes.map { $0 as Any } ?? NSNull()
            ] as [String: Any]
        }
        let output = try JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted, .sortedKeys])
        print(String(decoding: output, as: UTF8.self))
    }
}
