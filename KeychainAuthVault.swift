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
        let status = SecItemCopyMatching(self.listQuery() as CFDictionary, &result)

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
        let status = SecItemCopyMatching(self.loadQuery(profileID: profileID) as CFDictionary, &result)

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
        let attributes = self.itemAttributes(data: data, profileID: profileID)
        let addStatus = SecItemAdd(attributes as CFDictionary, nil)

        if addStatus == errSecSuccess {
            return
        }

        if addStatus == errSecDuplicateItem {
            if let existingData = try? self.loadAuthBlob(profileID: profileID) {
                let replaceStatus = self.replaceExistingItem(
                    data: data,
                    profileID: profileID,
                    rollbackData: existingData
                )
                if replaceStatus == errSecSuccess {
                    return
                }
            }

            let updateStatus = self.updateExistingItem(data: data, profileID: profileID, repairAccess: true)
            if updateStatus == errSecSuccess {
                return
            }

            let valueOnlyStatus = self.updateExistingItem(data: data, profileID: profileID, repairAccess: false)
            if valueOnlyStatus == errSecSuccess {
                return
            }

            throw KeychainAuthVaultError.operationFailed(
                operation: "update auth blob",
                profileID: profileID,
                status: valueOnlyStatus
            )
        }

        throw KeychainAuthVaultError.operationFailed(
            operation: "save auth blob",
            profileID: profileID,
            status: addStatus
        )
    }

    func repairStoredAuthAccess() throws -> Int {
        var repaired = 0
        for profileID in try self.listProfileIDs() {
            guard let data = try self.loadAuthBlob(profileID: profileID) else { continue }
            let status = self.replaceExistingItem(data: data, profileID: profileID, rollbackData: data)
            guard status == errSecSuccess else {
                throw KeychainAuthVaultError.operationFailed(
                    operation: "repair auth blob access",
                    profileID: profileID,
                    status: status
                )
            }
            repaired += 1
        }
        return repaired
    }

    func deleteAuthBlob(profileID: String) throws {
        let status = SecItemDelete(self.itemQuery(profileID: profileID) as CFDictionary)

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
            operation: "check auth blob",
            profileID: profileID,
            status: status
        )
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
            kSecAttrService: self.service,
            kSecAttrSynchronizable: kCFBooleanFalse as Any,
        ]
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
        if let access = self.sharedAccess(profileID: profileID) {
            attributes[kSecAttrAccess] = access
        }
        return attributes
    }

    private func sharedAccess(profileID: String) -> SecAccess? {
        var trustedApps: [SecTrustedApplication] = []

        var selfApp: SecTrustedApplication?
        if SecTrustedApplicationCreateFromPath(nil, &selfApp) == errSecSuccess,
           let app = selfApp {
            trustedApps.append(app)
        }

        let siblingPaths = self.siblingBinaryPaths()
        for path in siblingPaths {
            var trusted: SecTrustedApplication?
            if SecTrustedApplicationCreateFromPath(path, &trusted) == errSecSuccess,
               let app = trusted {
                trustedApps.append(app)
            }
        }

        guard !trustedApps.isEmpty else { return nil }

        var access: SecAccess?
        let status = SecAccessCreate(
            self.label(profileID: profileID) as CFString,
            trustedApps as CFArray,
            &access
        )
        return status == errSecSuccess ? access : nil
    }

    private func siblingBinaryPaths() -> [String] {
        let execURL = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
        var paths: [String] = []

        if let bundleURL = Bundle.main.bundleURL.pathExtension == "app" ? Bundle.main.bundleURL : nil {
            let helperPath = bundleURL.appendingPathComponent("Contents/Helpers/codex-profile").path
            let appPath = bundleURL.appendingPathComponent("Contents/MacOS/CodexProfileSwitcher").path
            if execURL.path != helperPath { paths.append(helperPath) }
            if execURL.path != appPath { paths.append(appPath) }
        } else {
            let dir = execURL.deletingLastPathComponent()
            let candidates = ["codex-profile", "codex-profile-switcher"]
            for name in candidates {
                let path = dir.appendingPathComponent(name).path
                if path != execURL.path { paths.append(path) }
            }
        }

        return paths
    }

    private func label(profileID: String) -> String {
        "Codex Profile Switcher: \(profileID)"
    }

    private func updateExistingItem(data: Data, profileID: String, repairAccess: Bool) -> OSStatus {
        var update: [CFString: Any] = [
            kSecAttrLabel: self.label(profileID: profileID),
            kSecValueData: data,
        ]
        if repairAccess {
            update[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        }

        return self.updateItem(self.itemQuery(profileID: profileID), update: update)
    }

    private func updateItem(_ query: [CFString: Any], update: [CFString: Any]) -> OSStatus {
        SecItemUpdate(query as CFDictionary, update as CFDictionary)
    }

    private func replaceExistingItem(data: Data, profileID: String, rollbackData: Data) -> OSStatus {
        let deleteStatus = SecItemDelete(self.itemQuery(profileID: profileID) as CFDictionary)
        guard deleteStatus == errSecSuccess || deleteStatus == errSecItemNotFound else {
            return deleteStatus
        }

        let addStatus = SecItemAdd(self.itemAttributes(data: data, profileID: profileID) as CFDictionary, nil)
        if addStatus == errSecSuccess {
            return errSecSuccess
        }

        if deleteStatus == errSecSuccess {
            _ = SecItemAdd(self.itemAttributes(data: rollbackData, profileID: profileID) as CFDictionary, nil)
        }

        return addStatus
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
