import Foundation
import Security

/// Runtime code requirements pin both XPC endpoints; development/ad-hoc signatures are never privileged.
enum SnapshotCodeIdentity {
    static func information(at url: URL? = nil) -> [String: Any]? {
        var code: SecStaticCode?
        if let url {
            guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess else { return nil }
        } else {
            var dynamic: SecCode?
            guard SecCodeCopySelf([], &dynamic) == errSecSuccess, let dynamic,
                  SecCodeCopyStaticCode(dynamic, [], &code) == errSecSuccess else { return nil }
        }
        guard let code, SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate), nil) == errSecSuccess else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess else { return nil }
        return info as? [String: Any]
    }
    static func team(_ info: [String: Any]?) -> String? {
        guard let value = info?[kSecCodeInfoTeamIdentifier as String] as? String,
              value.range(of: "^[A-Z0-9]{10}$", options: .regularExpression) != nil else { return nil }
        return value
    }
    static func requirement(identifier: String, team: String) -> String {
        // Both inputs are fixed identifiers or a validated ten-character signing Team ID.
        "anchor apple generic and identifier \"\(identifier)\" and certificate leaf[subject.OU] = \"\(team)\" and entitlement[\"com.apple.security.get-task-allow\"] absent"
    }
}

enum SnapshotAuthorization {
    static func installRightsIfMissing() throws {
        var auth: AuthorizationRef?
        try lifecycleRequire(AuthorizationCreate(nil, nil, [], &auth) == errAuthorizationSuccess && auth != nil, "Cannot initialize service authorization rules.")
        defer { AuthorizationFree(auth!, []) }
        for suffix in ["create", "delete", "configure", "compare"] {
            let name = SnapshotServiceIdentity.authorizationPrefix + "." + suffix
            var existing: CFDictionary?
            let status = AuthorizationRightGet(name, &existing)
            if status == errAuthorizationSuccess { continue } // Preserve administrator customizations.
            try lifecycleRequire(status == errAuthorizationDenied, "Cannot inspect snapshot authorization rule.")
            let rule: [String: Any] = ["class": "user", "group": "admin", "authenticate-user": true, "shared": false, "timeout": 0, "tries": 3]
            try lifecycleRequire(AuthorizationRightSet(auth!, name, rule as CFDictionary, "Manage Storage Monitor snapshots" as CFString, nil, nil) == errAuthorizationSuccess, "Cannot establish the narrow snapshot authorization right.")
        }
    }
    static func externalForm(for action: SnapshotServiceAction) throws -> Data {
        guard let right = SnapshotServiceIdentity.authorizationRight(for: action) else { return Data() }
        var auth: AuthorizationRef?
        try lifecycleRequire(AuthorizationCreate(nil, nil, [], &auth) == errAuthorizationSuccess && auth != nil, "Cannot create snapshot authorization.")
        defer { AuthorizationFree(auth!, []) }
        let granted: Bool = right.withCString { name in
            var item = AuthorizationItem(name: name, valueLength: 0, value: nil, flags: 0)
            return withUnsafeMutablePointer(to: &item) { pointer in
                var rights = AuthorizationRights(count: 1, items: pointer), authorized: UnsafeMutablePointer<AuthorizationRights>?
                let status = AuthorizationCopyRights(auth!, &rights, nil, [.interactionAllowed, .extendRights, .preAuthorize], &authorized)
                defer { if let authorized { AuthorizationFreeItemSet(authorized) } }
                guard status == errAuthorizationSuccess, let authorized, authorized.pointee.count == 1, authorized.pointee.items != nil else { return false }
                let result = authorized.pointee.items!.pointee
                return String(cString: result.name) == right && result.flags & UInt32(kAuthorizationFlagCanNotPreAuthorize) == 0
            }
        }
        try lifecycleRequire(granted, "Snapshot authorization was cancelled or denied.")
        var external = AuthorizationExternalForm()
        try lifecycleRequire(AuthorizationMakeExternalForm(auth!, &external) == errAuthorizationSuccess, "Cannot transfer snapshot authorization.")
        defer { _ = withUnsafeMutableBytes(of: &external) { $0.initializeMemory(as: UInt8.self, repeating: 0) } }
        return withUnsafeBytes(of: external) { Data($0) }
    }
    static func verify(_ data: Data, action: SnapshotServiceAction) throws {
        guard let right = SnapshotServiceIdentity.authorizationRight(for: action) else { return }
        try lifecycleRequire(data.count == MemoryLayout<AuthorizationExternalForm>.size, "Snapshot authorization credential is missing or invalid.")
        var external = AuthorizationExternalForm()
        _ = withUnsafeMutableBytes(of: &external) { data.copyBytes(to: $0) }
        var auth: AuthorizationRef?
        let status = AuthorizationCreateFromExternalForm(&external, &auth)
        _ = withUnsafeMutableBytes(of: &external) { $0.initializeMemory(as: UInt8.self, repeating: 0) }
        try lifecycleRequire(status == errAuthorizationSuccess && auth != nil, "Snapshot authorization is invalid.")
        defer { AuthorizationFree(auth!, [.destroyRights]) }
        let verified = right.withCString { name in
            var item = AuthorizationItem(name: name, valueLength: 0, value: nil, flags: 0)
            return withUnsafeMutablePointer(to: &item) { pointer in
                var rights = AuthorizationRights(count: 1, items: pointer)
                return AuthorizationCopyRights(auth!, &rights, nil, [], nil) == errAuthorizationSuccess
            }
        }
        try lifecycleRequire(verified, "Administrator authorization was not granted for this snapshot operation.")
    }
}
