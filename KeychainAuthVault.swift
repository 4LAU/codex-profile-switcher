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
            let updateStatus = self.updateExistingItem(data: data, profileID: profileID)
            if updateStatus == errSecSuccess {
                return
            }

            let recreateStatus = self.recreateItem(attributes, profileID: profileID)
            guard recreateStatus == errSecSuccess else {
                throw KeychainAuthVaultError.operationFailed(
                    operation: "repair auth blob access",
                    profileID: profileID,
                    status: recreateStatus
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
        if let access = self.authAccessControl() {
            attributes[kSecAttrAccess] = access
        }
        attributes[kSecValueData] = data
        return attributes
    }

    private func label(profileID: String) -> String {
        "Codex Profile Switcher: \(profileID)"
    }

    private func authAccessControl() -> SecAccess? {
        // These legacy ACL APIs are still the practical way to let both the app
        // and helper access one login-keychain item without repeated prompts.
        // Keep automated tests on FileAuthVault so CI never exercises them.
        let trustedPaths = self.trustedApplicationPaths()
        guard !trustedPaths.isEmpty else { return nil }

        var trustedApplications: [SecTrustedApplication] = []
        for path in trustedPaths {
            var application: SecTrustedApplication?
            let status = path.withCString { cPath in
                SecTrustedApplicationCreateFromPath(cPath, &application)
            }
            if status == errSecSuccess, let application {
                trustedApplications.append(application)
            }
        }
        guard !trustedApplications.isEmpty else { return nil }

        var access: SecAccess?
        let status = SecAccessCreate("Codex Profile Switcher Auth" as CFString,
                                     trustedApplications as CFArray,
                                     &access)
        return status == errSecSuccess ? access : nil
    }

    private func updateExistingItem(data: Data, profileID: String) -> OSStatus {
        var update: [CFString: Any] = [
            kSecAttrLabel: self.label(profileID: profileID),
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData: data,
        ]
        if let access = self.authAccessControl() {
            update[kSecAttrAccess] = access
        }

        return self.updateItem(self.itemQuery(profileID: profileID), update: update)
    }

    private func recreateItem(_ attributes: [CFString: Any], profileID: String) -> OSStatus {
        let query = self.itemQuery(profileID: profileID)
        let deleteStatus = SecItemDelete(query as CFDictionary)
        guard deleteStatus == errSecSuccess || deleteStatus == errSecItemNotFound else {
            return deleteStatus
        }
        return SecItemAdd(attributes as CFDictionary, nil)
    }

    private func trustedApplicationPaths(
        executableURL: URL? = Bundle.main.executableURL,
        bundleURL: URL = Bundle.main.bundleURL
    ) -> [String] {
        var paths: [String] = []
        func append(_ path: String) {
            guard !path.isEmpty,
                  FileManager.default.fileExists(atPath: path),
                  !paths.contains(path) else { return }
            paths.append(path)
        }

        if let appBundle = self.appBundleURL(containing: bundleURL)
            ?? executableURL.flatMap(self.appBundleURL(containing:)) {
            append(appBundle.path)
            append(appBundle.appendingPathComponent("Contents/MacOS/CodexProfileSwitcher").path)
            append(appBundle.appendingPathComponent("Contents/Helpers/codex-profile").path)
        }

        if let executableURL {
            append(executableURL.path)
            let siblingName = executableURL.lastPathComponent == "codex-profile"
                ? "codex-profile-switcher"
                : "codex-profile"
            append(executableURL.deletingLastPathComponent().appendingPathComponent(siblingName).path)
        }
        return paths
    }

    private func appBundleURL(containing url: URL) -> URL? {
        var current = url.standardizedFileURL
        while current.path != "/" {
            if current.pathExtension == "app" {
                return current
            }
            current.deleteLastPathComponent()
        }
        return nil
    }

    private func updateItem(_ query: [CFString: Any], update: [CFString: Any]) -> OSStatus {
        SecItemUpdate(query as CFDictionary, update as CFDictionary)
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
