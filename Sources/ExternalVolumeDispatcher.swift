import Foundation
import Darwin

private struct ExternalDispatchProgress: Codable { var last: String? }
struct ExternalDispatchDependencies {
    let discover: () throws -> ExternalVolumeObservations
    let validateExternal: (ExternalVolumeDescriptor, ExternalVolumeRegistry) throws -> Void
    let runStartup: ([String], URL) async throws -> InventoryRunResult?
    let runExternal: (URL, ExternalVolumeDescriptor, TimeInterval) async throws -> InventoryRunResult?
    let now: () -> TimeInterval

    static let live = ExternalDispatchDependencies(
        discover: ExternalVolumeDiscovery.discover,
        validateExternal: { descriptor, registry in _ = try ExternalVolumeMountLease(descriptor: descriptor, registry: registry) },
        runStartup: { args, directory in try await inventoryCommand("inventory-update", args: args, directory: directory, coordinated: true) },
        runExternal: { directory, descriptor, budget in try await runExternalInventorySlice(baseDirectory: directory, descriptor: descriptor, budget: budget) },
        now: { ProcessInfo.processInfo.systemUptime })
}

private struct ExternalWorkingLineage: Codable, Equatable {
    var version = 1
    let volumeUUID: String
    let capacityScope: String
    let backingUUIDs: [String]
}

func observeExternalVolumesForDispatch(directory: URL, discovery: () throws -> ExternalVolumeObservations = ExternalVolumeDiscovery.discover) throws -> ExternalVolumeObservations {
    let mailbox = InventoryRequests.directory(database: directory.appendingPathComponent("history.sqlite3").path)
    try ExternalVolumeStorage.ensureDirectory(mailbox)
    let signal = mailbox.appendingPathComponent("external-wake.json")
    let claimed = mailbox.appendingPathComponent(".external-claimed-\(UUID().uuidString)")
    // Claim before sampling: any new mount or control wake during discovery survives this wave.
    if rename(signal.path, claimed.path) == 0 { try? FileManager.default.removeItem(at: claimed) }
    let observations = try discovery()
    try ExternalVolumeObservationStore(baseDirectory: directory).write(observations)
    return observations
}

/// One canonical process owns the dispatcher lock. Each wave alternates startup and chosen external targets.
/// Offline/paused drives are omitted; only runnable work requests a launchd continuation.
func dispatchExternalInventory(directory: URL, args: [String]) async throws -> Bool {
    try await dispatchExternalInventory(directory: directory, args: args, dependencies: .live)
}

#if INVENTORY_TESTS
func dispatchExternalInventoryForTesting(directory: URL, args: [String], dependencies: ExternalDispatchDependencies) async throws -> Bool {
    try await dispatchExternalInventory(directory: directory, args: args, dependencies: dependencies)
}
#endif

private func dispatchExternalInventory(directory: URL, args: [String], dependencies: ExternalDispatchDependencies) async throws -> Bool {
    try ExternalVolumeStorage.ensureDirectory(directory)
    guard let lock = FileLock(directory.appendingPathComponent("inventory-dispatch.lock").path, wait: 0) else { return false }
    defer { withExtendedLifetime(lock) {} }
    let registry = ExternalVolumeRegistry(baseDirectory: directory)
    let observations = try observeExternalVolumesForDispatch(directory: directory, discovery: dependencies.discover)
    let mailbox = InventoryRequests.directory(database: directory.appendingPathComponent("history.sqlite3").path)
    let signal = mailbox.appendingPathComponent("external-wake.json")
    let saved: ExternalVolumeRegistryDocument
    do { saved = try registry.read() }
    catch { log(directory, "external settings refused: \(error)"); return try await dependencies.runStartup(args, directory)?.runnableWorkRemains ?? false }
    var descriptors = [String: ExternalVolumeDescriptor]()
    for target in saved.volumes.values where target.enabled && !target.indexingPaused {
        do {
            if let descriptor = try ExternalVolumeCatalog.resolve(uuid: target.volumeUUID, descriptors: observations.descriptors) {
                try dependencies.validateExternal(descriptor, registry)
                descriptors[target.volumeUUID] = descriptor
            }
        } catch { log(directory, "external inventory \(target.volumeUUID) skipped: \(error)") }
    }
    var targets = [String](), startupTargets = Set<String>()
    if descriptors.isEmpty { targets = ["startup"]; startupTargets.insert("startup") }
    else {
        for uuid in descriptors.keys.sorted() {
            let startup = "startup:" + uuid
            targets += [startup, uuid]; startupTargets.insert(startup)
        }
    }
    let progressURL = registry.directory.appendingPathComponent("dispatcher.json")
    let previous = try? ExternalVolumeStorage.read(ExternalDispatchProgress.self, from: progressURL)
    let order = ExternalInventorySchedule.order(targets: targets, after: previous?.last)
    func value(_ flag: String) -> String? { guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }; return args[i + 1] }
    let budget = min(3_600, max(0.01, Double(value("--budget") ?? String(inventoryAgentBudget)) ?? Double(inventoryAgentBudget)))
    let deadline = dependencies.now() + budget
    var runnable = false
    for (index, key) in order.enumerated() {
        let remaining = deadline - dependencies.now()
        if remaining <= 0 || index > 0 && remaining < min(30, budget) { runnable = true; break }
        let allowance = max(0.01, remaining)
        do {
            let result: InventoryRunResult?
            if startupTargets.contains(key) {
                var startupArgs = args
                if let i = startupArgs.firstIndex(of: "--budget"), i + 1 < startupArgs.count { startupArgs.removeSubrange(i...i + 1) }
                startupArgs += ["--budget", String(allowance)]
                result = try await dependencies.runStartup(startupArgs, directory)
            } else if let descriptor = descriptors[key] {
                result = try await dependencies.runExternal(directory, descriptor, allowance)
            } else { result = nil }
            runnable = runnable || result?.runnableWorkRemains == true
        } catch { log(directory, "inventory target \(key) stopped: \(error)") }
        try ExternalVolumeStorage.write(ExternalDispatchProgress(last: key), to: progressURL)
    }
    // This also handles a coalesced discovery request with no enrolled drive: one extra wake, then normal idle.
    return runnable || FileManager.default.fileExists(atPath: signal.path)
}

func runExternalInventorySlice(baseDirectory: URL, descriptor: ExternalVolumeDescriptor, budget: TimeInterval) async throws -> InventoryRunResult {
    let registry = ExternalVolumeRegistry(baseDirectory: baseDirectory)
    let lease = try ExternalVolumeMountLease(descriptor: descriptor, registry: registry)
    return try await runExternalInventorySlice(baseDirectory: baseDirectory, lease: lease, budget: budget)
}

#if INVENTORY_TESTS
func runExternalInventorySliceForTesting(baseDirectory: URL, lease: ExternalVolumeMountLease, budget: TimeInterval) async throws -> InventoryRunResult {
    try await runExternalInventorySlice(baseDirectory: baseDirectory, lease: lease, budget: budget)
}
#endif

private func runExternalInventorySlice(baseDirectory: URL, lease: ExternalVolumeMountLease, budget: TimeInterval) async throws -> InventoryRunResult {
    let deadline = Date().addingTimeInterval(budget)
    let descriptor = lease.descriptor
    let saved = lease.registration
    let paths = try ExternalVolumePaths(baseDirectory: baseDirectory, uuid: saved.volumeUUID, capacityScope: saved.capacityScope)
    try paths.prepare()
    guard let commandLock = FileLock(paths.inventoryDirectory.appendingPathComponent("inventory-command.lock").path, wait: 0) else {
        return InventoryRunResult(outcome: "busy", generation: nil, entries: 0, directories: 0, pending: 0, reason: "Another inventory command is active")
    }
    defer { withExtendedLifetime(commandLock) {} }
    let working = try Database(paths.inventoryDatabase, busyTimeout: inventoryWorkerBusyTimeout, noFollow: true)
    try initializeInventorySchema(databasePath: paths.inventoryDatabase)
    try lease.validate()
    let lineage = ExternalWorkingLineage(volumeUUID: saved.volumeUUID, capacityScope: saved.capacityScope, backingUUIDs: saved.backingUUIDs)
    let lineageURL = paths.inventoryDirectory.appendingPathComponent("working-identity.json")
    let previousLineage = try? ExternalVolumeStorage.read(ExternalWorkingLineage.self, from: lineageURL)
    if let previousLineage, previousLineage.version != 1 { throw ExternalVolumeError.invalidRegistry }
    if previousLineage != lineage {
        // Deactivate before recording the new lineage. A crash at either step safely creates a fresh generation later.
        try lease.validate()
        try working.write("UPDATE inventory_generations SET active=0,state='superseded',updated_at=? WHERE active=1", [Date().timeIntervalSince1970])
        try ExternalVolumeStorage.write(lineage, to: lineageURL)
    }
    // Registry authority wins over a stale disable/pause marker left by an older control operation.
    let cancel = paths.inventoryDirectory.appendingPathComponent("inventory.cancel")
    if FileManager.default.fileExists(atPath: cancel.path) { try FileManager.default.removeItem(at: cancel) }
    let initial = runInventory(databasePath: paths.inventoryDatabase, directory: paths.inventoryDirectory, region: lease.region,
        options: InventoryRunOptions(maxDuration: 0), fdaOverride: "external-volume", gatedOverride: [], rootValidator: lease.validator)
    guard initial.outcome != "failed", initial.generation != nil else { return initial }
    try consumeInventoryRequests(database: paths.inventoryDatabase, directory: paths.inventoryDirectory, region: lease.region, rootValidator: lease.validator)
    let hasEvents = ["apfs", "hfs", "hfs+"].contains(descriptor.filesystem.lowercased())
    if hasEvents {
        try reconcileInventoryEvents(database: paths.inventoryDatabase, directory: paths.inventoryDirectory, region: lease.region, rootValidator: lease.validator, deadline: deadline)
    } else {
        let now = Date().timeIntervalSince1970
        let last = Double(try working.state("external_refresh_at")) ?? 0
        if now - last >= 1800, let state = try working.rows("SELECT state FROM inventory_generations WHERE active=1").first?["state"], ["complete", "partial"].contains(state) {
            try lease.validate()
            try requestInventoryRefresh(databasePath: paths.inventoryDatabase, paths: [lease.region.root])
            try working.state("external_refresh_at", String(now))
        }
    }
    var result = runInventory(databasePath: paths.inventoryDatabase, directory: paths.inventoryDirectory, region: lease.region,
        options: InventoryRunOptions(maxDuration: max(0, deadline.timeIntervalSinceNow), cancelFile: cancel.path, serviceRequests: true),
        fdaOverride: "external-volume", gatedOverride: [], rootValidator: lease.validator)
    if ["complete", "partial"].contains(result.outcome), let generation = result.generation {
        if !hasEvents, result.directories > 0 { try working.state("external_refresh_at", String(Date().timeIntervalSince1970)) }
        if hasEvents {
            guard deadline.timeIntervalSinceNow > 0 else { result.runnableWorkRemains = true; return result }
            try reconcileInventoryEvents(database: paths.inventoryDatabase, directory: paths.inventoryDirectory, region: lease.region, rootValidator: lease.validator, deadline: deadline)
            let closing = runInventory(databasePath: paths.inventoryDatabase, directory: paths.inventoryDirectory, region: lease.region,
                options: InventoryRunOptions(maxDuration: 0), fdaOverride: "external-volume", gatedOverride: [], rootValidator: lease.validator)
            guard ["complete", "partial"].contains(closing.outcome) else { return result }
        }
        let prior = try ExternalCatalogAccess.current(paths: paths)
        let sequence = try working.rows("SELECT inventory_sequence FROM inventory_generations WHERE active=1").first?["inventory_sequence"].flatMap(Int64.init)
        if prior == nil || prior?.generation != generation || prior?.inventorySequence != sequence || result.entries > 0 || result.directories > 0 {
            _ = try ExternalCatalogPublisher.publish(paths: paths, expectedGeneration: generation, settingsRevision: saved.revision, validate: lease.validate)
        }
    }
    return result
}
