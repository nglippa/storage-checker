import Foundation
import Darwin

struct ExternalDiscoveryCommandResult: Sendable {
    let data: Data
    let status: Int32
    let timedOut: Bool
    let truncated: Bool
}

typealias ExternalDiscoveryCommandRunner = (_ executable: String, _ arguments: [String], _ timeout: TimeInterval, _ cap: Int) -> ExternalDiscoveryCommandResult

struct ExternalMountedVolumeMetadata: Sendable {
    let url: URL
    let name: String
    let volumeUUID: String?
    let isLocal: Bool
    let isInternal: Bool
    let isReadable: Bool
    let device: Int64
    var mountIdentity: ExternalMountIdentity? = nil
}

private struct APFSDiscoveryContainer {
    let uuid: String
    let stores: [String]
    let volumeRoles: [String: [String]]
}

struct ExternalVolumeDiscovery {
    private static let candidateLimit = 32
    private let commandRunner: ExternalDiscoveryCommandRunner
    private let mountedVolumes: () -> [ExternalMountedVolumeMetadata]

    init(commandRunner: @escaping ExternalDiscoveryCommandRunner, mountedVolumes: @escaping () -> [ExternalMountedVolumeMetadata]) {
        self.commandRunner = commandRunner
        self.mountedVolumes = mountedVolumes
    }

    static func discover() -> ExternalVolumeObservations {
        ExternalVolumeDiscovery(commandRunner: boundedCommand, mountedVolumes: mountedMetadata).sample()
    }

    func sample() -> ExternalVolumeObservations {
        let sampledAt = Date()
        let sampledUptime = ProcessInfo.processInfo.systemUptime
        // Known internal mounts cannot consume the bounded external-candidate budget. Unknown
        // metadata is retained and fails closed during verification below.
        let allMounted = mountedVolumes()
        let identities = Dictionary(grouping: allMounted.compactMap { $0.volumeUUID.flatMap { try? ExternalVolumeIdentity($0).uuid } }, by: { $0 })
        let mounted = allMounted.filter { !$0.isInternal }
        let limited = Array(mounted.prefix(Self.candidateLimit))
        var globalErrors = [String]()
        if mounted.count > Self.candidateLimit { globalErrors.append("candidate_limit_exceeded") }

        let apfsResult = commandRunner("/usr/sbin/diskutil", ["apfs", "list", "-plist"], 5, 1_048_576)
        let tmResult = commandRunner("/usr/bin/tmutil", ["destinationinfo", "-X"], 5, 524_288)
        let containers: [String: APFSDiscoveryContainer]
        if let plist = commandPlist(apfsResult), let parsed = parseContainers(plist) { containers = parsed }
        else { containers = [:]; globalErrors.append("apfs_metadata_unavailable") }
        let backupTruth: (paths: Set<String>, uuids: Set<String>)?
        if let plist = commandPlist(tmResult) { backupTruth = backupDestinations(plist) }
        else { backupTruth = nil; globalErrors.append("backup_metadata_unavailable") }

        var infoCache = [String: [String: Any]?]()
        func info(_ target: String) -> [String: Any]? {
            guard Date().timeIntervalSince(sampledAt) < 30 else { return nil }
            if let cached = infoCache[target] { return cached }
            let value = commandPlist(commandRunner("/usr/sbin/diskutil", ["info", "-plist", target], 2, 262_144)) as? [String: Any]
            infoCache[target] = value
            return value
        }

        var descriptors = limited.map { mount -> ExternalVolumeDescriptor in
            let normalizedUUID = mount.volumeUUID.flatMap { try? ExternalVolumeIdentity($0).uuid }
            var descriptor = ExternalVolumeDescriptor(volumeUUID: normalizedUUID, name: mount.name, mountPath: mount.url.path,
                                                      filesystem: "unknown", device: mount.device, isInternal: mount.isInternal,
                                                      isLocal: mount.isLocal, isPhysical: false, isReadable: mount.isReadable)
            descriptor.mountIdentity = mount.mountIdentity
            guard let candidate = info(mount.url.path) else {
                descriptor.verificationError = "Disk metadata could not be verified."
                return descriptor
            }
            descriptor.filesystem = string(candidate, ["FilesystemType", "FilesystemName", "Type (Bundle)"])?.lowercased() ?? "unknown"
            descriptor.isInternal = descriptor.isInternal || bool(candidate["Internal"]) == true
            descriptor.isDiskImage = bool(candidate["DiskImage"]) == true
                || string(candidate, ["VirtualOrPhysical"])?.lowercased() == "virtual" && candidate["APFSContainerReference"] == nil

            guard let normalizedUUID else {
                descriptor.verificationError = "The mounted volume has no verifiable UUID."
                return descriptor
            }
            let observedUUID = string(candidate, ["VolumeUUID", "APFSVolumeUUID", "DiskUUID"]).flatMap { try? ExternalVolumeIdentity($0).uuid }
            guard observedUUID == normalizedUUID else {
                descriptor.verificationError = "Mounted and disk metadata volume identities do not match."
                return descriptor
            }

            var roles = strings(candidate["Roles"]) + strings(candidate["APFSVolumeRole"])
            if descriptor.filesystem == "apfs" {
                guard let reference = string(candidate, ["APFSContainerReference"]), let container = containers[reference] else {
                    descriptor.verificationError = "The APFS container identity could not be verified."
                    return descriptor
                }
                descriptor.containerUUID = container.uuid
                roles += container.volumeRoles[normalizedUUID] ?? []
                var backing = [String]()
                var sawInternal = false
                for store in container.stores {
                    guard let verified = verifyPhysicalBacking(store, info: info) else {
                        descriptor.verificationError = "The physical APFS backing could not be verified."
                        return descriptor
                    }
                    if let uuid = verified.uuid { backing.append(uuid) }; sawInternal = sawInternal || verified.internalDisk
                }
                guard !container.stores.isEmpty else {
                    descriptor.verificationError = "The APFS container has no verified physical backing."
                    return descriptor
                }
                descriptor.backingUUIDs = Array(Set(backing)).sorted()
                descriptor.isInternal = descriptor.isInternal || sawInternal
                descriptor.isPhysical = true
            } else if let device = string(candidate, ["DeviceIdentifier"]), let verified = verifyPhysicalBacking(device, existing: candidate, info: info) {
                descriptor.backingUUIDs = verified.uuid.map { [$0] } ?? []
                descriptor.isInternal = descriptor.isInternal || verified.internalDisk
                descriptor.isPhysical = true
            } else {
                descriptor.verificationError = "The physical backing could not be verified."
                return descriptor
            }

            let helperRoles = Set(["system", "preboot", "recovery", "vm", "update", "backup"])
            let timeMachine = backupTruth.map { $0.paths.contains(mount.url.standardizedFileURL.path) || $0.uuids.contains(normalizedUUID) }
            descriptor.isBackup = roles.map { $0.lowercased() }.contains(where: helperRoles.contains) || timeMachine == true
            if backupTruth == nil { descriptor.verificationError = "Time Machine destination metadata could not be verified." }
            if let identity = mount.mountIdentity, (try? ExternalMountProbe.read(mount.url.path)) != identity {
                descriptor.verificationError = "The mounted volume changed during metadata verification."
            }
            return descriptor
        }
        let containerIdentities = Dictionary(grouping: containers.values, by: \.uuid)
        for index in descriptors.indices {
            if descriptors[index].eligibilityReason == nil, let uuid = try? descriptors[index].identity().uuid, (identities[uuid]?.count ?? 0) > 1 {
                descriptors[index].verificationError = ExternalVolumeError.ambiguousIdentity.localizedDescription
            }
            if descriptors[index].eligibilityReason == nil, let uuid = descriptors[index].containerUUID, (containerIdentities[uuid]?.count ?? 0) > 1 {
                descriptors[index].verificationError = "Multiple APFS containers have the same UUID. Resolve this identity conflict before monitoring."
            }
        }
        return ExternalVolumeObservations(sampledAt: sampledAt, descriptors: descriptors, error: globalErrors.isEmpty ? nil : globalErrors.joined(separator: ","), sampledUptime: sampledUptime)
    }

    private static func boundedCommand(_ executable: String, _ arguments: [String], _ timeout: TimeInterval, _ cap: Int) -> ExternalDiscoveryCommandResult {
        do {
            let result = try run(executable, arguments, timeout: timeout, cap: cap)
            // completePlist enforces successful, bounded, complete plist output without logging it.
            let value = try completePlist(result)
            let data = try PropertyListSerialization.data(fromPropertyList: value, format: .binary, options: 0)
            return ExternalDiscoveryCommandResult(data: data, status: 0, timedOut: false, truncated: false)
        } catch {
            return ExternalDiscoveryCommandResult(data: Data(), status: 1, timedOut: false, truncated: false)
        }
    }

    private static func mountedMetadata() -> [ExternalMountedVolumeMetadata] {
        let keys: [URLResourceKey] = [.volumeNameKey, .volumeUUIDStringKey, .volumeIsLocalKey, .volumeIsInternalKey]
        return (FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: []) ?? []).map { url in
            let values = try? url.resourceValues(forKeys: Set(keys))
            var info = stat(); let hasStat = lstat(url.path, &info) == 0
            return ExternalMountedVolumeMetadata(url: url, name: values?.volumeName ?? url.lastPathComponent,
                                                 volumeUUID: values?.volumeUUIDString, isLocal: values?.volumeIsLocal ?? false,
                                                 isInternal: values?.volumeIsInternal ?? false,
                                                 isReadable: access(url.path, R_OK) == 0,
                                                 device: hasStat ? Int64(info.st_dev) : -1,
                                                 mountIdentity: try? ExternalMountProbe.read(url.path))
        }
    }

    private func commandPlist(_ result: ExternalDiscoveryCommandResult) -> Any? {
        guard result.status == 0, !result.timedOut, !result.truncated, !result.data.isEmpty,
              result.data.count <= 1_048_576 else { return nil }
        return try? PropertyListSerialization.propertyList(from: result.data, options: [], format: nil)
    }

    private func parseContainers(_ value: Any) -> [String: APFSDiscoveryContainer]? {
        guard let root = value as? [String: Any], let raw = root["Containers"] as? [[String: Any]] else { return nil }
        var result = [String: APFSDiscoveryContainer]()
        for item in raw {
            guard let reference = string(item, ["APFSContainerReference", "ContainerReference"]),
                  let rawUUID = string(item, ["APFSContainerUUID"]),
                  let uuid = try? ExternalVolumeIdentity(rawUUID).uuid else { continue }
            let stores = (item["PhysicalStores"] as? [[String: Any]] ?? []).compactMap { string($0, ["APFSPhysicalStore", "DeviceIdentifier"]) }
            var volumeRoles = [String: [String]]()
            for volume in item["Volumes"] as? [[String: Any]] ?? [] {
                if let rawVolume = string(volume, ["APFSVolumeUUID", "VolumeUUID"]), let volumeUUID = try? ExternalVolumeIdentity(rawVolume).uuid {
                    volumeRoles[volumeUUID] = strings(volume["Roles"])
                }
            }
            result[reference] = APFSDiscoveryContainer(uuid: uuid, stores: stores, volumeRoles: volumeRoles)
        }
        return result
    }

    private func backupDestinations(_ value: Any) -> (paths: Set<String>, uuids: Set<String>) {
        var paths = Set<String>(), uuids = Set<String>()
        func visit(_ value: Any, key: String = "") {
            if let values = value as? [String: Any] { for (childKey, child) in values { visit(child, key: childKey.lowercased()) } }
            else if let values = value as? [Any] { for child in values { visit(child, key: key) } }
            else if let text = value as? String {
                if let uuid = try? ExternalVolumeIdentity(text).uuid { uuids.insert(uuid) }
                if key.contains("mount") {
                    let path = URL(fileURLWithPath: text).standardizedFileURL.path
                    if path.hasPrefix("/") { paths.insert(path) }
                } else if key.contains("url"), let url = URL(string: text), url.isFileURL { paths.insert(url.standardizedFileURL.path) }
            }
        }
        visit(value)
        return (paths, uuids)
    }

    private func verifyPhysicalBacking(_ device: String, existing: [String: Any]? = nil,
                                       info: (String) -> [String: Any]?) -> (uuid: String?, internalDisk: Bool)? {
        guard let partition = existing ?? info(device), string(partition, ["DeviceIdentifier"]) == device,
              string(partition, ["VirtualOrPhysical"])?.lowercased() != "virtual",
              bool(partition["PartitionMapPartition"]) == true || string(partition, ["VirtualOrPhysical"])?.lowercased() == "physical",
              bool(partition["DiskImage"]) != true,
              let parent = string(partition, ["ParentWholeDisk"]), let whole = info(parent),
              string(whole, ["DeviceIdentifier"]) == parent, bool(whole["WholeDisk"] ?? whole["Whole"]) == true,
              string(whole, ["VirtualOrPhysical"])?.lowercased() == "physical", bool(whole["DiskImage"]) != true,
              let partitionInternal = bool(partition["Internal"]), let wholeInternal = bool(whole["Internal"]),
              partitionInternal == wholeInternal else { return nil }
        let uuid: String?
        if let raw = string(partition, ["DiskUUID"]) {
            guard let canonical = try? ExternalVolumeIdentity(raw).uuid else { return nil }
            uuid = canonical
        } else { uuid = nil } // Some MBR/whole-filesystem disks expose only a persistent filesystem UUID.
        return (uuid, wholeInternal)
    }

    private func string(_ values: [String: Any], _ keys: [String]) -> String? {
        keys.lazy.compactMap { values[$0] as? String }.first
    }
    private func strings(_ value: Any?) -> [String] {
        if let values = value as? [String] { return values }
        if let value = value as? String { return [value] }
        return []
    }
    private func bool(_ value: Any?) -> Bool? { (value as? NSNumber)?.boolValue }
}
