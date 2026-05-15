import Foundation

public final class MigratingAuthVault: AuthVault {
    private let dataProtection: AuthVault
    private let legacy: AuthVault
    private let accessGroup: String?
    private let probeResult: DataProtectionProbeResult
    public var migrationComplete: Bool

    public init(
        service: String = LegacyKeychainAuthVault.defaultService,
        accessGroup: String? = KeychainAccessGroupResolver.configuredAccessGroup(),
        migrationComplete: Bool = false
    ) {
        let dpVault = DataProtectionKeychainAuthVault(service: service, accessGroup: accessGroup)
        let probe = accessGroup == nil
            ? DataProtectionProbeResult.failed("no keychain access group configured")
            : dpVault.probe()
        self.dataProtection = dpVault
        self.legacy = LegacyKeychainAuthVault(service: service)
        self.accessGroup = accessGroup
        self.probeResult = probe
        self.migrationComplete = migrationComplete
    }

    public init(
        dataProtection: AuthVault,
        legacy: AuthVault,
        accessGroup: String? = nil,
        probeResult: DataProtectionProbeResult,
        migrationComplete: Bool = false
    ) {
        self.dataProtection = dataProtection
        self.legacy = legacy
        self.accessGroup = accessGroup
        self.probeResult = probeResult
        self.migrationComplete = migrationComplete
    }

    public func listProfileIDs() throws -> [String] {
        if self.usesDataProtection {
            return try self.dataProtection.listProfileIDs()
        }
        return try self.legacy.listProfileIDs()
    }

    public func loadAuthBlob(profileID: String) throws -> Data? {
        if self.usesDataProtection {
            return try self.dataProtection.loadAuthBlob(profileID: profileID)
        }
        return try self.legacy.loadAuthBlob(profileID: profileID)
    }

    public func loadAuthBlobForActivation(profileID: String) throws -> Data? {
        if !self.usesDataProtection {
            return try self.legacy.loadAuthBlob(profileID: profileID)
        }

        if let data = try self.dataProtection.loadAuthBlob(profileID: profileID) {
            return data
        }

        guard !self.migrationComplete,
              let legacyData = try self.legacy.loadAuthBlob(profileID: profileID) else {
            return nil
        }

        try self.dataProtection.saveAuthBlob(legacyData, profileID: profileID)
        guard try self.dataProtection.loadAuthBlob(profileID: profileID) == legacyData else {
            throw KeychainAuthVaultError.unexpectedResult(operation: "verify migrated auth blob")
        }
        try self.legacy.deleteAuthBlob(profileID: profileID)
        return legacyData
    }

    public func loadAuthBlobForDuplicateCheck(profileID: String) throws -> Data? {
        if !self.usesDataProtection {
            return try self.legacy.loadAuthBlob(profileID: profileID)
        }
        if let data = try self.dataProtection.loadAuthBlob(profileID: profileID) {
            return data
        }
        guard !self.migrationComplete else { return nil }
        return try self.legacy.loadAuthBlob(profileID: profileID)
    }

    public func saveAuthBlob(_ data: Data, profileID: String) throws {
        if self.usesDataProtection {
            try self.dataProtection.saveAuthBlob(data, profileID: profileID)
        } else {
            try self.legacy.saveAuthBlob(data, profileID: profileID)
        }
    }

    public func deleteAuthBlob(profileID: String) throws {
        if !self.usesDataProtection {
            try self.legacy.deleteAuthBlob(profileID: profileID)
            return
        }

        var firstError: Error?
        do {
            try self.dataProtection.deleteAuthBlob(profileID: profileID)
        } catch {
            firstError = error
        }
        do {
            try self.legacy.deleteAuthBlob(profileID: profileID)
        } catch {
            if firstError == nil {
                firstError = error
            }
        }
        if let firstError {
            throw firstError
        }
    }

    public func hasAuthBlob(profileID: String) throws -> Bool {
        try self.authBlobAvailability(profileID: profileID) == .present
    }

    public func authBlobAvailability(profileID: String) throws -> AuthBlobAvailability {
        if !self.usesDataProtection {
            return try self.legacy.hasAuthBlob(profileID: profileID) ? .present : .missing
        }
        if try self.dataProtection.hasAuthBlob(profileID: profileID) {
            return .present
        }
        guard !self.migrationComplete else {
            return .missing
        }
        return try self.legacy.hasAuthBlob(profileID: profileID) ? .needsMigration : .missing
    }

    public func repairStoredAuthAccess() throws -> Int {
        if self.usesDataProtection {
            return 0
        }
        return try self.legacy.repairStoredAuthAccess()
    }

    public func diagnostics() -> AuthVaultDiagnostics {
        AuthVaultDiagnostics(
            activeBackend: self.usesDataProtection ? .dataProtectionShared : .legacyACL,
            accessGroup: self.accessGroup,
            dataProtectionProbe: self.probeResult.description
        )
    }

    private var usesDataProtection: Bool {
        self.probeResult.isSucceeded
    }
}
