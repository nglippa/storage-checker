import Foundation
import Darwin
import SQLite3

// Synthetic, disposable SQLite catalog only. No full-volume or production-catalog access.
@main struct CleanupReviewQueueBenchmark {
    static func main() async throws {
        let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("storage-monitor-review-benchmark-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let path = root.appendingPathComponent("catalog.sqlite3").path
        var db: OpaquePointer?
        guard sqlite3_open(path, &db) == SQLITE_OK else { throw InventoryReaderError.open("Synthetic benchmark catalog") }
        defer { sqlite3_close(db) }
        func sql(_ value: String) throws {
            guard sqlite3_exec(db, value, nil, nil, nil) == SQLITE_OK else { throw InventoryReaderError.query(String(cString: sqlite3_errmsg(db))) }
        }
        let count = 100_000
        try sql("""
        CREATE TABLE inventory_generations(id INTEGER PRIMARY KEY,root_path TEXT,active INTEGER,volume_uuid TEXT,event_availability TEXT);
        CREATE TABLE inventory_nodes(id INTEGER PRIMARY KEY,parent_id INTEGER,generation_id INTEGER,name TEXT,kind TEXT);
        CREATE TABLE inventory_invalidations(generation_id INTEGER);
        CREATE TABLE inventory_change_clock(id INTEGER PRIMARY KEY,journal_id TEXT,sequence INTEGER,retained_after INTEGER,signals_retained_after INTEGER);
        INSERT INTO inventory_generations VALUES(1,'/fixture',1,NULL,'available');
        INSERT INTO inventory_change_clock VALUES(1,'benchmark',0,0,0);
        WITH RECURSIVE numbers(id) AS (SELECT 1 UNION ALL SELECT id+1 FROM numbers WHERE id<\(count))
        INSERT INTO inventory_nodes SELECT id,1,1,'ordinary-'||id||'.txt','file' FROM numbers;
        """)
        let reader = InventoryReader(path: path)
        func milliseconds(_ start: Date) -> Double { Date().timeIntervalSince(start) * 1_000 }
        func percentile(_ samples: [Double], _ fraction: Double) -> Double { samples.sorted()[min(samples.count - 1, Int(Double(samples.count - 1) * fraction))] }
        var pages = [Double](), rows = 0, cursor: CleanupDiscoveryCursor?
        let start = Date()
        repeat {
            let began = Date()
            let page = try await reader.cleanupDiscoveryPage(after: cursor, limit: 256)
            pages.append(milliseconds(began)); rows += page.scannedRows; cursor = page.next
        } while cursor != nil
        print("Synthetic catalog rows: \(rows); SQLite bytes: \((try FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.int64Value ?? 0)")
        print(String(format: "Discovery metadata: %.2f ms total; page256 p50 %.3f / p95 %.3f / max %.3f ms", milliseconds(start), percentile(pages,0.5), percentile(pages,0.95), pages.max()!))
        var statement: OpaquePointer?
        sqlite3_prepare_v2(db, "EXPLAIN QUERY PLAN SELECT id,parent_id,name,kind,generation_id FROM inventory_nodes WHERE id>50000 ORDER BY id LIMIT 257", -1, &statement, nil)
        while sqlite3_step(statement) == SQLITE_ROW { print("SQLite plan: " + String(cString: sqlite3_column_text(statement,3))) }
        sqlite3_finalize(statement)
        let cache = root.appendingPathComponent("project/__pycache__")
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        try Data([1,2,3]).write(to: cache.appendingPathComponent("fixture.pyc"))
        let info = ArtifactProbe().info(cache.path)!
        func node(_ id: Int64) -> InventoryNode {
            InventoryNode(id:id,parentID:0,identity:.init(device:info.device,inode:info.inode,birthNanoseconds:info.birthNanoseconds),path:cache.path,name:"__pycache__",kind:.directory,
                logicalBytes:4096,allocatedBytes:id * 4096,previousLogicalBytes:nil,previousAllocatedBytes:nil,objectLogicalBytes:nil,objectAllocatedBytes:nil,directLogicalBytes:0,directAllocatedBytes:0,
                childCount:1,descendantFiles:1,descendantDirectories:0,status:.complete,coverageState:"complete",listingState:nil,statusReason:nil,measuredAt:Date(),modifiedAt:info.modified,generation:1,isHardlinkAlias:false,historicalGrowthBytes:nil)
        }
        let processes = ProcessObservation(executables:[],workingDirectories:[],inspected:10,unreadable:0)
        let environment = ArtifactEnvironment(home:root.path,pathDirectories:[],processes:{ processes },git:nil)
        var inspections = [Double]()
        for _ in 0..<100 {
            let began = Date(); _ = ArtifactInspector.inspect(node(1),environment:environment,budget:.init(entries:1000,reads:24,seconds:0.35)); inspections.append(milliseconds(began))
        }
        print(String(format:"Evidence/classification bytecode fixture: p50 %.3f / p95 %.3f ms; %.1f inspections/s", percentile(inspections,0.5),percentile(inspections,0.95),100_000/inspections.reduce(0,+)))
        let inspection = ArtifactInspector.inspect(node(1),environment:environment)
        let entries = (1...512).map { CleanupReviewQueueEntry(node:node(Int64($0)),inspection:inspection,journal:.init(journalID:"benchmark",sequence:0),processes:processes) }
        let snapshot = CleanupReviewQueueSnapshot(entries:entries,progress:.init(),cursor:nil,journal:nil)
        var filtering = [Double]()
        for _ in 0..<100 {
            let began = Date()
            for sort in CleanupReviewQueueSort.allCases { _ = snapshot.filtered(filter:.init(status:.reviewCandidate,tool:.python),sort:sort) }
            filtering.append(milliseconds(began))
        }
        print(String(format:"512-row filter + all five sorts: p50 %.3f / p95 %.3f ms",percentile(filtering,0.5),percentile(filtering,0.95)))
        let cancelledAt = Date()
        let task = Task { try await reader.cleanupDiscoveryPage(after:nil,limit:256) }
        task.cancel()
        do { _ = try await task.value } catch { }
        print(String(format:"Task cancellation observation: %.3f ms",milliseconds(cancelledAt)))
        var usage = rusage(); getrusage(RUSAGE_SELF,&usage)
        print("Process maximum RSS: \(usage.ru_maxrss) bytes; retained queue cap: 512; pending metadata cap: 256")
        let cpuBefore = Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec)/1_000_000
        try await Task.sleep(nanoseconds:250_000_000)
        getrusage(RUSAGE_SELF,&usage)
        let cpuAfter = Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec)/1_000_000
        print(String(format:"Idle interval 250ms: %.3f ms process CPU (no queue timer)",(cpuAfter-cpuBefore)*1000))
        print("Scope: synthetic warm metadata and bytecode-cache evidence, shared host; not a full-volume discovery or representative Git/process-heavy throughput benchmark.")
        print("Disposable benchmark catalog retained at \(path)")
    }
}
