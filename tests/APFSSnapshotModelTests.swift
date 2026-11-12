import Foundation

@main
struct APFSSnapshotModelTests {
    private static let volumeA = "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA"
    private static let volumeB = "BBBBBBBB-BBBB-4BBB-8BBB-BBBBBBBBBBBB"
    private static let snapshotA = "11111111-1111-4111-8111-111111111111"
    private static let snapshotB = "22222222-2222-4222-8222-222222222222"

    static func main() throws {
        try testDiskutilParsing()
        try testMalformedAndDuplicatePayloads()
        testAppearanceAndDisappearance()
        testCaseInsensitiveIdentityAndBaseline()
        testFailureDisconnectAndContinuityBreak()
        testVolumeScopedChangeIdentity()
        try testObservationRoundTripAndUnknowns()
        try testCorruptObservationRejection()
        print("APFS snapshot model tests passed")
    }

    private static func testDiskutilParsing() throws {
        let empty = try SnapshotInventory.parseDiskutil(
            plist(["Snapshots": []]),
            volumeUUID: volumeA,
            volumeName: "Data",
            observedAt: 100
        )
        expect(empty.status == .complete && empty.snapshots.isEmpty, "explicit empty list is complete")

        let parsed = try SnapshotInventory.parseDiskutil(
            plist(["Snapshots": [[
                "SnapshotUUID": snapshotA,
                "SnapshotName": "com.apple.TimeMachine.fixture",
                "SnapshotXID": NSNumber(value: UInt64(42)),
                "Purgeable": true,
                "CreationDate": Date(timeIntervalSince1970: 1),
                "PrivateSize": 999
            ]]]),
            volumeUUID: volumeA,
            volumeName: "Data",
            observedAt: 100
        )
        expect(parsed.snapshots.count == 1, "one snapshot parsed")
        let record = parsed.snapshots[0]
        expect(record.xid == 42 && record.purgeable == true, "documented optional values parsed")
        expect(record.createdAt == nil && record.creationSource == nil && record.privateBytes == nil,
               "undocumented fields do not invent measurements")
    }

    private static func testMalformedAndDuplicatePayloads() throws {
        expectThrows("malformed bytes rejected") {
            _ = try SnapshotInventory.parseDiskutil(Data("not a plist".utf8), volumeUUID: volumeA, volumeName: "Data", observedAt: 1)
        }
        expectThrows("missing Snapshots rejected") {
            _ = try SnapshotInventory.parseDiskutil(plist([:]), volumeUUID: volumeA, volumeName: "Data", observedAt: 1)
        }
        expectThrows("diskutil error payload rejected even with Snapshots") {
            _ = try SnapshotInventory.parseDiskutil(plist(["Error": "fixture failure", "Snapshots": []]), volumeUUID: volumeA, volumeName: "Data", observedAt: 1)
        }
        expectThrows("diskutil error code payload rejected even with Snapshots") {
            _ = try SnapshotInventory.parseDiskutil(plist(["errorCode": 1, "Snapshots": []]), volumeUUID: volumeA, volumeName: "Data", observedAt: 1)
        }
        expectThrows("partial snapshot rejected") {
            _ = try SnapshotInventory.parseDiskutil(plist(["Snapshots": [["SnapshotUUID": snapshotA]]]), volumeUUID: volumeA, volumeName: "Data", observedAt: 1)
        }
        expectThrows("invalid UUID rejected") {
            _ = try SnapshotInventory.parseDiskutil(plist(["Snapshots": [["SnapshotUUID": "bad", "SnapshotName": "x"]]]), volumeUUID: volumeA, volumeName: "Data", observedAt: 1)
        }
        expectThrows("case-insensitive duplicate UUID rejected") {
            _ = try SnapshotInventory.parseDiskutil(plist(["Snapshots": [
                ["SnapshotUUID": snapshotA, "SnapshotName": "one"],
                ["SnapshotUUID": snapshotA.lowercased(), "SnapshotName": "two"]
            ]]), volumeUUID: volumeA, volumeName: "Data", observedAt: 1)
        }
        expectThrows("zero XID rejected") {
            _ = try SnapshotInventory.parseDiskutil(plist(["Snapshots": [["SnapshotUUID": snapshotA, "SnapshotName": "x", "SnapshotXID": 0]]]), volumeUUID: volumeA, volumeName: "Data", observedAt: 1)
        }
        expectThrows("non-boolean purgeability rejected") {
            _ = try SnapshotInventory.parseDiskutil(plist(["Snapshots": [["SnapshotUUID": snapshotA, "SnapshotName": "x", "Purgeable": 1]]]), volumeUUID: volumeA, volumeName: "Data", observedAt: 1)
        }
    }

    private static func testAppearanceAndDisappearance() {
        let previous = inventory(volumeA, snapshots: [record(snapshotA)], observedAt: 1)
        let current = inventory(volumeA, snapshots: [record(snapshotB)])
        let result = SnapshotComparison.compare(previous: [previous], current: [current], continuous: true)
        expect(result.comparedVolumes == 1, "complete pair compared")
        expect(result.changes.map(\.kind) == [.appeared, .disappeared], "appearance and disappearance reported")
        expect(result.changes[0].snapshot.uuid == snapshotB && result.changes[1].snapshot.uuid == snapshotA,
               "change records retain observed snapshots")
    }

    private static func testCaseInsensitiveIdentityAndBaseline() {
        let previous = inventory(volumeA, snapshots: [record(snapshotA)], observedAt: 1)
        let current = inventory(volumeA.lowercased(), snapshots: [record(snapshotA.lowercased())])
        let same = SnapshotComparison.compare(previous: [previous], current: [current], continuous: true)
        expect(same.comparedVolumes == 1 && same.changes.isEmpty, "UUID identity is case insensitive")

        let baseline = SnapshotComparison.compare(previous: nil, current: [current], continuous: true)
        expect(baseline.changes.isEmpty && baseline.comparedVolumes == 0 && !baseline.limitations.isEmpty,
               "first observation is baseline")
    }

    private static func testFailureDisconnectAndContinuityBreak() {
        let prior = inventory(volumeA, snapshots: [record(snapshotA)], observedAt: 1)
        let failed = SnapshotInventory(volumeUUID: volumeA, volumeName: "Data", observedAt: 2,
                                       status: .unavailable, detail: "fixture failure", snapshots: [])
        let failure = SnapshotComparison.compare(previous: [prior], current: [failed], continuous: true)
        expect(failure.changes.isEmpty && failure.comparedVolumes == 0 && !failure.limitations.isEmpty,
               "failed inventory cannot imply disappearance")

        let disconnected = SnapshotComparison.compare(previous: [prior], current: [], continuous: true)
        expect(disconnected.changes.isEmpty && disconnected.comparedVolumes == 0 && !disconnected.limitations.isEmpty,
               "missing volume cannot imply disappearance")

        let reconnected = SnapshotComparison.compare(previous: [], current: [prior], continuous: true)
        expect(reconnected.changes.isEmpty && reconnected.comparedVolumes == 0 && !reconnected.limitations.isEmpty,
               "reconnected volume is a baseline")

        let broken = SnapshotComparison.compare(previous: [prior], current: [inventory(volumeA, snapshots: [])], continuous: false)
        expect(broken.changes.isEmpty && broken.comparedVolumes == 0 && !broken.limitations.isEmpty,
               "continuity break suppresses differences")
    }

    private static func testVolumeScopedChangeIdentity() {
        let current = [
            inventory(volumeA, name: "Data A", snapshots: [record(snapshotA)]),
            inventory(volumeB, name: "Data B", snapshots: [record(snapshotA)])
        ]
        let result = SnapshotComparison.compare(
            previous: [inventory(volumeA, snapshots: [], observedAt: 1), inventory(volumeB, snapshots: [], observedAt: 1)],
            current: current,
            continuous: true
        )
        expect(result.changes.count == 2, "same snapshot UUID on two volumes yields two observations")
        expect(Set(result.changes.map(\.id)).count == 2, "change identity includes volume")
    }

    private static func testObservationRoundTripAndUnknowns() throws {
        let unknown = APFSSnapshotRecord(uuid: snapshotA, name: "fixture", xid: nil)
        let observation = StorageObservation(
            container: "disk3",
            observedAt: 100,
            finishedAt: 101,
            inventories: [inventory(volumeA, snapshots: [unknown], observedAt: 100)],
            capacities: [VolumeCapacityObservation(
                volumeUUID: volumeA,
                path: "/System/Volumes/Data",
                observedAt: 100,
                availableBytes: nil,
                importantAvailableBytes: 200,
                opportunisticAvailableBytes: nil,
                detail: "fixture"
            )],
            swapAllocatedBytes: nil,
            swapUsedBytes: nil,
            vmCounters: nil,
            detail: "fixture"
        )
        let decoded = StorageObservation.decode(try observation.encoded())
        expect(decoded == observation, "version 1 observation round trips")
        expect(decoded?.inventories[0].snapshots[0].privateBytes == nil && decoded?.capacities[0].availableBytes == nil,
               "unknown metrics remain nil")

        for time in [99.0, 102.0] {
            let staleInventory = StorageObservation(
                container: "disk3", observedAt: 100, finishedAt: 101,
                inventories: [inventory(volumeA, snapshots: [unknown], observedAt: time)],
                capacities: [], swapAllocatedBytes: nil, swapUsedBytes: nil, vmCounters: nil, detail: "fixture")
            let inventoryJSON = try staleInventory.encoded()
            expect(StorageObservation.decode(inventoryJSON) == nil,
                   "snapshot inventory outside collection window rejected (\(time))")
            let staleCapacity = StorageObservation(
                container: "disk3", observedAt: 100, finishedAt: 101, inventories: [],
                capacities: [VolumeCapacityObservation(volumeUUID: volumeA, path: "/fixture", observedAt: time,
                    availableBytes: 200, importantAvailableBytes: nil, opportunisticAvailableBytes: nil, detail: "fixture")],
                swapAllocatedBytes: nil, swapUsedBytes: nil, vmCounters: nil, detail: "fixture")
            let capacityJSON = try staleCapacity.encoded()
            expect(StorageObservation.decode(capacityJSON) == nil,
                   "capacity observation outside collection window rejected (\(time))")
        }
    }

    private static func testCorruptObservationRejection() throws {
        var wrongVersion = StorageObservation(
            container: "disk3", observedAt: 1, finishedAt: 2,
            inventories: [], capacities: [], swapAllocatedBytes: nil, swapUsedBytes: nil,
            vmCounters: nil, detail: ""
        )
        wrongVersion.schemaVersion = 2
        let wrongVersionJSON = try wrongVersion.encoded()
        expect(StorageObservation.decode(wrongVersionJSON) == nil, "unknown schema rejected")
        expect(StorageObservation.decode("{broken") == nil, "corrupt JSON rejected")

        let duplicates = StorageObservation(
            container: "disk3", observedAt: 1, finishedAt: 2,
            inventories: [inventory(volumeA, snapshots: []), inventory(volumeA.lowercased(), snapshots: [])],
            capacities: [], swapAllocatedBytes: nil, swapUsedBytes: nil, vmCounters: nil, detail: ""
        )
        let duplicatesJSON = try duplicates.encoded()
        expect(StorageObservation.decode(duplicatesJSON) == nil, "duplicate volume UUID rejected")

        let negativeCapacity = StorageObservation(
            container: "disk3", observedAt: 1, finishedAt: 2, inventories: [],
            capacities: [VolumeCapacityObservation(volumeUUID: volumeA, path: "/", observedAt: 1,
                availableBytes: -1, importantAvailableBytes: nil, opportunisticAvailableBytes: nil, detail: "")],
            swapAllocatedBytes: nil, swapUsedBytes: nil, vmCounters: nil, detail: ""
        )
        let negativeCapacityJSON = try negativeCapacity.encoded()
        expect(StorageObservation.decode(negativeCapacityJSON) == nil, "negative capacity rejected")
    }

    private static func inventory(
        _ uuid: String,
        name: String = "Data",
        snapshots: [APFSSnapshotRecord],
        observedAt: Double = 2
    ) -> SnapshotInventory {
        SnapshotInventory(volumeUUID: uuid, volumeName: name, observedAt: observedAt,
                          status: .complete, detail: "", snapshots: snapshots)
    }

    private static func record(_ uuid: String) -> APFSSnapshotRecord {
        APFSSnapshotRecord(uuid: uuid, name: "snapshot-\(uuid.prefix(4))", xid: nil)
    }

    private static func plist(_ value: [String: Any]) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: value, format: .xml, options: 0)
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else {
            fputs("FAIL: \(message)\n", stderr)
            exit(1)
        }
    }

    private static func expectThrows(_ message: String, _ operation: () throws -> Void) {
        do {
            try operation()
            fputs("FAIL: \(message)\n", stderr)
            exit(1)
        } catch {
            // Expected.
        }
    }
}
