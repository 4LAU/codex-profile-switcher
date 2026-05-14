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

func envExpectEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: String) throws {
    if actual != expected {
        try envFail("\(message) (expected \(expected), got \(actual))")
    }
}

final class ProfileStoreEnvironmentTests {
    
    
    @Test
    
    
    func testUsesAppEnvironmentOverrides() throws {
        let workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-profile-store-env-tests-\(UUID().uuidString)", isDirectory: true)
        let home = workDir.appendingPathComponent("home", isDirectory: true)
        let authRoot = workDir.appendingPathComponent("auth", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: workDir) }

        let environment = [
            "CODEX_PROFILE_HOME": home.path,
            "CODEX_PROFILE_KEYCHAIN_SERVICE": "com.example.codex-profile-test",
        ]

        try envExpectEqual(
            ProfileStore.userHome(environment: environment).path,
            home.standardizedFileURL.path,
            "ProfileStore did not resolve CODEX_PROFILE_HOME")
        try envExpectEqual(
            ProfileStore.keychainService(environment: environment),
            "com.example.codex-profile-test",
            "ProfileStore did not resolve CODEX_PROFILE_KEYCHAIN_SERVICE")

        let store = ProfileStore(
            authVault: FileAuthVault(root: authRoot),
            environment: environment)
        let configPath = home.appendingPathComponent(".codex-switcher/config.json").path
        let codexHomePath = home.appendingPathComponent(".codex", isDirectory: true).path

        try envExpect(
            FileManager.default.fileExists(atPath: configPath),
            "ProfileStore did not create config under CODEX_PROFILE_HOME")
        try envExpect(
            store.debugSummaryLines().contains("codex_home: \(codexHomePath)"),
            "Debug summary did not report CODEX_PROFILE_HOME codex path")
    }

    
    
    @Test

    
    
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

    
    
    @Test

    
    
    func testRefusesToRemoveActiveProfile() throws {
        let workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-profile-store-remove-tests-\(UUID().uuidString)", isDirectory: true)
        let home = workDir.appendingPathComponent("home", isDirectory: true)
        let authRoot = workDir.appendingPathComponent("auth", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: workDir) }

        let store = ProfileStore(
            authVault: FileAuthVault(root: authRoot),
            environment: ["CODEX_PROFILE_HOME": home.path])
        try store.saveAuthDataToVault(Data(#"{"OPENAI_API_KEY":"sk-test-active-profile-1111111111"}"#.utf8), for: "1")
        store.setLiveProfileId("1")

        do {
            try store.removeProfile("1")
        } catch ProfileMutationError.cannotRemoveActiveProfile {
            try envExpect(store.authStoreExists(for: "1"), "Active profile auth was deleted")
            try envExpect(
                store.config.profiles.contains(where: { $0.id == "1" }),
                "Active profile config was removed")
            return
        } catch {
            try envFail("Expected cannotRemoveActiveProfile, got \(error)")
        }

        try envFail("Removing the active profile unexpectedly succeeded")
    }

    @Test
    func testPreparesSharedProfileSwitchTransaction() throws {
        let workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-profile-store-switch-tests-\(UUID().uuidString)", isDirectory: true)
        let home = workDir.appendingPathComponent("home", isDirectory: true)
        let authRoot = workDir.appendingPathComponent("auth", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: workDir) }

        let store = ProfileStore(
            authVault: FileAuthVault(root: authRoot),
            environment: ["CODEX_PROFILE_HOME": home.path])
        let firstAuth = Data(#"{"OPENAI_API_KEY":"sk-test-switch-first-1111111111"}"#.utf8)
        let secondAuth = Data(#"{"OPENAI_API_KEY":"sk-test-switch-second-2222222222"}"#.utf8)
        try store.saveAuthDataToVault(firstAuth, for: "1")
        try store.saveAuthDataToVault(secondAuth, for: "2")
        store.setActiveProfile("1")

        let liveAuthURL = home.appendingPathComponent(".codex/auth.json")
        try FileManager.default.createDirectory(
            at: liveAuthURL.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        try firstAuth.write(to: liveAuthURL)

        let transaction = try store.prepareProfileSwitch(to: "2", isCodexDesktopRunning: { false })
        try transaction.commit()

        try envExpectEqual(
            try Data(contentsOf: liveAuthURL),
            secondAuth,
            "Prepared switch did not restore target auth to live auth")
        try envExpectEqual(
            try FileAuthVault(root: authRoot).loadAuthBlob(profileID: "1"),
            firstAuth,
            "Prepared switch did not preserve outgoing active auth")

        let configURL = home.appendingPathComponent(".codex-switcher/config.json")
        let config = try JSONDecoder().decode(AppConfig.self, from: Data(contentsOf: configURL))
        try envExpectEqual(config.activeProfile, "2", "Prepared switch did not persist active profile")
    }
}
