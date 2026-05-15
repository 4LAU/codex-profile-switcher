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

private struct AvailabilityAuthVault: AuthVault {
    var availability: AuthBlobAvailability

    func listProfileIDs() throws -> [String] { [] }
    func loadAuthBlob(profileID: String) throws -> Data? { nil }
    func saveAuthBlob(_ data: Data, profileID: String) throws {}
    func deleteAuthBlob(profileID: String) throws {}
    func hasAuthBlob(profileID: String) throws -> Bool { self.availability == .present }
    func authBlobAvailability(profileID: String) throws -> AuthBlobAvailability { self.availability }
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
    @Test
    func testNeedsMigrationAuthIsNotTreatedAsActivatable() throws {
        let workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-profile-store-availability-tests-\(UUID().uuidString)", isDirectory: true)
        let home = workDir.appendingPathComponent("home", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: workDir) }

        let store = ProfileStore(
            authVault: AvailabilityAuthVault(availability: .needsMigration),
            environment: ["CODEX_PROFILE_HOME": home.path])

        try envExpect(
            !store.authCanBeActivated(for: "1"),
            "Needs-migration auth was incorrectly treated as ready to activate")
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
}
