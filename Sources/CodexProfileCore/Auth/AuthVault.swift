import Foundation

public enum AuthBlobAvailability: Equatable {
    case present
    case missing
}

public enum AuthVaultBackend: String, Equatable {
    case legacyACL
    case file
    case custom
}

public struct AuthVaultDiagnostics: Equatable {
    public var activeBackend: AuthVaultBackend

    public init(activeBackend: AuthVaultBackend) {
        self.activeBackend = activeBackend
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

public protocol AuthVault {
    func listProfileIDs() throws -> [String]
    func loadAuthBlob(profileID: String) throws -> Data?
    func saveAuthBlob(_ data: Data, profileID: String) throws
    func deleteAuthBlob(profileID: String) throws
    func hasAuthBlob(profileID: String) throws -> Bool
    func authBlobAvailability(profileID: String) throws -> AuthBlobAvailability
    func repairStoredAuthAccess() throws -> AuthVaultRepairResult
    func diagnostics() -> AuthVaultDiagnostics
}

public extension AuthVault {
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
