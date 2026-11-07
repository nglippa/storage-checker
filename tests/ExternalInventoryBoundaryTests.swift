import Foundation
import Darwin
import SQLite3

#if INVENTORY_TESTS
private struct ExternalInventoryFixture {
    let root: URL
    let state: URL
    let database: String
    let region: CoverageRegion

    init(_ name: String, files: Int) throws {
        let base = "/private/tmp/storage-monitor-external-boundary-\(name)-\(UUID().uuidString)"
        root = URL(fileURLWithPath: base)
        state = URL(fileURLWithPath: base + "-state")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try privateDirectory(state)
        for index in 0..<files {
            try Data(repeating: UInt8(index & 255), count: 4_096).write(to: root.appendingPathComponent("file-\(index)"))
        }
        var info = stat()
        try required(lstat(root.path, &info) == 0, "stat external inventory fixture")
        region = CoverageRegion(mount: root.path, prefix: "", device: info.st_dev, deviceIdentifier: "external-boundary-test")
        database = state.appendingPathComponent("history.sqlite3").path
        _ = try Database(database)
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: state)
    }

    func scalar(_ sql: String, _ values: [Any] = []) throws -> Int64 {
        Int64(try Database(database).rows(sql, values).first?.values.first ?? "") ?? 0
    }

    func row(_ sql: String, _ values: [Any] = []) throws -> [String: String] {
        try Database(database).rows(sql, values).first ?? [:]
    }
}

private func rootJob(_ fixture: ExternalInventoryFixture) throws -> [String: String] {
    try fixture.row("SELECT j.state,j.listing_token,j.snapshot_device,j.completed_token,g.state AS generation_state,g.inventory_sequence FROM inventory_jobs j JOIN inventory_nodes n ON n.id=j.node_id JOIN inventory_generations g ON g.id=j.generation_id WHERE n.parent_id IS NULL")
}

private func assertUncommittedRoot(_ fixture: ExternalInventoryFixture, _ test: (Bool, String) throws -> Void, _ context: String) throws {
    let job = try rootJob(fixture)
    try test(try fixture.scalar("SELECT COUNT(*) FROM inventory_nodes") == 1, "\(context): no observed child is committed")
    try test(job["listing_token"] == "0" && job["snapshot_device"] == nil && job["completed_token"] == "0",
             "\(context): listing token and snapshot stay uncommitted")
    try test(try fixture.scalar("SELECT COUNT(*) FROM inventory_prune_jobs") == 0, "\(context): no false deletion work is created")
}

private func runStartBoundaryTest(_ test: (Bool, String) throws -> Void) throws {
    let fixture = try ExternalInventoryFixture("start", files: 1)
    defer { fixture.remove() }
    let result = runInventory(databasePath: fixture.database, directory: fixture.state, region: fixture.region,
                              options: InventoryRunOptions(maxDuration: 5), fdaOverride: "granted",
                              rootValidator: { _, boundary in
        if boundary == .runStart { throw InventoryRootValidationError.disconnected }
    })
    try test(result.outcome == "interrupted" && result.generation == nil && result.reason == InventoryRootValidationError.disconnected.description,
             "run-start root loss is a normal interrupted outcome")
    try test(try fixture.scalar("SELECT COUNT(*) FROM inventory_generations") == 0, "run-start root loss creates no generation")
}

private func requestBoundaryTest(_ test: (Bool, String) throws -> Void) throws {
    let fixture = try ExternalInventoryFixture("request", files: 20)
    defer { fixture.remove() }
    try initializeInventorySchema(databasePath: fixture.database)
    _ = try InventoryRequests.enqueue(database: fixture.database, action: "resume")
    let before = (try FileManager.default.contentsOfDirectory(atPath: InventoryRequests.directory(database: fixture.database).path)).count
    let result = runInventory(databasePath: fixture.database, directory: fixture.state, region: fixture.region,
                              options: InventoryRunOptions(maxDuration: 5, batchSize: 1, pause: 0.3, serviceRequests: true), fdaOverride: "granted",
                              rootValidator: { _, boundary in
        if boundary == .beforeRequestService { throw InventoryRootValidationError.disabled }
    })
    let after = (try FileManager.default.contentsOfDirectory(atPath: InventoryRequests.directory(database: fixture.database).path)).count
    try test(result.outcome == "interrupted" && result.reason == InventoryRootValidationError.disabled.description,
             "disabled validation stops request servicing normally")
    try test(before == 1 && after == before, "disabled validation leaves the durable request unconsumed")
}

private func afterListingBoundaryTest(_ test: (Bool, String) throws -> Void) throws {
    let fixture = try ExternalInventoryFixture("after-listing", files: 3)
    defer { fixture.remove() }
    let result = runInventory(databasePath: fixture.database, directory: fixture.state, region: fixture.region,
                              options: InventoryRunOptions(maxDuration: 5, batchSize: 1), fdaOverride: "granted",
                              rootValidator: { _, boundary in
        if case .afterListing = boundary { throw InventoryRootValidationError.identityChanged }
    })
    try test(result.outcome == "interrupted" && result.reason == InventoryRootValidationError.identityChanged.description,
             "identity loss after a listing never enters per-directory unavailable handling")
    try assertUncommittedRoot(fixture, test, "after-listing root loss")
}

private func directCommitBoundaryTest(_ test: (Bool, String) throws -> Void) throws {
    let fixture = try ExternalInventoryFixture("direct-commit", files: 3)
    defer { fixture.remove() }
    let result = runInventory(databasePath: fixture.database, directory: fixture.state, region: fixture.region,
                              options: InventoryRunOptions(maxDuration: 5, batchSize: 1), fdaOverride: "granted",
                              rootValidator: { _, boundary in
        if case .beforeCommit = boundary { throw InventoryRootValidationError.disconnected }
    })
    try test(result.outcome == "interrupted", "direct batch commit is refused after disconnect")
    try assertUncommittedRoot(fixture, test, "direct-commit root loss")
}

private func groupedCommitBoundaryTest(_ test: (Bool, String) throws -> Void) throws {
    let fixture = try ExternalInventoryFixture("grouped-commit", files: 2)
    defer { fixture.remove() }
    let result = runInventory(databasePath: fixture.database, directory: fixture.state, region: fixture.region,
                              options: InventoryRunOptions(maxDuration: 5, batchSize: 256), fdaOverride: "granted",
                              rootValidator: { _, boundary in
        if case .beforeCommit = boundary { throw InventoryRootValidationError.disconnected }
    })
    try test(result.outcome == "interrupted", "grouped listing flush is refused after disconnect")
    try assertUncommittedRoot(fixture, test, "grouped-commit root loss")
}

private func finalizationBoundaryTest(_ test: (Bool, String) throws -> Void) throws {
    let fixture = try ExternalInventoryFixture("finalize", files: 3)
    defer { fixture.remove() }
    let result = runInventory(databasePath: fixture.database, directory: fixture.state, region: fixture.region,
                              options: InventoryRunOptions(maxDuration: 5, batchSize: 1), fdaOverride: "granted",
                              rootValidator: { _, boundary in
        if boundary == .beforeFinalize { throw InventoryRootValidationError.disconnected }
    })
    let job = try rootJob(fixture)
    try test(result.outcome == "interrupted", "finalization root loss remains a normal interrupted outcome")
    try test(try fixture.scalar("SELECT COUNT(*) FROM inventory_nodes") == 4, "committed pre-finalization batches remain readable")
    try test(job["state"] == "complete" && job["listing_token"] == "1" && job["completed_token"] == "1" && job["snapshot_device"] == nil,
             "finalization refusal retains the committed listing checkpoint")
    try test(job["generation_state"] == "building", "finalization refusal never publishes a terminal generation state")
    try test(try fixture.scalar("SELECT COUNT(*) FROM inventory_prune_jobs") == 0, "finalization refusal creates no false deletion work")
}

private func terminalBoundaryTest(_ test: (Bool, String) throws -> Void) throws {
    let fixture = try ExternalInventoryFixture("terminal", files: 2)
    defer { fixture.remove() }
    let result = runInventory(databasePath: fixture.database, directory: fixture.state, region: fixture.region,
                              options: InventoryRunOptions(maxDuration: 5, batchSize: 1), fdaOverride: "granted",
                              rootValidator: { _, boundary in
        if boundary == .beforeStatusCommit { throw InventoryRootValidationError.disconnected }
    })
    try test(result.outcome == "interrupted", "late root loss refuses terminal status commit")
    try test(try rootJob(fixture)["generation_state"] == "building", "late root loss cannot mark the generation complete")
    let region = CoverageRegion(mount: fixture.root.path, prefix: "", device: fixture.region.device,
                                deviceIdentifier: "external", usesFirmlinks: false)
    try test(region.display("Users/example/file") == fixture.root.path + "/Users/example/file", "external Users folders never use startup firmlinks")
    try test(region.absoluteForms("Users/example") == [fixture.root.path + "/Users/example"], "external absolute paths remain on selected filesystem")
    try test(consentGatedPaths(region).exact.isEmpty, "startup home consent gates cannot exclude external folders")
}

@main enum ExternalInventoryBoundaryTestMain {
    static func main() {
        let savedSpace = inventoryAvailableSpaceOverride
        inventoryAvailableSpaceOverride = (available: 1_000_000_000_000, capacity: 2_000_000_000_000)
        defer { inventoryAvailableSpaceOverride = savedSpace }
        do {
            var count = 0
            let test: (Bool, String) throws -> Void = { value, description in
                try required(value, "FAIL: \(description)")
                count += 1
                print("PASS \(description)")
            }
            try runStartBoundaryTest(test)
            try requestBoundaryTest(test)
            try afterListingBoundaryTest(test)
            try directCommitBoundaryTest(test)
            try groupedCommitBoundaryTest(test)
            try finalizationBoundaryTest(test)
            try terminalBoundaryTest(test)
            print("\(count) external inventory boundary tests passed")
        } catch {
            fputs("External inventory boundary tests: \(error)\n", stderr)
            exit(1)
        }
    }
}
#endif
