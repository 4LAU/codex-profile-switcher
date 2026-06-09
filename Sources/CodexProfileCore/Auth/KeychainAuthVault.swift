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
        let dataOnly: [CFString: Any] = [
            kSecValueData: data,
            kSecAttrLabel: self.label(profileID: profileID),
        ]
        let dataOnlyStatus = SecItemUpdate(
            self.itemQuery(profileID: profileID) as CFDictionary,
            dataOnly as CFDictionary)
        if dataOnlyStatus == errSecSuccess {
            return
        }

        if dataOnlyStatus == errSecItemNotFound {
            let addStatus = SecItemAdd(self.itemAttributes(data: data, profileID: profileID) as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw KeychainAuthVaultError.operationFailed(
                    operation: "save auth blob",
                    profileID: profileID,
                    status: addStatus
                )
            }
            return
        }

        let withAccessible: [CFString: Any] = [
            kSecValueData: data,
            kSecAttrLabel: self.label(profileID: profileID),
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let accessibleStatus = SecItemUpdate(
            self.itemQuery(profileID: profileID) as CFDictionary,
            withAccessible as CFDictionary)
        if accessibleStatus == errSecSuccess {
            return
        }

        throw KeychainAuthVaultError.operationFailed(
            operation: "update auth blob",
            profileID: profileID,
            status: dataOnlyStatus
        )
    }

    public func repairStoredAuthAccess() throws -> AuthVaultRepairResult {
        self.restoreRepairRecoveryFiles()
        let profileIDs = try self.listProfileIDs()
        var repaired = 0
        for profileID in profileIDs {
            let data: Data?
            do {
                data = try self.loadAuthBlob(profileID: profileID)
            } catch {
                CoreLogger.warning("Skipping repair for profile - load failed",
                                   metadata: ["profile": profileID, "error": error.localizedDescription])
                continue
            }
            guard let data else { continue }
            guard self.writeRepairRecoveryFile(data: data, profileID: profileID) else { continue }
            let status = self.replaceExistingItem(data: data, profileID: profileID, rollbackData: data)
            if status == errSecSuccess {
                if self.removeRepairRecoveryFile(profileID: profileID) {
                    repaired += 1
                }
            } else {
                let stillExists = (try? self.hasAuthBlob(profileID: profileID)) ?? false
                CoreLogger.error("Repair failed for profile",
                                 metadata: [
                                     "profile": profileID,
                                     "status": "\(status)",
                                     "data_preserved": "\(stillExists)",
                                 ])
            }
        }
        return AuthVaultRepairResult(total: profileIDs.count, repaired: repaired)
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

        if let bundleURL = self.enclosingAppBundle(for: execURL) {
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

    private func enclosingAppBundle(for executableURL: URL) -> URL? {
        if Bundle.main.bundleURL.pathExtension == "app" {
            return Bundle.main.bundleURL
        }
        var url = executableURL.standardizedFileURL
        while url.path != "/" {
            if url.pathExtension == "app" {
                return url
            }
            url = url.deletingLastPathComponent()
        }
        return nil
    }

    private func label(profileID: String) -> String {
        "Codex Profile Switcher: \(profileID)"
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
            let rollbackStatus = SecItemAdd(
                self.itemAttributes(data: rollbackData, profileID: profileID) as CFDictionary,
                nil)
            if rollbackStatus != errSecSuccess {
                CoreLogger.error("Rollback failed after unsuccessful replace",
                                 metadata: [
                                     "profile": profileID,
                                     "addStatus": "\(addStatus)",
                                     "rollbackStatus": "\(rollbackStatus)",
                                 ])
            }
        }

        return addStatus
    }

    private func writeRepairRecoveryFile(data: Data, profileID: String) -> Bool {
        do {
            try self.ensureRepairRecoveryRoot()
            let url = self.repairRecoveryURL(profileID: profileID)
            try data.write(to: url, options: [.atomic])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            return true
        } catch {
            CoreLogger.error("Failed to write Keychain repair recovery file",
                             metadata: ["profile": profileID, "error": error.localizedDescription])
            return false
        }
    }

    private func removeRepairRecoveryFile(profileID: String) -> Bool {
        let url = self.repairRecoveryURL(profileID: profileID)
        guard FileManager.default.fileExists(atPath: url.path) else { return true }
        return self.removeRepairRecoveryFile(at: url, profileID: profileID)
    }

    private func restoreRepairRecoveryFiles() {
        let root = self.repairRecoveryServiceRoot()
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return }

        for file in files where file.pathExtension == "recovery" {
            let encodedProfileID = file.deletingPathExtension().lastPathComponent
            guard let profileID = Self.decodeRecoveryComponent(encodedProfileID),
                  let data = try? Data(contentsOf: file) else { continue }
            do {
                if try self.hasAuthBlob(profileID: profileID) {
                    self.removeRepairRecoveryFile(at: file, profileID: profileID)
                    continue
                }
            } catch {
                CoreLogger.warning("Could not check Keychain recovery target",
                                   metadata: ["profile": profileID, "error": error.localizedDescription])
                continue
            }

            let status = SecItemAdd(self.itemAttributes(data: data, profileID: profileID) as CFDictionary, nil)
            if status == errSecSuccess || status == errSecDuplicateItem {
                self.removeRepairRecoveryFile(at: file, profileID: profileID)
            } else {
                CoreLogger.error("Failed to restore Keychain item from repair recovery file",
                                 metadata: ["profile": profileID, "status": "\(status)"])
            }
        }
    }

    private func ensureRepairRecoveryRoot() throws {
        try FileManager.default.createDirectory(
            at: self.repairRecoveryServiceRoot(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
    }

    private func repairRecoveryURL(profileID: String) -> URL {
        self.repairRecoveryServiceRoot()
            .appendingPathComponent(Self.encodeRecoveryComponent(profileID))
            .appendingPathExtension("recovery")
    }

    @discardableResult
    private func removeRepairRecoveryFile(at url: URL, profileID: String) -> Bool {
        do {
            try FileManager.default.removeItem(at: url)
            return true
        } catch {
            CoreLogger.error("Failed to remove Keychain repair recovery file",
                             metadata: ["profile": profileID, "error": error.localizedDescription])
            return false
        }
    }

    private func repairRecoveryServiceRoot() -> URL {
        AppPaths().tempRoot
            .appendingPathComponent("keychain-repair-recovery", isDirectory: true)
            .appendingPathComponent(Self.encodeRecoveryComponent(self.service), isDirectory: true)
    }

    private static func encodeRecoveryComponent(_ value: String) -> String {
        Data(value.utf8)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func decodeRecoveryComponent(_ value: String) -> String? {
        var base64 = value
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let padding = base64.count % 4
        if padding > 0 {
            base64.append(String(repeating: "=", count: 4 - padding))
        }
        guard let data = Data(base64Encoded: base64) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

public enum KeychainAuthVaultError: LocalizedError {
    case operationFailed(operation: String, profileID: String?, status: OSStatus)
    case unexpectedResult(operation: String)

    public var errorDescription: String? {
        switch self {
        case let .operationFailed(operation, profileID, status):
            let profile = profileID.map { " for profile '\($0)'" } ?? ""
            return "Could not \(operation)\(profile): \(Self.statusDescription(status))."
        case let .unexpectedResult(operation):
            return "Could not \(operation): Keychain returned an unexpected result."
        }
    }

    public var failureReason: String? {
        switch self {
        case let .operationFailed(_, _, status):
            return Self.statusName(status)
        case .unexpectedResult:
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
