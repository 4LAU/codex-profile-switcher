import Foundation
import Security

public typealias KeychainAuthVault = LegacyKeychainAuthVault

struct LegacyKeychainAuthBlobCapture: Sendable {
    let profileID: String
    let authBlob: Data

    let persistentReference: Data
    let service: String

    init(profileID: String, authBlob: Data, persistentReference: Data, service: String) {
        self.profileID = profileID
        self.authBlob = authBlob
        self.persistentReference = persistentReference
        self.service = service
    }
}

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

    func captureLegacyAuthBlobsForMigration() throws -> [LegacyKeychainAuthBlobCapture] {
        try self.listProfileIDs().map { profileID in
            try self.captureLegacyAuthBlobForMigration(profileID: profileID)
        }
    }

    func captureLegacyAuthBlobForMigration(profileID: String) throws -> LegacyKeychainAuthBlobCapture {
        var result: CFTypeRef?
        let status = SecItemCopyMatching(
            self.migrationCaptureQuery(profileID: profileID) as CFDictionary,
            &result)
        guard status == errSecSuccess else {
            throw KeychainAuthVaultError.operationFailed(
                operation: "capture legacy auth blob",
                profileID: profileID,
                status: status)
        }
        guard let item = result as? [String: Any],
              self.isExpectedMigrationItem(item, profileID: profileID),
              let authBlob = item[kSecValueData as String] as? Data,
              AuthBlob.isPlausibleAuthBlob(authBlob),
              let persistentReference = item[kSecValuePersistentRef as String] as? Data,
              !persistentReference.isEmpty else {
            throw KeychainAuthVaultError.unexpectedResult(
                operation: "capture legacy auth blob")
        }
        return LegacyKeychainAuthBlobCapture(
            profileID: profileID,
            authBlob: authBlob,
            persistentReference: persistentReference,
            service: self.service)
    }

    func deleteCapturedLegacyAuthBlob(_ capture: LegacyKeychainAuthBlobCapture) throws {
        guard capture.service == self.service else {
            throw KeychainAuthVaultError.unexpectedResult(
                operation: "delete captured legacy auth blob")
        }

        var result: CFTypeRef?
        let validationStatus = SecItemCopyMatching(
            self.capturedItemQuery(capture, returningItem: true) as CFDictionary,
            &result)
        if validationStatus == errSecItemNotFound {
            throw KeychainAuthVaultError.staleMigrationSource
        }
        guard validationStatus == errSecSuccess else {
            throw KeychainAuthVaultError.operationFailed(
                operation: "revalidate legacy auth blob for migration",
                profileID: nil,
                status: validationStatus)
        }
        guard let item = result as? [String: Any],
              self.isExpectedMigrationItem(item, profileID: capture.profileID),
              let authBlob = item[kSecValueData as String] as? Data,
              authBlob == capture.authBlob else {
            throw KeychainAuthVaultError.staleMigrationSource
        }

        let deleteStatus = SecItemDelete(self.capturedItemQuery(capture) as CFDictionary)
        if deleteStatus == errSecItemNotFound {
            throw KeychainAuthVaultError.staleMigrationSource
        }
        guard deleteStatus == errSecSuccess else {
            throw KeychainAuthVaultError.operationFailed(
                operation: "delete captured legacy auth blob",
                profileID: nil,
                status: deleteStatus)
        }
    }

    public func saveAuthBlob(_ data: Data, profileID: String) throws {
        throw KeychainAuthVaultError.legacyVaultIsReadOnly
    }

    public func repairStoredAuthAccess() throws -> AuthVaultRepairResult {
        throw KeychainAuthVaultError.legacyVaultIsReadOnly
    }

    public func deleteAuthBlob(profileID: String) throws {
        throw KeychainAuthVaultError.legacyVaultIsReadOnly
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

    private func migrationCaptureQuery(profileID: String) -> [CFString: Any] {
        var query = self.itemQuery(profileID: profileID)
        query[kSecReturnAttributes] = kCFBooleanTrue
        query[kSecReturnData] = kCFBooleanTrue
        query[kSecReturnPersistentRef] = kCFBooleanTrue
        query[kSecMatchLimit] = kSecMatchLimitOne
        self.applyInteractionPolicy(to: &query)
        return query
    }

    private func capturedItemQuery(
        _ capture: LegacyKeychainAuthBlobCapture,
        returningItem: Bool = false
    ) -> [CFString: Any] {
        var query = self.itemQuery(profileID: capture.profileID)
        query[kSecValuePersistentRef] = capture.persistentReference
        if returningItem {
            query[kSecReturnAttributes] = kCFBooleanTrue
            query[kSecReturnData] = kCFBooleanTrue
            query[kSecMatchLimit] = kSecMatchLimitOne
        }
        self.applyInteractionPolicy(to: &query)
        return query
    }

    private func isExpectedMigrationItem(_ item: [String: Any], profileID: String) -> Bool {
        item[kSecAttrService as String] as? String == self.service
            && item[kSecAttrAccount as String] as? String == profileID
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
    case staleMigrationSource

    public var errorDescription: String? {
        switch self {
        case let .operationFailed(operation, profileID, status):
            let profile = profileID.map { " for profile '\($0)'" } ?? ""
            return "Could not \(operation)\(profile): \(Self.statusDescription(status))."
        case let .unexpectedResult(operation):
            return "Could not \(operation): Keychain returned an unexpected result."
        case .legacyVaultIsReadOnly:
            return "Legacy Keychain items are available only for an explicit migration."
        case .staleMigrationSource:
            return "The legacy Keychain copy changed before it could be removed."
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
        case .staleMigrationSource:
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
        case .staleMigrationSource:
            return "Review the legacy Keychain copies again before retrying the migration."
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
