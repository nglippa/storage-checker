import Foundation
import Darwin

@main struct SnapshotNativeDisposableTests {
    static func main() throws {
        if CommandLine.arguments.count == 3 && CommandLine.arguments[1] == "--offline" {
            let path = CommandLine.arguments[2]
            try lifecycleRequire(path.hasPrefix("/private/tmp/storage-snapshot-native-") && path.hasSuffix("/volume.json"), "Invalid disposable offline test record.")
            let volume = try JSONDecoder().decode(ManagedVolume.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
            let backend = NativeSnapshotBackend()
            try lifecycleRequire(try !backend.volumes().contains { $0.id == volume.id }, "Disposable volume is still connected.")
            do { _ = try backend.freeBytes(volume); fatalError("removed disposable volume accepted") } catch {}
            print("PASS actual disposable APFS image removal rejects the stale volume before an operation")
            return
        }
        guard CommandLine.arguments.count == 2 else { throw SnapshotLifecycleError.refused("Disposable mount path required.") }
        let input = CommandLine.arguments[1]
        guard let resolved = realpath(input, nil) else { throw SnapshotLifecycleError.refused("Disposable mount path is unavailable.") }
        let path = String(cString: resolved); free(resolved)
        try lifecycleRequire(path.hasPrefix("/private/tmp/storage-snapshot-native-") && path.hasSuffix("/mount"), "Refusing tests outside the disposable image mount.")
        let backend = NativeSnapshotBackend()
        let matches = try backend.volumes().filter { $0.mountPath == path }
        try lifecycleRequire(matches.count == 1 && matches[0].roles.isEmpty, "Disposable APFS image is unavailable or has an unexpected role.")
        let volume = matches[0]
        try JSONEncoder().encode(volume).write(to: URL(fileURLWithPath: path).deletingLastPathComponent().appendingPathComponent("volume.json"))
        try lifecycleRequire(volume.compatibilityIssue == nil, volume.compatibilityIssue ?? "Unsupported volume")
        let before = try backend.inventory(volume)
        try lifecycleRequire(before.isEmpty, "Fresh disposable image unexpectedly has snapshots.")
        let free = try backend.freeBytes(volume)
        try lifecycleRequire(free > 0, "Descriptor-based APFS free-capacity query failed.")
        // This development test binary is deliberately NOT granted a snapshot entitlement or root.
        // Exercise actual platform identity/capability checks and actual management permission denial.
        do {
            try backend.create(volume, name: "local.storage-monitor.\(UUID().uuidString.lowercased()).\(UUID().uuidString.lowercased()).Disposable")
            throw SnapshotLifecycleError.refused("Unexpected native mutation capability: stop and review the disposable volume.")
        } catch {
            try lifecycleRequire(geteuid() != 0 || sm_snapshot_has_entitlement() == 0, "Unexpected privileged mutation state.")
            print("PASS native creation denied without root + accepted entitlement: \(error)")
        }
        let unowned = LifecycleSnapshot(id: UUID().uuidString, name: "local.storage-monitor.unowned-test-record", xid: 1)
        do {
            try backend.delete(volume, snapshot: unowned)
            throw SnapshotLifecycleError.refused("Unexpected native deletion capability.")
        } catch {
            try lifecycleRequire(geteuid() != 0 || sm_snapshot_has_entitlement() == 0, "Unexpected privileged deletion state.")
            print("PASS native deletion denied without root + accepted entitlement")
        }
        let after = try backend.inventory(volume)
        try lifecycleRequire(after.isEmpty, "Permission-denied create changed native snapshot inventory.")
        var replaced = volume; replaced.id = UUID().uuidString
        do { _ = try backend.freeBytes(replaced); fatalError("stale volume UUID accepted") } catch {}
        var staleContainer = volume; staleContainer.container = UUID().uuidString
        do { _ = try backend.freeBytes(staleContainer); fatalError("stale container UUID accepted") } catch {}
        print("PASS disposable APFS discovery, empty native inventory, descriptor UUID/capability/free-space validation, stale volume/container rejection")
        print("NOT VERIFIED native successful create/delete/mount: accepted Apple snapshot entitlement and privileged disposable-test approval path unavailable")
    }
}
