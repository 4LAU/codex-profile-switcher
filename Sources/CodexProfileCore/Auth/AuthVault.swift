import Foundation

public enum AuthBlobAvailability: Equatable {
    case present
    case missing
}

public enum AuthVaultBackend: String, Equatable {
    case legacyACL
    case file
    case custom
    case dataProtectionKeychain

    public var displayName: String {
        switch self {
        case .legacyACL:
            return "macOS Keychain"
        case .file:
            return "file auth vault"
        case .custom:
            return "custom auth vault"
        case .dataProtectionKeychain:
            return "Data Protection Keychain"
        }
    }
}

public struct AuthVaultDiagnostics: Equatable {
    public var activeBackend: AuthVaultBackend

    public init(activeBackend: AuthVaultBackend) {
        self.activeBackend = activeBackend
    }
}

public enum PrimaryAuthVaultSelector {
    public static func makeVault(
        hasDataProtectionKeychainAccess: Bool,
        fileVaultRoot: URL,
        authLockURL: URL = AppPaths().authLockURL
    ) -> AuthVault {
        hasDataProtectionKeychainAccess
            ? DataProtectionKeychainAuthVault(authLockURL: authLockURL)
            : FileAuthVault(root: fileVaultRoot, authLockURL: authLockURL)
    }
}

public struct AuthVaultRepairResult: Equatable {
    public let total: Int
    public let repaired: Int
    public var isComplete: Bool { self.repaired == self.total }

    public init(total: Int, repaired: Int) {
        self.total = total
        self.repaired = repaired
    }
}

public protocol AuthVault: Sendable {
    /// The lock guarding this instance's own read-modify-write transactions.
    /// Must be threaded from the SAME `AppPaths` (or equivalent environment)
    /// the instance stores its data under — see `transact`.
    var authLockURL: URL { get }

    func listProfileIDs() throws -> [String]
    func loadAuthBlob(profileID: String) throws -> Data?
    func _saveAuthBlobUnlocked(_ data: Data, profileID: String) throws
    func _deleteAuthBlobUnlocked(profileID: String) throws
    func hasAuthBlob(profileID: String) throws -> Bool
    func authBlobAvailability(profileID: String) throws -> AuthBlobAvailability
    func repairStoredAuthAccess() throws -> AuthVaultRepairResult
    func diagnostics() -> AuthVaultDiagnostics
}

public extension AuthVault {
    /// Default: the real environment's auth lock. A vault built with an
    /// injected (non-ambient) environment — e.g. a test or dev instance
    /// pointed at a scratch `CODEX_PROFILE_HOME` — MUST override this with the
    /// same `AppPaths` it used to resolve where it stores data, or this default
    /// silently locks a different file than the one it reads/writes.
    var authLockURL: URL { AppPaths().authLockURL }

    /// Auth locking may be nested inside `CacheLock`, but must never enclose it.
    /// Keep this transaction limited to bounded vault operations: it must not
    /// include usage fetches, profile ranking, or Codex subprocesses.
    func transact<T>(_ body: () throws -> T) throws -> T {
        try CacheLock.withLock(at: self.authLockURL) {
            try body()
        }
    }

    func saveAuthBlob(_ data: Data, profileID: String) throws {
        try self.transact {
            try self._saveAuthBlobUnlocked(data, profileID: profileID)
        }
    }

    func deleteAuthBlob(profileID: String) throws {
        try self.transact {
            try self._deleteAuthBlobUnlocked(profileID: profileID)
        }
    }

    func authBlobAvailability(profileID: String) throws -> AuthBlobAvailability {
        try self.hasAuthBlob(profileID: profileID) ? .present : .missing
    }

    func repairStoredAuthAccess() throws -> AuthVaultRepairResult {
        let profileIDs = try self.listProfileIDs()
        var repaired = 0
        for profileID in profileIDs {
            guard let data = try? self.loadAuthBlob(profileID: profileID) else { continue }
            try self.saveAuthBlob(data, profileID: profileID)
            repaired += 1
        }
        return AuthVaultRepairResult(total: profileIDs.count, repaired: repaired)
    }

    func diagnostics() -> AuthVaultDiagnostics {
        AuthVaultDiagnostics(activeBackend: .custom)
    }
}
