import Foundation
import Security

struct KeychainAuthVault: AuthVault {
    static let defaultService = "com.4lau.codex-profile-switcher.auth"

    let service: String

    init(service: String = Self.defaultService) {
        self.service = service
    }

    func listProfileIDs() throws -> [String] {
        var result: CFTypeRef?
        let status = self.copyMatching(self.listQuery(useDataProtectionKeychain: true), result: &result)

        if status == errSecItemNotFound {
            return []
        }

        guard status == errSecSuccess else {
            throw KeychainAuthVaultError.operationFailed(
                operation: "list profile auth blobs",
                profileID: nil,
                status: status
            )
        }

        guard let items = result as? [[String: Any]] else {
            throw KeychainAuthVaultError.unexpectedResult(operation: "list profile auth blobs")
        }

        let profileIDs = items.compactMap { item -> String? in
            guard let account = item[kSecAttrAccount as String] as? String, !account.isEmpty else {
                return nil
            }
            return account
        }

        return Array(Set(profileIDs)).sorted()
    }

    func loadAuthBlob(profileID: String) throws -> Data? {
        var result: CFTypeRef?
        let status = self.copyMatching(self.loadQuery(profileID: profileID, useDataProtectionKeychain: true),
                                       result: &result)

        if status == errSecItemNotFound {
            return nil
        }

        guard status == errSecSuccess else {
            throw KeychainAuthVaultError.operationFailed(
                operation: "load auth blob",
                profileID: profileID,
                status: status
            )
        }

        guard let data = result as? Data else {
            throw KeychainAuthVaultError.unexpectedResult(operation: "load auth blob")
        }

        return data
    }

    func saveAuthBlob(_ data: Data, profileID: String) throws {
        let addStatus = self.addItem(self.itemAttributes(
            data: data,
            profileID: profileID,
            useDataProtectionKeychain: true))

        if addStatus == errSecSuccess {
            return
        }

        if addStatus == errSecDuplicateItem {
            let update: [CFString: Any] = [
                kSecAttrLabel: self.label(profileID: profileID),
                kSecValueData: data,
            ]
            let updateStatus = self.updateItem(
                self.itemQuery(profileID: profileID, useDataProtectionKeychain: true),
                update: update)

            guard updateStatus == errSecSuccess else {
                throw KeychainAuthVaultError.operationFailed(
                    operation: "update auth blob",
                    profileID: profileID,
                    status: updateStatus
                )
            }
            return
        }

        throw KeychainAuthVaultError.operationFailed(
            operation: "save auth blob",
            profileID: profileID,
            status: addStatus
        )
    }

    func deleteAuthBlob(profileID: String) throws {
        let status = self.deleteItem(self.itemQuery(profileID: profileID, useDataProtectionKeychain: true))

        if status == errSecSuccess || status == errSecItemNotFound {
            return
        }

        throw KeychainAuthVaultError.operationFailed(
            operation: "delete auth blob",
            profileID: profileID,
            status: status
        )
    }

    func hasAuthBlob(profileID: String) throws -> Bool {
        var query = self.itemQuery(profileID: profileID, useDataProtectionKeychain: true)
        query[kSecReturnData] = kCFBooleanFalse
        query[kSecReturnAttributes] = kCFBooleanFalse
        query[kSecMatchLimit] = kSecMatchLimitOne

        let status = self.copyMatching(query, result: nil)

        if status == errSecSuccess {
            return true
        }

        if status == errSecItemNotFound {
            return false
        }

        throw KeychainAuthVaultError.operationFailed(
            operation: "check auth blob",
            profileID: profileID,
            status: status
        )
    }

    private func listQuery(useDataProtectionKeychain: Bool) -> [CFString: Any] {
        var query = self.baseServiceQuery(useDataProtectionKeychain: useDataProtectionKeychain)
        query[kSecReturnAttributes] = kCFBooleanTrue
        query[kSecMatchLimit] = kSecMatchLimitAll
        return query
    }

    private func loadQuery(profileID: String, useDataProtectionKeychain: Bool) -> [CFString: Any] {
        var query = self.itemQuery(profileID: profileID, useDataProtectionKeychain: useDataProtectionKeychain)
        query[kSecReturnData] = kCFBooleanTrue
        query[kSecMatchLimit] = kSecMatchLimitOne
        return query
    }

    private func baseServiceQuery(useDataProtectionKeychain: Bool) -> [CFString: Any] {
        var query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: self.service,
            kSecAttrSynchronizable: kCFBooleanFalse as Any,
        ]
        if useDataProtectionKeychain {
            self.addDataProtectionKeychainAttribute(to: &query)
        }
        return query
    }

    private func itemQuery(profileID: String, useDataProtectionKeychain: Bool) -> [CFString: Any] {
        var query = self.baseServiceQuery(useDataProtectionKeychain: useDataProtectionKeychain)
        query[kSecAttrAccount] = profileID
        return query
    }

    private func itemAttributes(data: Data, profileID: String, useDataProtectionKeychain: Bool) -> [CFString: Any] {
        var attributes = self.itemQuery(
            profileID: profileID,
            useDataProtectionKeychain: useDataProtectionKeychain)
        attributes[kSecAttrLabel] = self.label(profileID: profileID)
        attributes[kSecValueData] = data
        return attributes
    }

    private func label(profileID: String) -> String {
        "Codex Profile Switcher: \(profileID)"
    }

    private func addDataProtectionKeychainAttribute(to query: inout [CFString: Any]) {
        if #available(macOS 10.15, *) {
            query[kSecUseDataProtectionKeychain] = kCFBooleanTrue as Any
        }
    }

    private func copyMatching(_ query: [CFString: Any], result: UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus {
        let status = SecItemCopyMatching(query as CFDictionary, result)
        guard (status == errSecMissingEntitlement || status == errSecItemNotFound),
              let fallback = self.withoutDataProtectionKeychain(query) else {
            return status
        }
        return SecItemCopyMatching(fallback as CFDictionary, result)
    }

    private func addItem(_ attributes: [CFString: Any]) -> OSStatus {
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecMissingEntitlement,
              let fallback = self.withoutDataProtectionKeychain(attributes) else {
            return status
        }
        return SecItemAdd(fallback as CFDictionary, nil)
    }

    private func updateItem(_ query: [CFString: Any], update: [CFString: Any]) -> OSStatus {
        let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        guard (status == errSecMissingEntitlement || status == errSecItemNotFound),
              let fallback = self.withoutDataProtectionKeychain(query) else {
            return status
        }
        return SecItemUpdate(fallback as CFDictionary, update as CFDictionary)
    }

    private func deleteItem(_ query: [CFString: Any]) -> OSStatus {
        let status = SecItemDelete(query as CFDictionary)
        guard (status == errSecMissingEntitlement || status == errSecItemNotFound),
              let fallback = self.withoutDataProtectionKeychain(query) else {
            return status
        }
        return SecItemDelete(fallback as CFDictionary)
    }

    private func withoutDataProtectionKeychain(_ query: [CFString: Any]) -> [CFString: Any]? {
        guard query[kSecUseDataProtectionKeychain] != nil else { return nil }
        var fallback = query
        fallback.removeValue(forKey: kSecUseDataProtectionKeychain)
        return fallback
    }
}

enum KeychainAuthVaultError: LocalizedError {
    case operationFailed(operation: String, profileID: String?, status: OSStatus)
    case unexpectedResult(operation: String)

    var errorDescription: String? {
        switch self {
        case let .operationFailed(operation, profileID, status):
            let profile = profileID.map { " for profile '\($0)'" } ?? ""
            return "Could not \(operation)\(profile): \(Self.statusDescription(status))."
        case let .unexpectedResult(operation):
            return "Could not \(operation): Keychain returned an unexpected result."
        }
    }

    var failureReason: String? {
        switch self {
        case let .operationFailed(_, _, status):
            return Self.statusName(status)
        case .unexpectedResult:
            return nil
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case let .operationFailed(_, _, status):
            switch status {
            case errSecInteractionNotAllowed:
                return "Unlock the login keychain or run the app in a user session that allows Keychain access."
            case errSecAuthFailed:
                return "Check Keychain access permissions for Codex Profile Switcher."
            case errSecMissingEntitlement:
                return "The app may need the Keychain entitlement required by this Keychain item."
            default:
                return nil
            }
        case .unexpectedResult:
            return nil
        }
    }

    static func statusDescription(_ status: OSStatus) -> String {
        let name = self.statusName(status)
        let message = SecCopyErrorMessageString(status, nil) as String?

        if let message, !message.isEmpty, message != name {
            return "\(name) (\(status)): \(message)"
        }

        return "\(name) (\(status))"
    }

    static func statusName(_ status: OSStatus) -> String {
        switch status {
        case errSecSuccess:
            return "errSecSuccess"
        case errSecUnimplemented:
            return "errSecUnimplemented"
        case errSecParam:
            return "errSecParam"
        case errSecAllocate:
            return "errSecAllocate"
        case errSecNotAvailable:
            return "errSecNotAvailable"
        case errSecAuthFailed:
            return "errSecAuthFailed"
        case errSecDuplicateItem:
            return "errSecDuplicateItem"
        case errSecItemNotFound:
            return "errSecItemNotFound"
        case errSecInteractionNotAllowed:
            return "errSecInteractionNotAllowed"
        case errSecDecode:
            return "errSecDecode"
        case errSecNoAccessForItem:
            return "errSecNoAccessForItem"
        case errSecNoDefaultKeychain:
            return "errSecNoDefaultKeychain"
        case errSecInvalidKeychain:
            return "errSecInvalidKeychain"
        case errSecInvalidItemRef:
            return "errSecInvalidItemRef"
        case errSecMissingEntitlement:
            return "errSecMissingEntitlement"
        case errSecUserCanceled:
            return "errSecUserCanceled"
        default:
            return "OSStatus"
        }
    }
}
