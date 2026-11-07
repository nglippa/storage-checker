import Foundation
import Darwin

/// A slice owns one verified mount instance and one desired-settings revision.
/// Every engine barrier checks these again, without launching metadata subprocesses per batch.
final class ExternalVolumeMountLease: @unchecked Sendable {
    let descriptor: ExternalVolumeDescriptor
    let registration: ExternalVolumeRegistration
    let region: CoverageRegion
    private let registry: ExternalVolumeRegistry
    private let indexing: Bool
    private let expected: ExternalMountIdentity
    private let probe: (String) throws -> ExternalMountIdentity

    init(descriptor: ExternalVolumeDescriptor, registry: ExternalVolumeRegistry, indexing: Bool = true,
         probe: @escaping (String) throws -> ExternalMountIdentity = ExternalMountProbe.read) throws {
        if let reason = descriptor.eligibilityReason { throw ExternalVolumeError.unsupported(reason) }
        let uuid = try descriptor.identity().uuid
        guard let saved = try registry.read().volumes[uuid] else { throw InventoryRootValidationError.disabled }
        self.descriptor = descriptor; self.registry = registry; self.registration = saved
        self.indexing = indexing; self.probe = probe
        do { expected = try probe(descriptor.mountPath) }
        catch { throw InventoryRootValidationError.disconnected }
        guard let discovered = descriptor.mountIdentity, expected == discovered,
              expected.volumeUUID == uuid, expected.device == descriptor.device,
              expected.mountPath == descriptor.mountPath else { throw InventoryRootValidationError.identityChanged }
        region = CoverageRegion(mount: descriptor.mountPath, prefix: "", device: dev_t(expected.device),
            deviceIdentifier: String(expected.source.dropFirst(expected.source.hasPrefix("/dev/") ? 5 : 0)), usesFirmlinks: false)
        try validate()
    }

    func validate() throws {
        let current: ExternalVolumeRegistration
        do {
            guard let saved = try registry.read().volumes[registration.volumeUUID] else { throw InventoryRootValidationError.disabled }
            current = saved
        } catch { throw InventoryRootValidationError.disabled }
        guard current.enabled, !indexing || !current.indexingPaused,
              current.revision == registration.revision else { throw InventoryRootValidationError.disabled }
        guard current.capacityScope == (try descriptor.capacityScope()),
              current.backingUUIDs == (try descriptor.normalizedBacking()) else { throw InventoryRootValidationError.identityChanged }
        let observed: ExternalMountIdentity
        do { observed = try probe(descriptor.mountPath) }
        catch { throw InventoryRootValidationError.disconnected }
        guard observed == expected else { throw InventoryRootValidationError.identityChanged }
    }

    var validator: InventoryRootValidator { { [self] _, _ in try validate() } }
}
