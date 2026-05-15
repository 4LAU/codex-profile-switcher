import Foundation

public enum AuthBlobAvailability: Equatable {
    case present
    case missing
    case needsMigration
}

public enum AuthVaultBackend: String, Equatable {
    case dataProtectionShared
    case legacyACL
    case file
    case custom
}

public struct AuthVaultDiagnostics: Equatable {
    public var activeBackend: AuthVaultBackend
    public var accessGroup: String?
    public var dataProtectionProbe: String?

    public init(
        activeBackend: AuthVaultBackend,
        accessGroup: String? = nil,
        dataProtectionProbe: String? = nil
    ) {
        self.activeBackend = activeBackend
        self.accessGroup = accessGroup
        self.dataProtectionProbe = dataProtectionProbe
    }
}

public protocol AuthVault {
    func listProfileIDs() throws -> [String]
    func loadAuthBlob(profileID: String) throws -> Data?
    func loadAuthBlobForActivation(profileID: String) throws -> Data?
    func loadAuthBlobForDuplicateCheck(profileID: String) throws -> Data?
    func saveAuthBlob(_ data: Data, profileID: String) throws
    func deleteAuthBlob(profileID: String) throws
    func hasAuthBlob(profileID: String) throws -> Bool
    func authBlobAvailability(profileID: String) throws -> AuthBlobAvailability
    func repairStoredAuthAccess() throws -> Int
    func diagnostics() -> AuthVaultDiagnostics
}

public extension AuthVault {
    func loadAuthBlobForActivation(profileID: String) throws -> Data? {
        try self.loadAuthBlob(profileID: profileID)
    }

    func loadAuthBlobForDuplicateCheck(profileID: String) throws -> Data? {
        try self.loadAuthBlob(profileID: profileID)
    }

    func authBlobAvailability(profileID: String) throws -> AuthBlobAvailability {
        try self.hasAuthBlob(profileID: profileID) ? .present : .missing
    }

    func repairStoredAuthAccess() throws -> Int {
        var repaired = 0
        for profileID in try self.listProfileIDs() {
            guard let data = try self.loadAuthBlob(profileID: profileID) else { continue }
            try self.saveAuthBlob(data, profileID: profileID)
            repaired += 1
        }
        return repaired
    }

    func diagnostics() -> AuthVaultDiagnostics {
        AuthVaultDiagnostics(activeBackend: .custom)
    }
}
