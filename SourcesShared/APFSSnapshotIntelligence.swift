import Foundation

enum SnapshotInventoryStatus: String, Codable, Sendable {
    case complete
    case unavailable
    case skipped
    case unsupported
}

struct APFSSnapshotRecord: Codable, Sendable, Equatable, Identifiable {
    let uuid: String
    let name: String
    let xid: UInt64?
    var createdAt: Double? = nil
    var creationSource: String? = nil
    var purgeable: Bool? = nil
    var privateBytes: Int64? = nil

    var id: String { uuid }
}

struct SnapshotInventory: Codable, Sendable, Equatable {
    let volumeUUID: String
    let volumeName: String
    let observedAt: Double
    let status: SnapshotInventoryStatus
    let detail: String
    let snapshots: [APFSSnapshotRecord]

    private static let maximumPropertyListBytes = 512 * 1_024
    private static let maximumSnapshotCount = 4_096

    enum ParseError: Error, Equatable {
        case malformedPropertyList
        case missingSnapshots
        case unreasonableSnapshotCount
        case malformedSnapshot(Int)
        case invalidSnapshotUUID(Int)
        case emptySnapshotName(Int)
        case duplicateSnapshotUUID(String)
        case invalidSnapshotXID(Int)
        case invalidPurgeableValue(Int)
    }

    static func parseDiskutil(
        _ data: Data,
        volumeUUID: String,
        volumeName: String,
        observedAt: Double
    ) throws -> SnapshotInventory {
        guard data.count <= maximumPropertyListBytes else {
            throw ParseError.unreasonableSnapshotCount
        }
        let propertyList: Any
        do {
            propertyList = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        } catch {
            throw ParseError.malformedPropertyList
        }

        guard let dictionary = propertyList as? [String: Any] else {
            throw ParseError.malformedPropertyList
        }
        guard dictionary["Error"] == nil,
              dictionary["error"] == nil,
              dictionary["ErrorCode"] == nil,
              dictionary["errorCode"] == nil else {
            throw ParseError.malformedPropertyList
        }
        guard let rawSnapshots = dictionary["Snapshots"] else {
            throw ParseError.missingSnapshots
        }
        guard let snapshotDictionaries = rawSnapshots as? [[String: Any]] else {
            throw ParseError.malformedPropertyList
        }
        guard snapshotDictionaries.count <= maximumSnapshotCount else {
            throw ParseError.unreasonableSnapshotCount
        }

        var seenUUIDs = Set<String>()
        var records: [APFSSnapshotRecord] = []
        records.reserveCapacity(snapshotDictionaries.count)

        for (index, snapshot) in snapshotDictionaries.enumerated() {
            guard let rawUUID = snapshot["SnapshotUUID"] as? String else {
                throw ParseError.malformedSnapshot(index)
            }
            let trimmedUUID = rawUUID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard UUID(uuidString: trimmedUUID) != nil else {
                throw ParseError.invalidSnapshotUUID(index)
            }
            let identity = trimmedUUID.lowercased()
            guard seenUUIDs.insert(identity).inserted else {
                throw ParseError.duplicateSnapshotUUID(trimmedUUID)
            }

            guard let rawName = snapshot["SnapshotName"] as? String else {
                throw ParseError.malformedSnapshot(index)
            }
            let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else {
                throw ParseError.emptySnapshotName(index)
            }

            let xid: UInt64?
            if let rawXID = snapshot["SnapshotXID"] {
                guard let parsedXID = exactPositiveInteger(rawXID) else {
                    throw ParseError.invalidSnapshotXID(index)
                }
                xid = parsedXID
            } else {
                xid = nil
            }

            let purgeable: Bool?
            if let rawPurgeable = snapshot["Purgeable"] {
                guard let parsedPurgeable = exactBoolean(rawPurgeable) else {
                    throw ParseError.invalidPurgeableValue(index)
                }
                purgeable = parsedPurgeable
            } else {
                purgeable = nil
            }

            records.append(
                APFSSnapshotRecord(
                    uuid: trimmedUUID,
                    name: name,
                    xid: xid,
                    purgeable: purgeable
                )
            )
        }

        records.sort {
            ($0.uuid.lowercased(), $0.name) < ($1.uuid.lowercased(), $1.name)
        }
        return SnapshotInventory(
            volumeUUID: volumeUUID,
            volumeName: volumeName,
            observedAt: observedAt,
            status: .complete,
            detail: "",
            snapshots: records
        )
    }

    private static func exactPositiveInteger(_ value: Any) -> UInt64? {
        guard let number = value as? NSNumber else { return nil }
        let encoding = String(cString: number.objCType)
        guard ["c", "C", "s", "S", "i", "I", "l", "L", "q", "Q"].contains(encoding) else {
            return nil
        }
        // Property-list booleans are NSNumbers too, but are never valid XIDs.
        guard CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let text = number.stringValue
        guard !text.hasPrefix("-"), let result = UInt64(text), result > 0 else { return nil }
        return result
    }

    private static func exactBoolean(_ value: Any) -> Bool? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) == CFBooleanGetTypeID() else {
            return nil
        }
        return number.boolValue
    }
}

struct SnapshotChange: Sendable, Equatable, Identifiable {
    enum Kind: String, Sendable {
        case appeared
        case disappeared
    }

    let volumeUUID: String
    let volumeName: String
    let kind: Kind
    let snapshot: APFSSnapshotRecord

    var id: String {
        "\(volumeUUID.lowercased())|\(kind.rawValue)|\(snapshot.uuid.lowercased())"
    }
}

struct SnapshotComparison: Sendable, Equatable {
    let changes: [SnapshotChange]
    let limitations: [String]
    let comparedVolumes: Int

    static func compare(
        previous: [SnapshotInventory]?,
        current: [SnapshotInventory],
        continuous: Bool
    ) -> SnapshotComparison {
        guard continuous else {
            return SnapshotComparison(
                changes: [],
                limitations: ["Observation continuity was not established; current inventories are a new baseline."],
                comparedVolumes: 0
            )
        }
        guard let previous else {
            return SnapshotComparison(
                changes: [],
                limitations: ["No prior observation was available; current inventories are the baseline."],
                comparedVolumes: 0
            )
        }

        let old = inventoriesByVolume(previous)
        let new = inventoriesByVolume(current)
        let allVolumeIDs = Set(old.values.keys).union(new.values.keys).sorted()
        var changes: [SnapshotChange] = []
        var limitations = old.duplicateLimitations + new.duplicateLimitations
        var comparedVolumes = 0

        for volumeID in allVolumeIDs {
            guard !old.duplicates.contains(volumeID), !new.duplicates.contains(volumeID) else { continue }
            guard let currentInventory = new.values[volumeID] else {
                let name = old.values[volumeID]?.volumeName ?? volumeID
                limitations.append("Volume \(name) was not observed; no snapshot disappearances were inferred.")
                continue
            }
            guard let previousInventory = old.values[volumeID] else {
                limitations.append("Volume \(currentInventory.volumeName) has no continuous prior inventory; it is a new baseline.")
                continue
            }
            guard previousInventory.status == .complete, currentInventory.status == .complete else {
                limitations.append("Volume \(currentInventory.volumeName) did not have two complete inventories; no changes were inferred.")
                continue
            }
            guard previousInventory.observedAt.isFinite,
                  currentInventory.observedAt.isFinite,
                  currentInventory.observedAt > previousInventory.observedAt else {
                limitations.append("Volume \(currentInventory.volumeName) did not have increasing observation times; no changes were inferred.")
                continue
            }

            guard let previousSnapshots = snapshotsByUUID(previousInventory.snapshots),
                  let currentSnapshots = snapshotsByUUID(currentInventory.snapshots) else {
                limitations.append("Volume \(currentInventory.volumeName) contained duplicate snapshot UUIDs; it was not compared.")
                continue
            }
            comparedVolumes += 1

            for identity in currentSnapshots.keys where previousSnapshots[identity] == nil {
                if let snapshot = currentSnapshots[identity] {
                    changes.append(SnapshotChange(
                        volumeUUID: currentInventory.volumeUUID,
                        volumeName: currentInventory.volumeName,
                        kind: .appeared,
                        snapshot: snapshot
                    ))
                }
            }
            for identity in previousSnapshots.keys where currentSnapshots[identity] == nil {
                if let snapshot = previousSnapshots[identity] {
                    changes.append(SnapshotChange(
                        volumeUUID: currentInventory.volumeUUID,
                        volumeName: currentInventory.volumeName,
                        kind: .disappeared,
                        snapshot: snapshot
                    ))
                }
            }
        }

        changes.sort {
            ($0.volumeUUID.lowercased(), $0.kind.rawValue, $0.snapshot.uuid.lowercased())
                < ($1.volumeUUID.lowercased(), $1.kind.rawValue, $1.snapshot.uuid.lowercased())
        }
        limitations.sort()
        return SnapshotComparison(changes: changes, limitations: limitations, comparedVolumes: comparedVolumes)
    }

    private static func snapshotsByUUID(_ snapshots: [APFSSnapshotRecord]) -> [String: APFSSnapshotRecord]? {
        var values: [String: APFSSnapshotRecord] = [:]
        for snapshot in snapshots {
            let identity = snapshot.uuid.lowercased()
            guard values[identity] == nil else { return nil }
            values[identity] = snapshot
        }
        return values
    }

    private static func inventoriesByVolume(_ inventories: [SnapshotInventory]) -> (
        values: [String: SnapshotInventory],
        duplicates: Set<String>,
        duplicateLimitations: [String]
    ) {
        var values: [String: SnapshotInventory] = [:]
        var duplicates = Set<String>()
        for inventory in inventories {
            let identity = inventory.volumeUUID.lowercased()
            if values[identity] != nil {
                duplicates.insert(identity)
            } else {
                values[identity] = inventory
            }
        }
        let limitations = duplicates.sorted().map {
            "Volume UUID \($0) appeared more than once in an observation; it was not compared."
        }
        return (values, duplicates, limitations)
    }
}

struct VolumeCapacityObservation: Codable, Sendable, Equatable {
    let volumeUUID: String
    let path: String
    let observedAt: Double
    let availableBytes: Int64?
    let importantAvailableBytes: Int64?
    let opportunisticAvailableBytes: Int64?
    let detail: String
}

struct StorageObservation: Codable, Sendable, Equatable {
    var schemaVersion: Int = 1
    let container: String
    let observedAt: Double
    let finishedAt: Double
    let inventories: [SnapshotInventory]
    let capacities: [VolumeCapacityObservation]
    let swapAllocatedBytes: Int64?
    let swapUsedBytes: Int64?
    let vmCounters: [String: Int64]?
    let detail: String
    var bootSession: String? = nil
    var uptime: Double? = nil

    private static let maximumInventories = 32
    private static let maximumSnapshots = 4_096
    private static let maximumCapacities = 32
    private static let maximumVMCounters = 32
    private static let maximumTextLength = 1_000_000
    private static let maximumSmallTextLength = 16_384
    private static let maximumTimestamp: Double = 10_000_000_000

    func encoded() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(self)
        guard let string = String(data: data, encoding: .utf8) else {
            throw EncodingError.invalidValue(self, EncodingError.Context(
                codingPath: [],
                debugDescription: "Storage observation was not valid UTF-8 JSON."
            ))
        }
        return string
    }

    static func decode(_ string: String) -> StorageObservation? {
        guard string.utf8.count <= maximumTextLength,
              let data = string.data(using: .utf8),
              let observation = try? JSONDecoder().decode(StorageObservation.self, from: data),
              observation.isValid else {
            return nil
        }
        return observation
    }

    private var isValid: Bool {
        guard schemaVersion == 1,
              validText(container, allowEmpty: false),
              validText(detail),
              validTime(observedAt),
              validTime(finishedAt),
              finishedAt >= observedAt,
              uptime.map({ $0.isFinite && $0 >= 0 }) ?? true,
              bootSession.map({ UUID(uuidString: $0) != nil }) ?? true,
              inventories.count <= Self.maximumInventories,
              capacities.count <= Self.maximumCapacities,
              (vmCounters?.count ?? 0) <= Self.maximumVMCounters,
              nonnegative(swapAllocatedBytes),
              nonnegative(swapUsedBytes) else {
            return false
        }

        var inventoryUUIDs = Set<String>()
        var totalSnapshots = 0
        for inventory in inventories {
            guard let identity = validUUIDIdentity(inventory.volumeUUID),
                  inventoryUUIDs.insert(identity).inserted,
                  validText(inventory.volumeName),
                  validText(inventory.detail),
                    validTime(inventory.observedAt),
                    inventory.observedAt >= observedAt, inventory.observedAt <= finishedAt else {
                return false
            }
            totalSnapshots += inventory.snapshots.count
            guard totalSnapshots <= Self.maximumSnapshots else { return false }

            var snapshotUUIDs = Set<String>()
            for snapshot in inventory.snapshots {
                guard let snapshotIdentity = validUUIDIdentity(snapshot.uuid),
                      snapshotUUIDs.insert(snapshotIdentity).inserted,
                      validText(snapshot.name, allowEmpty: false),
                      snapshot.createdAt.map(validTime) ?? true,
                      snapshot.creationSource.map({ validText($0) }) ?? true,
                      nonnegative(snapshot.privateBytes) else {
                    return false
                }
            }
        }

        var capacityUUIDs = Set<String>()
        for capacity in capacities {
            guard let identity = validUUIDIdentity(capacity.volumeUUID),
                  capacityUUIDs.insert(identity).inserted,
                  validText(capacity.path, allowEmpty: false),
                  validText(capacity.detail),
                    validTime(capacity.observedAt),
                    capacity.observedAt >= observedAt, capacity.observedAt <= finishedAt,
                  nonnegative(capacity.availableBytes),
                  nonnegative(capacity.importantAvailableBytes),
                  nonnegative(capacity.opportunisticAvailableBytes) else {
                return false
            }
        }

        if let vmCounters {
            for (key, value) in vmCounters where !validText(key, allowEmpty: false) || value < 0 {
                return false
            }
        }
        return true
    }

    private func validText(_ text: String, allowEmpty: Bool = true) -> Bool {
        text.utf8.count <= Self.maximumSmallTextLength && (allowEmpty || !text.isEmpty)
    }

    private func validTime(_ value: Double) -> Bool {
        value.isFinite && value >= 0 && value <= Self.maximumTimestamp
    }

    private func validUUIDIdentity(_ value: String) -> String? {
        guard UUID(uuidString: value) != nil else { return nil }
        return value.lowercased()
    }

    private func nonnegative(_ value: Int64?) -> Bool {
        value.map { $0 >= 0 } ?? true
    }
}
