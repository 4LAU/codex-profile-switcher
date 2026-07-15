@testable import CodexProfileCore
@testable import CodexProfileSwitcherApp
import Foundation
import Testing

enum ProfileStoreEnvironmentTestFailure: Error, CustomStringConvertible {
    case failed(String)

    var description: String {
        switch self {
        case .failed(let message): return message
        }
    }
}

private struct FailingSaveAuthVault: AuthVault {
    func listProfileIDs() throws -> [String] { [] }
    func loadAuthBlob(profileID: String) throws -> Data? { nil }
    func saveAuthBlob(_ data: Data, profileID: String) throws {
        throw ProfileStoreEnvironmentTestFailure.failed("intentional save failure")
    }
    func deleteAuthBlob(profileID: String) throws {}
    func hasAuthBlob(profileID: String) throws -> Bool { false }
}

func envFail(_ message: String) throws -> Never {
    throw ProfileStoreEnvironmentTestFailure.failed(message)
}

func envExpect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() {
        try envFail(message)
    }
}

final class ProfileStoreEnvironmentTests {
    @Test @MainActor
    func testUnentitledAppRoutesToFileVault() throws {
        try envExpect(
            !ProcessSigningIdentity.hasDataProtectionKeychainAccess,
            "This hermetic test requires an unentitled test process")

        let workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-profile-store-file-vault-routing-tests-\(UUID().uuidString)", isDirectory: true)
        let home = workDir.appendingPathComponent("home", isDirectory: true)
        let expectedAuth = Data(#"{"OPENAI_API_KEY":"sk-test-app-routing-1111111111"}"#.utf8)
        let fileVaultAuth = home
            .appendingPathComponent(".codex-switcher/dev-auth-store", isDirectory: true)
            .appendingPathComponent("1.json")
        defer { try? FileManager.default.removeItem(at: workDir) }

        let store = ProfileStore(
            authVault: nil,
            environment: ["CODEX_PROFILE_HOME": home.path])

        try store.saveAuthDataToVault(expectedAuth, for: "1")
        let summary = store.debugSummaryLines()
        let savedAuth = try Data(contentsOf: fileVaultAuth)
        try envExpect(
            summary.contains("auth_storage_backend: file"),
            "An unentitled app did not select the file vault")
        try envExpect(
            savedAuth == expectedAuth,
            "An unentitled app did not save auth to its file vault")
    }

    @Test @MainActor
    func testDoesNotMarkAccessRepairCompleteAfterFailedLegacyMigration() throws {
        let workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-profile-store-migration-tests-\(UUID().uuidString)", isDirectory: true)
        let home = workDir.appendingPathComponent("home", isDirectory: true)
        let legacyAuthDir = home.appendingPathComponent(".codex-switcher/auth", isDirectory: true)
        let legacyAuth = legacyAuthDir.appendingPathComponent("LegacyProfile.json")
        defer { try? FileManager.default.removeItem(at: workDir) }

        try FileManager.default.createDirectory(
            at: legacyAuthDir,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        try Data(#"{"OPENAI_API_KEY":"sk-test-legacy-profile-1111111111"}"#.utf8)
            .write(to: legacyAuth)

        _ = ProfileStore(
            authVault: FailingSaveAuthVault(),
            environment: ["CODEX_PROFILE_HOME": home.path])

        let configURL = home.appendingPathComponent(".codex-switcher/config.json")
        let data = try Data(contentsOf: configURL)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let version = json?["authStorageVersion"] as? Int

        try envExpect(version == nil || version == 0, "Failed legacy migration was incorrectly marked as access-repaired")
        try envExpect(
            FileManager.default.fileExists(atPath: legacyAuth.path),
            "Failed legacy migration removed the legacy auth file")
    }

    @Test @MainActor
    func testFileDevVaultDoesNotAdvanceKeychainVersionOrDeleteLegacy() throws {
        // An unsigned dev build uses a file vault. It must never perform the
        // Keychain-specific bookkeeping that lives in the shared config.json:
        // advancing authStorageVersion, deleting the legacy store, or migrating
        // legacy auth into itself. Otherwise a later signed Keychain build sees
        // the advanced version, skips its real migration, and finds nothing.
        let workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-profile-store-devvault-tests-\(UUID().uuidString)", isDirectory: true)
        let home = workDir.appendingPathComponent("home", isDirectory: true)
        let legacyAuthDir = home.appendingPathComponent(".codex-switcher/auth", isDirectory: true)
        let legacyAuth = legacyAuthDir.appendingPathComponent("LegacyProfile.json")
        let vaultRoot = workDir.appendingPathComponent("dev-auth-store", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: workDir) }

        try FileManager.default.createDirectory(
            at: legacyAuthDir,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        try Data(#"{"OPENAI_API_KEY":"sk-test-legacy-devvault-1111111111"}"#.utf8)
            .write(to: legacyAuth)

        // A file-backed vault stands in for the unsigned dev build's file vault.
        _ = ProfileStore(
            authVault: FileAuthVault(root: vaultRoot),
            environment: ["CODEX_PROFILE_HOME": home.path])

        let configURL = home.appendingPathComponent(".codex-switcher/config.json")
        let data = try Data(contentsOf: configURL)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let version = json?["authStorageVersion"] as? Int

        try envExpect(
            version == nil || version == 0,
            "File dev vault advanced the shared Keychain auth-storage version")
        try envExpect(
            FileManager.default.fileExists(atPath: legacyAuth.path),
            "File dev vault deleted the legacy auth store a signed build still needs")
        try envExpect(
            !FileManager.default.fileExists(
                atPath: vaultRoot.appendingPathComponent("LegacyProfile.json").path),
            "File dev vault migrated legacy auth into itself")
    }

    @Test @MainActor
    func testClearSavedAuthRemovesExhaustionOverrideFromDisk() throws {
        let workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-profile-store-override-tests-\(UUID().uuidString)", isDirectory: true)
        let home = workDir.appendingPathComponent("home", isDirectory: true)
        let switcherHome = home.appendingPathComponent(".codex-switcher", isDirectory: true)
        let vaultRoot = workDir.appendingPathComponent("vault", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: workDir) }

        try FileManager.default.createDirectory(
            at: switcherHome, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])

        // Two profiles with saved auth so both are discovered. Profile "1" is the
        // default active (live) profile; we clear non-live profile "2".
        let vault = FileAuthVault(root: vaultRoot)
        try vault.saveAuthBlob(Data(#"{"OPENAI_API_KEY":"sk-test-profile-1-1111111111"}"#.utf8), profileID: "1")
        try vault.saveAuthBlob(Data(#"{"OPENAI_API_KEY":"sk-test-profile-2-2222222222"}"#.utf8), profileID: "2")

        // Seed a cache file with an exhaustion override for BOTH profiles.
        let cacheJSON = """
        {
          "snapshots": {},
          "exhaustionOverrides": {
            "1": { "blockedUntil": "2999-01-01T00:00:00Z", "reason": "limit", "source": "cli" },
            "2": { "blockedUntil": "2999-01-01T00:00:00Z", "reason": "limit", "source": "cli" }
          }
        }
        """
        let cacheURL = switcherHome.appendingPathComponent("cache.json")
        try Data(cacheJSON.utf8).write(to: cacheURL)

        let store = ProfileStore(
            authVault: vault,
            environment: ["CODEX_PROFILE_HOME": home.path])

        // Sanity: both overrides present in memory after init.
        try envExpect(store.cache.exhaustionOverrides["1"] != nil, "Override for profile 1 missing after init")
        try envExpect(store.cache.exhaustionOverrides["2"] != nil, "Override for profile 2 missing after init")

        try store.clearSavedAuth(for: "2")

        // Re-read the cache FILE (not in-memory state).
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let diskData = try Data(contentsOf: cacheURL)
        let diskCache = try decoder.decode(UsageCache.self, from: diskData)

        try envExpect(
            diskCache.exhaustionOverrides["2"] == nil,
            "clearSavedAuth did not remove profile 2's exhaustion override from disk")
        try envExpect(
            diskCache.exhaustionOverrides["1"] != nil,
            "clearSavedAuth incorrectly removed another profile's exhaustion override from disk")
    }

}
