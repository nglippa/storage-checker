import Foundation

enum SnapshotServiceIdentity {
    static let label = "local.macbook.storage-monitor.snapshots"
    static let helperIdentifier = "local.macbook.storage-monitor.snapshot-service"
    static let clientIdentifier = "local.macbook.storage-monitor.viewer"
    static let authorizationPrefix = "local.macbook.storage-monitor.snapshots.v1"
    static func authorizationRight(for action: SnapshotServiceAction) -> String? {
        switch action {
        case .create: return authorizationPrefix + ".create"
        case .deletePreview: return authorizationPrefix + ".delete"
        case .protect, .recover, .savePolicy: return authorizationPrefix + ".configure"
        case .beginComparison: return authorizationPrefix + ".compare"
        case .inventory, .previewManual, .previewRetention, .endComparison: return nil
        }
    }
    static let stateRoot = "/Library/Application Support/Storage Monitor Snapshots"
    static let mountRoot = stateRoot + "/Mounts"
}
@objc protocol SnapshotServiceProtocol {
    func perform(_ request: Data, authorization: Data, reply: @escaping (Data) -> Void)
}
