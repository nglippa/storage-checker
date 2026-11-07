import Foundation
import CryptoKit

enum ExternalVolumeError: Error, LocalizedError {
    case invalidIdentity, unsupported(String), ambiguousIdentity, changedBacking, invalidRegistry, identityCollision, unsafeStorage
    var errorDescription: String? {
        switch self {
        case .invalidIdentity: return "This volume has no usable persistent UUID."
        case .unsupported(let reason): return reason
        case .ambiguousIdentity: return "Multiple connected volumes have the same identity. Monitoring is paused until the ambiguity is resolved."
        case .changedBacking: return "The drive's backing identity changed. Explicitly re-enroll this drive before resuming."
        case .invalidRegistry: return "External-drive settings are damaged or use an unsupported version. No external work was started."
        case .identityCollision: return "The saved dataset belongs to a different storage identity."
        case .unsafeStorage: return "External-drive data must use a private internal directory without symbolic links."
        }
    }
}

struct ExternalVolumeIdentity: Codable, Hashable, Sendable {
    let uuid: String
    init(_ value: String) throws {
        guard let id = UUID(uuidString: value) else { throw ExternalVolumeError.invalidIdentity }
        uuid = id.uuidString
    }
    var key: String { Self.storageKey(uuid) }
    static func storageKey(_ value: String) -> String { SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined() }
    static func capacityScope(_ value: String) throws -> String {
        let parts = value.split(separator: ":", maxSplits: 1)
        guard parts.count == 2, ["apfs", "filesystem"].contains(String(parts[0])) else { throw ExternalVolumeError.invalidIdentity }
        return String(parts[0]) + ":" + (try ExternalVolumeIdentity(String(parts[1])).uuid)
    }
}

/// Metadata observations only. Constructing a descriptor never enumerates files on the volume.
struct ExternalVolumeDescriptor: Codable, Equatable, Sendable, Identifiable {
    var volumeUUID: String?
    var name: String
    var mountPath: String
    var filesystem: String
    var device: Int64
    var containerUUID: String? = nil
    var backingUUIDs: [String] = []
    var isInternal: Bool
    var isLocal: Bool
    var isPhysical: Bool
    var isDiskImage = false
    var isBackup = false
    var isReadable = true
    var verificationError: String? = nil
    var mountIdentity: ExternalMountIdentity? = nil
    var id: String { (try? identity().uuid) ?? "unidentified:\(mountPath)" }
    func identity() throws -> ExternalVolumeIdentity {
        guard let volumeUUID else { throw ExternalVolumeError.invalidIdentity }
        return try ExternalVolumeIdentity(volumeUUID)
    }
    var eligibilityReason: String? {
        if let verificationError { return verificationError }
        if (try? identity()) == nil { return ExternalVolumeError.invalidIdentity.localizedDescription }
        if isInternal { return "Internal storage is monitored separately." }
        if !isLocal { return "Network volumes are not supported." }
        if isDiskImage || !isPhysical { return "Disk images and synthetic volumes are not eligible." }
        if isBackup { return "Time Machine and system helper volumes are excluded." }
        if !["apfs", "hfs", "hfs+", "exfat"].contains(filesystem.lowercased()) { return "This filesystem is not supported for external monitoring." }
        if !isReadable { return "Permission is required to read this volume." }
        if filesystem.lowercased() == "apfs", containerUUID.flatMap({ try? ExternalVolumeIdentity($0) }) == nil { return "The APFS container identity could not be verified." }
        return nil
    }
    func capacityScope() throws -> String {
        if filesystem.lowercased() == "apfs" {
            guard let containerUUID else { throw ExternalVolumeError.invalidIdentity }
            return "apfs:" + (try ExternalVolumeIdentity(containerUUID).uuid)
        }
        return "filesystem:" + (try identity().uuid)
    }
    func normalizedBacking() throws -> [String] { try Set(backingUUIDs.map { try ExternalVolumeIdentity($0).uuid }).sorted() }
}

enum ExternalVolumeCatalog {
    static func resolve(uuid: String, descriptors: [ExternalVolumeDescriptor]) throws -> ExternalVolumeDescriptor? {
        let id = try ExternalVolumeIdentity(uuid)
        let matches = descriptors.filter { (try? $0.identity()) == id }
        guard matches.count <= 1 else { throw ExternalVolumeError.ambiguousIdentity }
        guard let match = matches.first else { return nil }
        if let reason = match.eligibilityReason { throw ExternalVolumeError.unsupported(reason) }
        return match
    }
}

struct ExternalVolumeRegistration: Codable, Equatable, Sendable, Identifiable {
    var volumeUUID: String
    var name: String
    var backingUUIDs: [String]
    var capacityScope: String
    var enabled: Bool
    var indexingPaused: Bool
    var revision: UInt64
    var id: String { volumeUUID }
}

struct ExternalVolumeRegistryDocument: Codable, Equatable, Sendable {
    var version = 1
    var revision: UInt64 = 0
    var volumes: [String: ExternalVolumeRegistration] = [:]
}
