import Foundation
import Darwin
import Security

@main struct SnapshotManagementTests {
    static func main() throws {
        var requirement: SecRequirement?
        let expression = SnapshotCodeIdentity.requirement(identifier: SnapshotServiceIdentity.clientIdentifier, team: "ABCDE12345")
        precondition(SecRequirementCreateWithString(expression as CFString, [], &requirement) == errSecSuccess, "XPC signing requirement must parse before it is passed to Foundation")
        let volume = ManagedVolume(id: UUID().uuidString, container: UUID().uuidString, name: "Disposable", mountPath: "/Volumes/Fixture", device: "disk99s1", roles: [], writable: true, local: true)
        let now = Date(timeIntervalSince1970: 2_000_000)
        var policy = SnapshotPolicy()
        precondition(!policy.enabled, "schedules default off")
        policy.enabled = true; policy.interval = .hourly; policy.maximumCount = 2; policy.maximumAgeDays = 7
        try policy.validate()
        precondition(policy.interval.seconds == 3600)
        precondition(SnapshotInterval.daily.seconds == 86400 && SnapshotInterval.weekly.seconds == 604800)
        var invalid = policy; invalid.customIntervalMinutes = 0; invalid.interval = .custom
        do { try invalid.validate(); fatalError("zero interval accepted") } catch {}
        let a = ManagedSnapshot(volume: volume, domain: UUID().uuidString, name: "old", snapshotUUID: UUID().uuidString, xid: 12, createdAt: now.addingTimeInterval(-9*86400), owner: 501)
        var b = ManagedSnapshot(volume: volume, domain: a.domain, name: "protected", snapshotUUID: UUID().uuidString, xid: 13, createdAt: now.addingTimeInterval(-8*86400), owner: 501)
        b.protected = true
        let c = ManagedSnapshot(volume: volume, domain: a.domain, name: "new", snapshotUUID: UUID().uuidString, xid: 14, createdAt: now, owner: 501)
        let preview = SnapshotRetention.candidates(records: [a,b,c], volume: volume, policy: policy, now: now)
        precondition(preview.map(\.id) == [a.id], "protected snapshots are never retention candidates")
        var excluded = ManagedSnapshot(volume: volume, domain: a.domain, name: "excluded", snapshotUUID: UUID().uuidString, xid: 15, createdAt: now.addingTimeInterval(-7*86400), owner: 501)
        excluded.excludedFromRetention = true
        let eligibleOne = ManagedSnapshot(volume: volume, domain: a.domain, name: "eligible-one", snapshotUUID: UUID().uuidString, xid: 16, createdAt: now.addingTimeInterval(-6*86400), owner: 501)
        let eligibleTwo = ManagedSnapshot(volume: volume, domain: a.domain, name: "eligible-two", snapshotUUID: UUID().uuidString, xid: 17, createdAt: now.addingTimeInterval(-5*86400), owner: 501)
        var countOnly = policy; countOnly.maximumCount = 2; countOnly.maximumAgeDays = 3650
        let eligibleAroundProtected = SnapshotRetention.candidates(records: [b, excluded, eligibleOne, eligibleTwo, c], volume: volume, policy: countOnly, now: now)
        precondition(eligibleAroundProtected.map(\.id) == [eligibleOne.id, eligibleTwo.id], "protected/excluded oldest records must not consume count-retention candidate slots")
        var quarantined = a; quarantined.state = .quarantined
        precondition(SnapshotRetention.candidates(records: [quarantined,b,c], volume: volume, policy: policy, now: now).isEmpty)
        let listing = LifecycleSnapshot(id: a.snapshotUUID, name: a.name, xid: a.xid)
        try SnapshotOwnership.verify(a, against: listing, volume: volume, domain: a.domain, owner: 501)
        var renamed = listing; renamed.name = "com.apple.TimeMachine.2026"
        do { try SnapshotOwnership.verify(a, against: renamed, volume: volume, domain: a.domain, owner: 501); fatalError("identity mismatch accepted") } catch {}
        do { try SnapshotOwnership.verify(a, against: listing, volume: volume, domain: UUID().uuidString, owner: 501); fatalError("foreign domain accepted") } catch {}
        var external = volume; external.container = UUID().uuidString
        do { try SnapshotOwnership.verify(a, against: listing, volume: external, domain: a.domain, owner: 501); fatalError("replacement container accepted") } catch {}
        var system = volume; system.roles = ["System"]
        precondition(system.compatibilityIssue != nil)
        precondition(volume.compatibilityIssue == nil)
        var scheduling = VolumeSnapshotPolicy(volume: volume, owner: 501, policy: policy, nextDue: now.addingTimeInterval(-36000))
        precondition(scheduling.isDue(now: now))
        scheduling.didAttempt(at: now)
        precondition(!scheduling.isDue(now: now), "missed periods must coalesce, not replay")
        precondition(scheduling.nextDue == now.addingTimeInterval(3600))
        let temp = URL(fileURLWithPath: "/private/tmp").appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: temp.appendingPathComponent("left"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: temp.appendingPathComponent("right"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        try Data("old".utf8).write(to: temp.appendingPathComponent("left/modified"))
        try Data("new".utf8).write(to: temp.appendingPathComponent("right/modified"))
        try Data("removed".utf8).write(to: temp.appendingPathComponent("left/removed"))
        try Data("added".utf8).write(to: temp.appendingPathComponent("right/added"))
        try FileManager.default.createSymbolicLink(atPath: temp.appendingPathComponent("left/link").path, withDestinationPath: "/etc")
        try FileManager.default.createSymbolicLink(atPath: temp.appendingPathComponent("right/link").path, withDestinationPath: "/var")
        let comparison = try SnapshotFileComparison.compare(left: temp.appendingPathComponent("left"), right: temp.appendingPathComponent("right"))
        precondition(comparison.changes.contains { $0.path == "added" && $0.kind == .added })
        precondition(comparison.changes.contains { $0.path == "removed" && $0.kind == .removed })
        precondition(comparison.changes.contains { $0.path == "modified" && $0.kind == .modified })
        precondition(comparison.changes.contains { $0.path == "link" && $0.kind == .modified })
        precondition(!comparison.changes.contains { $0.path.hasPrefix("link/") }, "symlink targets must not be traversed")
        let limited = try SnapshotFileComparison.compare(left: temp.appendingPathComponent("left"), right: temp.appendingPathComponent("right"), maximumEntries: 1)
        precondition(!limited.metadataCoverageComplete, "entry limits must report incomplete coverage")
        precondition(!limited.changes.contains { $0.kind == .added || $0.kind == .removed }, "incomplete one-sided results cannot assert added/removed")
        let hashLimited = try SnapshotFileComparison.compare(left: temp.appendingPathComponent("left"), right: temp.appendingPathComponent("right"), totalHashLimit: 2)
        precondition(hashLimited.contentUnverifiedFiles > 0)
        let rootLink = temp.appendingPathComponent("rootLink")
        try FileManager.default.createSymbolicLink(at: rootLink, withDestinationURL: temp.appendingPathComponent("left"))
        do { _ = try SnapshotFileComparison.compare(left: rootLink, right: temp.appendingPathComponent("right")); fatalError("symlink comparison root accepted") } catch {}
        do { try SnapshotAuthorization.verify(Data(), action: .create); fatalError("missing authorization accepted") } catch {}
        try SnapshotAuthorization.verify(Data(), action: .inventory)
        do { try SnapshotAuthorization.verify(Data(repeating: 0, count: 32), action: .deletePreview); fatalError("invalid authorization accepted") } catch {}
        var export = comparison
        export.sourceVolumeUUID = volume.id; export.leftSnapshotUUID = a.snapshotUUID; export.rightSnapshotUUID = c.snapshotUUID
        let exported = try JSONEncoder().encode(export)
        let reloadedExport = try JSONDecoder().decode(SnapshotFileComparison.self, from: exported)
        precondition(reloadedExport.sourceVolumeUUID == volume.id && reloadedExport.leftSnapshotUUID == a.snapshotUUID && reloadedExport.changes.map(\.path) == export.changes.map(\.path), "export must retain source identities, changes and coverage limitations")
        try SnapshotLifecycleEngineTests.run()
        print("PASS scheduling, retention, ownership, compatibility and real-directory comparison contracts")
    }
}
