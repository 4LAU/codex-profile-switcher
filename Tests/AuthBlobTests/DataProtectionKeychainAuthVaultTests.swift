@testable import CodexProfileCore
import Foundation
import Security
import Testing

final class DataProtectionKeychainAuthVaultTests {
    @Test
    func resolverAcceptsOnlyTheExactAccessGroupEntitlement() throws {
        let expected = DataProtectionKeychainAuthVault.accessGroup

        try expectEqual(
            KeychainAccessGroupResolver.resolve(accessGroupsEntitlement: [expected]),
            expected,
            "The exact keychain access group should be accepted")
        try expect(
            KeychainAccessGroupResolver.resolve(accessGroupsEntitlement: ["wrong.group"]) == nil,
            "A different keychain access group must be rejected")
        try expect(
            KeychainAccessGroupResolver.resolve(accessGroupsEntitlement: [expected, "wrong.group"]) == nil,
            "An entitlement with additional groups must be rejected")
        try expect(
            KeychainAccessGroupResolver.resolve(accessGroupsEntitlement: expected) == nil,
            "A malformed entitlement value must be rejected")
    }

    @Test
    func dataProtectionQueriesUseTheFixedSecurityAttributes() throws {
        let vault = DataProtectionKeychainAuthVault()
        let profileID = "profile-1"
        let query = vault.itemQuery(profileID: profileID)
        let attributes = vault.newItemAttributes(data: Data("test".utf8), profileID: profileID)

        try expect(
            vault.diagnostics().usesDataProtectionKeychain,
            "Diagnostics must identify the Data Protection backend")
        try expectEqual(
            query[kSecClass] as? String,
            kSecClassGenericPassword as String,
            "Wrong Keychain item class")
        try expectEqual(
            query[kSecAttrService] as? String,
            LegacyKeychainAuthVault.defaultService,
            "The v2 destination must retain the existing service")
        try expectEqual(query[kSecAttrAccount] as? String, profileID, "Profile ID missing from item query")
        try expectEqual(
            query[kSecAttrAccessGroup] as? String,
            DataProtectionKeychainAuthVault.accessGroup,
            "The v2 access group must be fixed")
        try expectEqual(query[kSecAttrSynchronizable] as? Bool, false, "v2 items must not synchronize")
        try expectEqual(
            query[kSecUseDataProtectionKeychain] as? Bool,
            true,
            "v2 queries must use the Data Protection Keychain")
        try expectEqual(
            attributes[kSecAttrAccessible] as? String,
            kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String,
            "New v2 items must remain device-only after first unlock")
    }

    @Test
    func migrationStateIsPerProfileAndBackwardCompatible() throws {
        let oldConfigData = Data("""
        {"profiles":[{"id":"1","label":"One"}],"activeProfile":"1","authStorageVersion":4}
        """.utf8)
        let oldConfig = try JSONDecoder().decode(AppConfig.self, from: oldConfigData)
        try expect(oldConfig.authMigrationStates == nil, "Old configs must decode without migration state")

        let config = AppConfig(
            profiles: [ProfileConfig(id: "1", label: "One"), ProfileConfig(id: "2", label: "Two")],
            activeProfile: "1",
            authMigrationStates: ["1": .copiedCleanupPending, "2": .complete])
        let roundTripped = try JSONDecoder().decode(AppConfig.self, from: JSONEncoder().encode(config))

        try expectEqual(
            roundTripped.authMigrationStates?["1"],
            .copiedCleanupPending,
            "Per-profile cleanup-pending state did not survive encoding")
        try expectEqual(
            roundTripped.authMigrationStates?["2"],
            .complete,
            "Per-profile complete state did not survive encoding")
    }

    @Test
    func genericLegacyMutationsFailClosedWithoutKeychainAccess() throws {
        let legacyVault = LegacyKeychainAuthVault()

        try expectLegacyVaultIsReadOnly {
            try legacyVault.saveAuthBlob(Data("test".utf8), profileID: "profile-1")
        }
        try expectLegacyVaultIsReadOnly {
            _ = try legacyVault.repairStoredAuthAccess()
        }
        try expectLegacyVaultIsReadOnly {
            try legacyVault.deleteAuthBlob(profileID: "profile-1")
        }
    }
}

private func expectLegacyVaultIsReadOnly(_ body: () throws -> Void) throws {
    do {
        try body()
    } catch KeychainAuthVaultError.legacyVaultIsReadOnly {
        return
    } catch {
        try fail("Expected legacyVaultIsReadOnly, got \(error)")
    }
    try fail("Expected legacyVaultIsReadOnly, but no error was thrown")
}
