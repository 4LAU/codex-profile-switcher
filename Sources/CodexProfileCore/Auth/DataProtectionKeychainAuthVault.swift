import Foundation
import Security

public struct DataProtectionKeychainAuthVault: AuthVault, KeychainMigrationDestination {
    public static let accessGroup = "W3ZHLSH96F.com.4lau.codex-profile-switcher.auth-v2"
    public static let defaultService = LegacyKeychainAuthVault.defaultService

    public init() {}

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
                status: status)
        }
        guard let items = result as? [[String: Any]] else {
            throw KeychainAuthVaultError.unexpectedResult(operation: "list data-protection auth blobs")
        }
        return Array(Set(items.compactMap { item in
            guard let account = item[kSecAttrAccount as String] as? String, !account.isEmpty else {
                return nil
            }
            return account
        })).sorted()
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
                status: status)
        }
        guard let data = result as? Data else {
            throw KeychainAuthVaultError.unexpectedResult(operation: "load data-protection auth blob")
        }
        return data
    }

    public func saveAuthBlob(_ data: Data, profileID: String) throws {
        let update: [CFString: Any] = [
            kSecValueData: data,
            kSecAttrLabel: self.label(profileID: profileID),
        ]
        let updateStatus = SecItemUpdate(
            self.itemQuery(profileID: profileID) as CFDictionary,
            update as CFDictionary)
        if updateStatus == errSecSuccess {
            return
        }
        if updateStatus != errSecItemNotFound {
            throw KeychainAuthVaultError.operationFailed(
                operation: "save data-protection auth blob",
                profileID: profileID,
                status: updateStatus)
        }

        let addStatus = SecItemAdd(self.newItemAttributes(data: data, profileID: profileID) as CFDictionary, nil)
        if addStatus == errSecSuccess {
            return
        }
        if addStatus == errSecDuplicateItem {
            let retryStatus = SecItemUpdate(
                self.itemQuery(profileID: profileID) as CFDictionary,
                update as CFDictionary)
            if retryStatus == errSecSuccess {
                return
            }
            throw KeychainAuthVaultError.operationFailed(
                operation: "save data-protection auth blob",
                profileID: profileID,
                status: retryStatus)
        }
        throw KeychainAuthVaultError.operationFailed(
            operation: "save data-protection auth blob",
            profileID: profileID,
            status: addStatus)
    }

    public func deleteAuthBlob(profileID: String) throws {
        let status = SecItemDelete(self.itemQuery(profileID: profileID) as CFDictionary)
        if status == errSecSuccess || status == errSecItemNotFound {
            return
        }
        throw KeychainAuthVaultError.operationFailed(
            operation: "delete data-protection auth blob",
            profileID: profileID,
            status: status)
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
            status: status)
    }

    public func diagnostics() -> AuthVaultDiagnostics {
        AuthVaultDiagnostics(activeBackend: .dataProtectionKeychain)
    }

    func createAuthBlobIfAbsentForMigration(
        _ data: Data,
        profileID: String
    ) throws -> KeychainMigrationCreateResult {
        let status = SecItemAdd(self.newItemAttributes(data: data, profileID: profileID) as CFDictionary, nil)
        if status == errSecSuccess {
            return .created
        }
        if status == errSecDuplicateItem {
            return .alreadyExists
        }
        throw KeychainAuthVaultError.operationFailed(
            operation: "create data-protection auth blob for migration",
            profileID: profileID,
            status: status)
    }

    func itemQuery(profileID: String) -> [CFString: Any] {
        var query = self.baseServiceQuery()
        query[kSecAttrAccount] = profileID
        return query
    }

    func newItemAttributes(data: Data, profileID: String) -> [CFString: Any] {
        var attributes = self.itemQuery(profileID: profileID)
        attributes[kSecAttrLabel] = self.label(profileID: profileID)
        attributes[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        attributes[kSecValueData] = data
        return attributes
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
        [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: Self.defaultService,
            kSecAttrAccessGroup: Self.accessGroup,
            kSecAttrSynchronizable: kCFBooleanFalse as Any,
            kSecUseDataProtectionKeychain: kCFBooleanTrue as Any,
        ]
    }

    private func label(profileID: String) -> String {
        "Codex Profile Switcher: \(profileID)"
    }
}
