import Foundation
import Security

public enum KeychainAccessGroupResolver {
    public static let environmentKey = "CODEX_PROFILE_KEYCHAIN_ACCESS_GROUP"

    public static func configuredAccessGroup(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        if let value = environment[Self.environmentKey]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !value.isEmpty {
            return value
        }
        return self.embeddedKeychainAccessGroups().first
    }

    public static func embeddedKeychainAccessGroups() -> [String] {
        guard let task = SecTaskCreateFromSelf(nil),
              let value = SecTaskCopyValueForEntitlement(
                task,
                "keychain-access-groups" as CFString,
                nil
              ) else {
            return []
        }
        return (value as? [String]) ?? []
    }
}

public struct DataProtectionKeychainAuthVault: AuthVault {
    public let service: String
    public let accessGroup: String?

    public init(service: String = LegacyKeychainAuthVault.defaultService, accessGroup: String? = nil) {
        self.service = service
        self.accessGroup = accessGroup?.isEmpty == false ? accessGroup : nil
    }

    public func listProfileIDs() throws -> [String] {
        var result: CFTypeRef?
        let status = SecItemCopyMatching(self.listQuery() as CFDictionary, &result)

        if status == errSecItemNotFound {
            return []
        }

        guard status == errSecSuccess else {
            throw KeychainAuthVaultError.operationFailed(
                operation: "list data-protection auth blobs",
                profileID: nil,
                status: status
            )
        }

        guard let items = result as? [[String: Any]] else {
            throw KeychainAuthVaultError.unexpectedResult(operation: "list data-protection auth blobs")
        }

        let profileIDs = items.compactMap { item -> String? in
            guard let account = item[kSecAttrAccount as String] as? String, !account.isEmpty else {
                return nil
            }
            return account
        }

        return Array(Set(profileIDs)).sorted()
    }

    public func loadAuthBlob(profileID: String) throws -> Data? {
        var result: CFTypeRef?
        let status = SecItemCopyMatching(self.loadQuery(profileID: profileID) as CFDictionary, &result)

        if status == errSecItemNotFound {
            return nil
        }

        guard status == errSecSuccess else {
            throw KeychainAuthVaultError.operationFailed(
                operation: "load data-protection auth blob",
                profileID: profileID,
                status: status
            )
        }

        guard let data = result as? Data else {
            throw KeychainAuthVaultError.unexpectedResult(operation: "load data-protection auth blob")
        }

        return data
    }

    public func saveAuthBlob(_ data: Data, profileID: String) throws {
        let attributes = self.itemAttributes(data: data, profileID: profileID)
        let addStatus = SecItemAdd(attributes as CFDictionary, nil)

        if addStatus == errSecSuccess {
            return
        }

        if addStatus == errSecDuplicateItem {
            let update: [CFString: Any] = [
                kSecAttrLabel: self.label(profileID: profileID),
                kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
                kSecValueData: data,
            ]
            let updateStatus = SecItemUpdate(self.itemQuery(profileID: profileID) as CFDictionary, update as CFDictionary)
            if updateStatus == errSecSuccess {
                return
            }
            throw KeychainAuthVaultError.operationFailed(
                operation: "update data-protection auth blob",
                profileID: profileID,
                status: updateStatus
            )
        }

        throw KeychainAuthVaultError.operationFailed(
            operation: "save data-protection auth blob",
            profileID: profileID,
            status: addStatus
        )
    }

    public func deleteAuthBlob(profileID: String) throws {
        let status = SecItemDelete(self.itemQuery(profileID: profileID) as CFDictionary)

        if status == errSecSuccess || status == errSecItemNotFound {
            return
        }

        throw KeychainAuthVaultError.operationFailed(
            operation: "delete data-protection auth blob",
            profileID: profileID,
            status: status
        )
    }

    public func hasAuthBlob(profileID: String) throws -> Bool {
        var query = self.itemQuery(profileID: profileID)
        query[kSecReturnData] = kCFBooleanFalse
        query[kSecReturnAttributes] = kCFBooleanFalse
        query[kSecMatchLimit] = kSecMatchLimitOne

        let status = SecItemCopyMatching(query as CFDictionary, nil)

        if status == errSecSuccess {
            return true
        }

        if status == errSecItemNotFound {
            return false
        }

        throw KeychainAuthVaultError.operationFailed(
            operation: "check data-protection auth blob",
            profileID: profileID,
            status: status
        )
    }

    public func diagnostics() -> AuthVaultDiagnostics {
        AuthVaultDiagnostics(activeBackend: .dataProtectionShared, accessGroup: self.accessGroup)
    }

    public func probe() -> DataProtectionProbeResult {
        let profileID = "__codex_profile_switcher_probe_\(UUID().uuidString)"
        let data = Data("probe-\(UUID().uuidString)".utf8)

        do {
            try self.saveAuthBlob(data, profileID: profileID)
            guard try self.loadAuthBlob(profileID: profileID) == data else {
                try? self.deleteAuthBlob(profileID: profileID)
                return .failed("readback mismatch")
            }
            try self.deleteAuthBlob(profileID: profileID)
            return .succeeded
        } catch {
            try? self.deleteAuthBlob(profileID: profileID)
            return .failed(error.localizedDescription)
        }
    }

    private func listQuery() -> [CFString: Any] {
        var query = self.baseServiceQuery()
        query[kSecReturnAttributes] = kCFBooleanTrue
        query[kSecMatchLimit] = kSecMatchLimitAll
        return query
    }

    private func loadQuery(profileID: String) -> [CFString: Any] {
        var query = self.itemQuery(profileID: profileID)
        query[kSecReturnData] = kCFBooleanTrue
        query[kSecMatchLimit] = kSecMatchLimitOne
        return query
    }

    private func baseServiceQuery() -> [CFString: Any] {
        var query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: self.service,
            kSecAttrSynchronizable: kCFBooleanFalse as Any,
            kSecUseDataProtectionKeychain: kCFBooleanTrue as Any,
        ]
        if let accessGroup {
            query[kSecAttrAccessGroup] = accessGroup
        }
        return query
    }

    private func itemQuery(profileID: String) -> [CFString: Any] {
        var query = self.baseServiceQuery()
        query[kSecAttrAccount] = profileID
        return query
    }

    private func itemAttributes(data: Data, profileID: String) -> [CFString: Any] {
        var attributes = self.itemQuery(profileID: profileID)
        attributes[kSecAttrLabel] = self.label(profileID: profileID)
        attributes[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        attributes[kSecValueData] = data
        return attributes
    }

    private func label(profileID: String) -> String {
        "Codex Profile Switcher: \(profileID)"
    }
}

public enum DataProtectionProbeResult: Equatable {
    case succeeded
    case failed(String)

    public var isSucceeded: Bool {
        if case .succeeded = self { return true }
        return false
    }

    public var description: String {
        switch self {
        case .succeeded:
            return "pass"
        case .failed(let reason):
            return "fail: \(reason)"
        }
    }
}
