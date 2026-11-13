import SwiftUI
import AppKit
import ServiceManagement
import Security
import UniformTypeIdentifiers

private final class SnapshotReplyGate: @unchecked Sendable {
    let lock = NSLock()
    var continuation: CheckedContinuation<SnapshotServiceResponse, Never>?
    init(_ continuation: CheckedContinuation<SnapshotServiceResponse, Never>) { self.continuation = continuation }
    func finish(_ value: SnapshotServiceResponse) {
        lock.lock(); let target = continuation; continuation = nil; lock.unlock(); target?.resume(returning: value)
    }
}
@MainActor final class SnapshotManagementModel: ObservableObject {
    @Published var response = SnapshotServiceResponse()
    @Published var volumeID = ""
    @Published var selected = Set<String>()
    @Published var search = ""
    @Published var busy = false
    @Published var message = ""
    @Published var error: String?
    @Published var comparison: SnapshotFileComparison?
    @Published var comparisonSearch = ""
    @Published var serviceStatus = "Snapshot helper has not been enabled."
    @Published var available = false
    @Published var tmActivities: [TimeMachineSnapshotActivity] = []
    @Published var tmBusy = false
    @Published var tmError: String?
    @Published var tmNeedsAcknowledgement = false
    let isQA: Bool
    private var connection: NSXPCConnection?
    private var loading: Task<Void, Never>?
    private let timeMachineHistory: TimeMachineSnapshotHistory
    init(
        isQA: Bool,
        timeMachineDirectory: URL = MonitoringSetupStatus.dataDirectory(home: FileManager.default.homeDirectoryForCurrentUser)
            .appendingPathComponent("time-machine-snapshots", isDirectory: true),
        timeMachineRunner: any TimeMachineSnapshotCreating = SystemTimeMachineSnapshotCommand()
    ) {
        self.isQA = isQA
        self.timeMachineHistory = TimeMachineSnapshotHistory(directory: timeMachineDirectory, runner: timeMachineRunner)
    }
    var tmUncertainActivities: [TimeMachineSnapshotActivity] {
        tmActivities.filter { $0.outcome == .uncertain || $0.outcome == .interrupted }
    }
    var volume: ManagedVolume? { response.volumes.first { $0.id == volumeID } }
    var records: [ManagedSnapshot] { response.records.filter { $0.volumeUUID == volumeID && $0.state != .deleted } }
    var inventory: [LifecycleSnapshot] { response.inventories[volumeID] ?? [] }
    var visibleInventory: [LifecycleSnapshot] { inventory.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) || $0.id.localizedCaseInsensitiveContains(search) || (record($0)?.label.localizedCaseInsensitiveContains(search) ?? false) } }
    func record(_ snapshot: LifecycleSnapshot) -> ManagedSnapshot? {
        guard !snapshot.name.lowercased().hasPrefix("com.apple.timemachine.") else { return nil }
        return records.first { $0.snapshotUUID == snapshot.id && $0.name == snapshot.name && $0.xid == snapshot.xid && $0.state == .managed }
    }
    var selectedRecords: [ManagedSnapshot] { inventory.filter { selected.contains($0.id) }.compactMap { record($0) }.sorted { $0.createdAt < $1.createdAt } }
    var policy: SnapshotPolicy { response.policies.first { $0.volume.id == volumeID }?.policy ?? SnapshotPolicy() }
    var canMutate: Bool { available && !isQA && !busy && volume?.compatibilityIssue == nil }
    var helperURL: URL { Bundle.main.bundleURL.appendingPathComponent("Contents/Library/HelperTools/Storage Monitor Snapshot Service.app/Contents/MacOS/StorageMonitorSnapshotService") }
    func compatibility() -> String? {
        if isQA { return "Read-only QA session. Helper registration and all mutations are disabled." }
        let clientInfo = SnapshotCodeIdentity.information(), helperInfo = SnapshotCodeIdentity.information(at: helperURL)
        guard clientInfo?[kSecCodeInfoIdentifier as String] as? String == SnapshotServiceIdentity.clientIdentifier,
              helperInfo?[kSecCodeInfoIdentifier as String] as? String == SnapshotServiceIdentity.helperIdentifier,
              let team = SnapshotCodeIdentity.team(clientInfo), SnapshotCodeIdentity.team(helperInfo) == team else { return "A matching Developer ID signed app and helper are required. This development build cannot enable privileged snapshot operations." }
        let entitlements = helperInfo?[kSecCodeInfoEntitlementsDict as String] as? [String: Any]
        guard entitlements?["com.apple.developer.vfs.snapshot"] as? Bool == true else { return "The helper lacks Apple's snapshot entitlement. Creation, deletion, scheduling and mounting remain unavailable; administrator access alone is insufficient." }
        return nil
    }
    @discardableResult
    func loadTimeMachineHistory() -> Task<Void, Never>? {
        guard !tmBusy else { return nil }
        guard !isQA else {
            tmActivities = []
            tmError = nil
            tmNeedsAcknowledgement = false
            return nil
        }
        tmBusy = true
        tmError = nil
        let history = timeMachineHistory
        return Task { [weak self] in
            do {
                let activities = try await Task.detached(priority: .utility) {
                    try history.load()
                }.value
                guard let self else { return }
                self.tmActivities = activities.sorted { $0.startedAt > $1.startedAt }
            } catch {
                self?.tmError = Self.timeMachineErrorDescription(error)
            }
            self?.tmBusy = false
        }
    }
    @discardableResult
    func requestTimeMachineSnapshot(acknowledgeUncertain: Bool = false) -> Task<Void, Never>? {
        guard !tmBusy else { return nil }
        guard !isQA else {
            tmError = "Time Machine snapshot requests are disabled in read-only QA sessions."
            return nil
        }
        tmBusy = true
        tmError = nil
        tmNeedsAcknowledgement = false
        let history = timeMachineHistory
        return Task { [weak self] in
            do {
                let activities = try await Task.detached(priority: .userInitiated) {
                    _ = try history.create(acknowledgeUncertain: acknowledgeUncertain)
                    return try history.load()
                }.value
                guard let self else { return }
                self.tmActivities = activities.sorted { $0.startedAt > $1.startedAt }
            } catch let error as TimeMachineSnapshotHistoryError where error == .acknowledgementRequired {
                let activities = try? await Task.detached(priority: .utility) {
                    try history.load()
                }.value
                guard let self else { return }
                if let activities {
                    self.tmActivities = activities.sorted { $0.startedAt > $1.startedAt }
                }
                self.tmNeedsAcknowledgement = true
                self.tmError = error.errorDescription
            } catch {
                let activities = try? await Task.detached(priority: .utility) { try history.load() }.value
                if let activities { self?.tmActivities = activities.sorted { $0.startedAt > $1.startedAt } }
                self?.tmError = Self.timeMachineErrorDescription(error)
            }
            self?.tmBusy = false
        }
    }
    private static func timeMachineErrorDescription(_ error: Error) -> String {
        if let historyError = error as? TimeMachineSnapshotHistoryError {
            return historyError.errorDescription ?? String(describing: historyError)
        }
        return error.localizedDescription
    }
    func reload() {
        guard !busy else { return }
        busy = true; error = nil
        loading = Task {
            defer { busy = false }
            if isQA, let index = CommandLine.arguments.firstIndex(of: "--snapshot-management-fixture"), CommandLine.arguments.count > index+1 {
                let input = CommandLine.arguments[index+1]
                let resolved = realpath(input, nil)
                let path = resolved.map { String(cString: $0) } ?? ""
                if let resolved { free(resolved) }
                let bytes = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.intValue ?? Int.max
                if path.hasPrefix("/private/tmp/"), bytes < 1024*1024, let data = try? Data(contentsOf: URL(fileURLWithPath: path)), data.count < 1024*1024, let fixture = try? JSONDecoder().decode(SnapshotServiceResponse.self, from: data) {
                    response = fixture; serviceStatus = "Synthetic snapshot-management QA fixture — mutations disabled."; chooseVolume(); return
                }
            }
            if let issue = compatibility() { serviceStatus = issue; available = false }
            else { available = SMAppService.daemon(plistName: SnapshotServiceIdentity.label + ".plist").status == .enabled; serviceStatus = available ? "Authorized snapshot helper enabled. Schedules run independently of this window." : "Snapshot helper is off or awaiting approval in Login Items. Automatic snapshots are off until a volume policy is enabled." }
            if available {
                let value = await rpc(.init(action: .inventory), authorization: Data())
                if let problem = value.error { error = problem; available = false } else { response = value; chooseVolume(); return }
            }
            do {
                let value = try await Task.detached(priority: .utility) { () throws -> SnapshotServiceResponse in
                    var result = SnapshotServiceResponse()
                    result.volumes = try SnapshotPlatformInventory.volumes()
                    for volume in result.volumes where volume.roles.isEmpty {
                        do { result.inventories[volume.id] = try SnapshotPlatformInventory.inventory(volume) }
                        catch { result.inventoryErrors[volume.id] = String(describing: error) }
                    }
                    return result
                }.value
                response = value; chooseVolume()
            } catch { self.error = error.localizedDescription }
        }
    }
    private func chooseVolume() {
        if !response.volumes.contains(where: { $0.id == volumeID }) { volumeID = response.volumes.first(where: { $0.compatibilityIssue == nil })?.id ?? response.volumes.first?.id ?? "" }
        selected = selected.intersection(Set(inventory.map(\.id)))
    }
    func enableService() {
        if let issue = compatibility() { error = issue; return }
        do {
            try SMAppService.daemon(plistName: SnapshotServiceIdentity.label + ".plist").register()
            message = "Helper registration requested. Approve Storage Monitor in System Settings → General → Login Items if macOS requests it. Volume schedules remain off."
        } catch { self.error = error.localizedDescription }
        reload()
    }
    func disableService() {
        guard !isQA else { return }
        Task {
            do {
                try await SMAppService.daemon(plistName: SnapshotServiceIdentity.label + ".plist").unregister()
                connection?.invalidate(); connection = nil; available = false
                message = "Snapshot helper disabled. Managed snapshots and ownership history remain intact."
            } catch { self.error = error.localizedDescription }
            reload()
        }
    }
    private func rpc(_ request: SnapshotServiceRequest, authorization: Data) async -> SnapshotServiceResponse {
        guard let team = SnapshotCodeIdentity.team(SnapshotCodeIdentity.information()) else { return .init(error: "No trusted signing team.") }
        if connection == nil {
            let value = NSXPCConnection(machServiceName: SnapshotServiceIdentity.label, options: .privileged)
            value.setCodeSigningRequirement(SnapshotCodeIdentity.requirement(identifier: SnapshotServiceIdentity.helperIdentifier, team: team))
            value.remoteObjectInterface = NSXPCInterface(with: SnapshotServiceProtocol.self)
            value.invalidationHandler = { [weak self, weak value] in
                Task { @MainActor in if self?.connection === value { self?.connection = nil } }
            }
            value.resume(); connection = value
        }
        guard let connection, let encoded = try? JSONEncoder().encode(request) else { return .init(error: "Cannot encode snapshot request.") }
        return await withCheckedContinuation { continuation in
            let gate = SnapshotReplyGate(continuation)
            let proxy = connection.remoteObjectProxyWithErrorHandler { error in gate.finish(.init(error: error.localizedDescription)) } as? SnapshotServiceProtocol
            proxy?.perform(encoded, authorization: authorization) { data in
                guard data.count <= 16*1024*1024, let response = try? JSONDecoder().decode(SnapshotServiceResponse.self, from: data) else { gate.finish(.init(error: "Invalid snapshot helper response.")); return }
                gate.finish(response)
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 60) { gate.finish(.init(error: "Snapshot helper did not reply. The operation may be interrupted or still running; reload and review activity before retrying.")) }
        }
    }
    func perform(_ request: SnapshotServiceRequest, completion: ((SnapshotServiceResponse) -> Void)? = nil) {
        guard !busy && available && !isQA else { error = "An authorized snapshot helper is required. QA sessions cannot mutate snapshots."; return }
        busy = true; error = nil
        Task {
            do {
                var authorization = try await Task.detached(priority: .userInitiated) { try SnapshotAuthorization.externalForm(for: request.action) }.value
                let value = await rpc(request, authorization: authorization)
                authorization.resetBytes(in: authorization.startIndex..<authorization.endIndex)
                busy = false
                if let problem = value.error { error = problem; return }
                response.records = value.records; response.policies = value.policies; response.activities = value.activities
                message = value.message ?? "Snapshot operation completed."
                NSAccessibility.post(element: NSApp.mainWindow as Any, notification: .announcementRequested, userInfo: [.announcement: message, .priority: NSAccessibilityPriorityLevel.high.rawValue])
                completion?(value)
                if value.preview == nil && value.lease == nil { reload() }
            } catch { busy = false; self.error = error.localizedDescription }
        }
    }
    func compareSelected() {
        let ids = selectedRecords.map(\.id)
        perform(.init(action: .beginComparison, volumeUUID: volumeID, snapshotIDs: ids)) { [weak self] value in
            guard let self, let lease = value.lease else { return }
            self.busy = true
            Task {
                do {
                    var result = try await Task.detached(priority: .utility) {
                        try SnapshotFileComparison.compare(left: URL(fileURLWithPath: lease.leftPath), right: URL(fileURLWithPath: lease.rightPath), requireReadOnlySnapshots: true)
                    }.value
                    result.sourceVolumeUUID = lease.volumeUUID
                    result.leftSnapshotUUID = value.records.first { $0.id == lease.leftSnapshotID }?.snapshotUUID
                    result.rightSnapshotUUID = value.records.first { $0.id == lease.rightSnapshotID }?.snapshotUUID
                    self.comparison = result; self.message = "Comparison finished: \(result.changes.count) reported changes. \(result.metadataCoverageComplete ? "Metadata scan completed within its limits." : "Coverage is incomplete; unverified paths are labeled.")"
                } catch { self.error = error.localizedDescription }
                self.busy = false
                self.perform(.init(action: .endComparison, token: lease.id))
            }
        }
    }
    func exportComparison() {
        guard let comparison else { return }
        let panel = NSSavePanel(); panel.allowedContentTypes = [.json]; panel.nameFieldStringValue = "Snapshot Comparison.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; try encoder.encode(comparison).write(to: url, options: .atomic); message = "Comparison exported." }
        catch { self.error = error.localizedDescription }
    }
}
