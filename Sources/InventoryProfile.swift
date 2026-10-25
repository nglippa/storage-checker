import Foundation
import Darwin

// Opt-in, aggregate-only instrumentation. No paths or file contents are collected.
// The synchronous worker owns a profile on its thread; watchdog connections do not
// inherit it. Timings are monotonic. Aggregate time overlaps SQL statement time.
final class InventoryProfile {
    private static let key = "StorageMonitor.InventoryProfile"
    static var current: InventoryProfile? { Thread.current.threadDictionary[key] as? InventoryProfile }
    let started = DispatchTime.now().uptimeNanoseconds
    var nanoseconds = [String: UInt64]()
    var counts = [String: Int64]()
    var firstBrowsable: Double?
    var usefulPartial: Double?
    private var lastRateTime: Double = 0
    private var lastRateEntries: Int64 = 0
    private var lastRateDirectories: Int64 = 0
    private var rateWindows = [[String: Double]]()

    init() {
        for key in ["listings_attempted", "listings_completed", "listings_repeated", "listings_retried_changed", "listings_unavailable", "jobs_retried_event", "jobs_retried_event_gap", "jobs_skipped_satisfied", "new_entries_committed", "entries_remeasured_committed", "entries_pruned_committed", "prefix_names_replayed", "lock_failures"] { counts[key] = 0 }
        for key in ["directory_enumeration", "filesystem_metadata", "sqlite_statements", "transaction_commit", "directory_aggregates", "cleanup_execution", "fsevents_reconciliation", "lock_acquisition", "scheduling_delay", "retry_overhead", "checkpoint_replay"] { nanoseconds[key] = 0 }
    }

    func withScope<T>(_ body: () throws -> T) rethrows -> T {
        let previous = Thread.current.threadDictionary[Self.key]
        Thread.current.threadDictionary[Self.key] = self
        defer { Thread.current.threadDictionary[Self.key] = previous }
        return try body()
    }
    func add(_ name: String, _ value: Int64 = 1) { counts[name, default: 0] += value }
    func elapsed() -> Double { Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000_000 }
    func timed<T>(_ name: String, _ body: () throws -> T) rethrows -> T {
        let previousErrno = errno
        let began = DispatchTime.now().uptimeNanoseconds
        errno = previousErrno
        defer {
            let bodyErrno = errno
            nanoseconds[name, default: 0] += DispatchTime.now().uptimeNanoseconds - began
            errno = bodyErrno
        }
        return try body()
    }
    func observedCommit() {
        if firstBrowsable == nil, counts["new_entries_committed", default: 0] > 0 { firstBrowsable = elapsed() }
        if usefulPartial == nil, counts["new_entries_committed", default: 0] >= 1_000 { usefulPartial = elapsed() }
        let now = elapsed()
        if now - lastRateTime >= 0.5 {
            let entries = counts["new_entries_committed", default: 0], directories = counts["listings_completed", default: 0]
            if rateWindows.count == 64 { rateWindows.removeFirst() }
            rateWindows.append(["elapsed_seconds": now, "entries_per_second": Double(entries-lastRateEntries)/(now-lastRateTime), "directories_per_second": Double(directories-lastRateDirectories)/(now-lastRateTime)])
            lastRateTime = now; lastRateEntries = entries; lastRateDirectories = directories
        }
    }
    var json: [String: Any] {
        let wall = elapsed()
        var result: [String: Any] = ["wall_seconds": wall, "counts": counts,
            "seconds": nanoseconds.mapValues { Double($0) / 1_000_000_000 },
            "new_entries_per_second": Double(counts["new_entries_committed", default: 0]) / max(wall, 0.000001),
            "completed_listings_per_second": Double(counts["listings_completed", default: 0]) / max(wall, 0.000001),
            "timing_note": "SQL statement time includes aggregate queries; aggregate and cleanup timers overlap it. I/O, metadata, commits, lock waits and scheduling are separate. Useful partial means 1000 committed discovered entries."]
        if let firstBrowsable { result["first_browsable_seconds"] = firstBrowsable }
        if let usefulPartial { result["useful_partial_seconds"] = usefulPartial }
        result["sustained_rate_windows_last_64"] = rateWindows
        return result
    }
}
