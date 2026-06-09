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

}
