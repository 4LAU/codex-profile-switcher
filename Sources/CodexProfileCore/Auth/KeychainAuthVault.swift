import Foundation
import Security

public typealias KeychainAuthVault = LegacyKeychainAuthVault

public struct LegacyKeychainAuthVault: AuthVault {
    public static let defaultService = "com.4lau.codex-profile-switcher.auth"

    public let service: String

    /// When `false`, all read queries set `kSecUseAuthenticationUI = .fail` so a
    /// Keychain access that would otherwise show a modal consent prompt instead
    /// returns `errSecInteractionNotAllowed`. This keeps the menu bar app's
    /// default behavior (`true`) untouched while letting the CLI stay
    /// non-interactive in non-TTY shells.
    public let interactionAllowed: Bool

    public init(service: String = Self.defaultService, interactionAllowed: Bool = true) {
        self.service = service
        self.interactionAllowed = interactionAllowed
    }

    public func listProfileIDs() throws -> [String] {
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

    public func loadAuthBlob(profileID: String) throws -> Data? {
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

    public func saveAuthBlob(_ data: Data, profileID: String) throws {
        throw KeychainAuthVaultError.legacyVaultIsReadOnly
    }

    public func repairStoredAuthAccess() throws -> AuthVaultRepairResult {
        throw KeychainAuthVaultError.legacyVaultIsReadOnly
    }

    public func deleteAuthBlob(profileID: String) throws {
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

    public func hasAuthBlob(profileID: String) throws -> Bool {
        var query = self.itemQuery(profileID: profileID)
        query[kSecReturnData] = kCFBooleanFalse
        query[kSecReturnAttributes] = kCFBooleanFalse
        query[kSecMatchLimit] = kSecMatchLimitOne
        self.applyInteractionPolicy(to: &query)

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

    public func diagnostics() -> AuthVaultDiagnostics {
        AuthVaultDiagnostics(activeBackend: .legacyACL)
    }

    private func listQuery() -> [CFString: Any] {
        var query = self.baseServiceQuery()
        query[kSecReturnAttributes] = kCFBooleanTrue
        query[kSecMatchLimit] = kSecMatchLimitAll
        self.applyInteractionPolicy(to: &query)
        return query
    }

    private func loadQuery(profileID: String) -> [CFString: Any] {
        var query = self.itemQuery(profileID: profileID)
        query[kSecReturnData] = kCFBooleanTrue
        query[kSecMatchLimit] = kSecMatchLimitOne
        self.applyInteractionPolicy(to: &query)
        return query
    }

    /// Adds the fail-closed authentication-UI flag to read queries when
    /// `interactionAllowed == false`, so a Keychain ACL prompt is replaced by an
    /// `errSecInteractionNotAllowed` error instead of a modal dialog.
    private func applyInteractionPolicy(to query: inout [CFString: Any]) {
        guard !self.interactionAllowed else { return }
        query[kSecUseAuthenticationUI] = kSecUseAuthenticationUIFail
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
}

public enum KeychainAuthVaultError: LocalizedError {
    case operationFailed(operation: String, profileID: String?, status: OSStatus)
    case unexpectedResult(operation: String)
    case legacyVaultIsReadOnly

    public var errorDescription: String? {
        switch self {
        case let .operationFailed(operation, profileID, status):
            let profile = profileID.map { " for profile '\($0)'" } ?? ""
            return "Could not \(operation)\(profile): \(Self.statusDescription(status))."
        case let .unexpectedResult(operation):
            return "Could not \(operation): Keychain returned an unexpected result."
        case .legacyVaultIsReadOnly:
            return "Legacy Keychain items are available only for an explicit migration."
        }
    }

    public var failureReason: String? {
        switch self {
        case let .operationFailed(_, _, status):
            return Self.statusName(status)
        case .unexpectedResult:
            return nil
        case .legacyVaultIsReadOnly:
            return nil
        }
    }

    /// True when the failure is the Keychain refusing to prompt for interactive
    /// consent (fail-closed mode). Callers in non-interactive contexts use this
    /// to distinguish "needs a terminal once" from other Keychain errors.
    public var isInteractionRequired: Bool {
        if case let .operationFailed(_, _, status) = self {
            return status == errSecInteractionNotAllowed
        }
        return false
    }

    public var recoverySuggestion: String? {
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
        case .legacyVaultIsReadOnly:
            return nil
        }
    }

    public static func statusDescription(_ status: OSStatus) -> String {
        let name = self.statusName(status)
        let message = SecCopyErrorMessageString(status, nil) as String?

        if let message, !message.isEmpty, message != name {
            return "\(name) (\(status)): \(message)"
        }

        return "\(name) (\(status))"
    }

    public static func statusName(_ status: OSStatus) -> String {
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
