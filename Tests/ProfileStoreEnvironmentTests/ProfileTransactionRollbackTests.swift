@testable import CodexProfileCore
import Foundation
import Testing

private final class RollbackAuthVault: AuthVault {
    var blobs: [String: Data]

    init(blobs: [String: Data]) {
        self.blobs = blobs
    }

    func listProfileIDs() throws -> [String] {
        self.blobs.keys.sorted()
    }

    func loadAuthBlob(profileID: String) throws -> Data? {
        self.blobs[profileID]
    }

    func saveAuthBlob(_ data: Data, profileID: String) throws {
        self.blobs[profileID] = data
    }

    func deleteAuthBlob(profileID: String) throws {
        self.blobs.removeValue(forKey: profileID)
    }

    func hasAuthBlob(profileID: String) throws -> Bool {
        self.blobs[profileID] != nil
    }
}

final class ProfileTransactionRollbackTests {
    private let fileManager = FileManager.default

    @Test
    func sameProfileLaunchPreservesNewerLiveAuthWhenCodexIsStopped() throws {
        let fixture = try self.makeFixture("same-profile-launch")
        defer { self.removeFixture(fixture) }

        let savedActive = authData("same-profile-5555555555555555", marker: "saved")
        let liveActive = authData("same-profile-5555555555555555", marker: "live")
        try liveActive.write(to: fixture.paths.liveAuthURL)
        try self.writeConfig(
            AppConfig(
                profiles: [ProfileConfig(id: "Active", label: "Active")],
                activeProfile: "Active",
                authStorageVersion: 7),
            to: fixture.paths.configURL)
        let vault = RollbackAuthVault(blobs: ["Active": savedActive])

        let transaction = try ProfileTransactionService(
            vault: vault,
            paths: fixture.paths,
            isCodexDesktopRunning: { false }
        ).prepareSwitch(to: "Active")
        #expect(!transaction.alreadyActive)

        _ = try transaction.commit()

        #expect(try Data(contentsOf: fixture.paths.liveAuthURL) == liveActive)
        #expect(vault.blobs["Active"] == liveActive)
    }

    @Test
    func refusesToClassifyActiveProfileWhenFingerprintsAreMissing() throws {
        let fixture = try self.makeFixture("missing-fingerprint-live")
        defer { self.removeFixture(fixture) }

        let savedActive = oauthWithoutStableIdentity(accessToken: "saved-access", refreshToken: "saved-refresh")
        let liveUnknown = oauthWithoutStableIdentity(accessToken: "live-access", refreshToken: "live-refresh")
        let targetData = authData("target-6666666666666666")
        try liveUnknown.write(to: fixture.paths.liveAuthURL)
        try self.writeConfig(
            AppConfig(
                profiles: [
                    ProfileConfig(id: "Active", label: "Active"),
                    ProfileConfig(id: "Target", label: "Target"),
                ],
                activeProfile: "Active",
                authStorageVersion: 7),
            to: fixture.paths.configURL)
        let vault = RollbackAuthVault(blobs: ["Active": savedActive, "Target": targetData])

        do {
            _ = try ProfileTransactionService(
                vault: vault,
                paths: fixture.paths
            ).prepareSwitch(to: "Target")
        } catch ProfileTransactionError.unmanagedLiveAuth {
            return
        } catch {
            try envFail("Expected unmanagedLiveAuth, got \(error)")
        }

        try envFail("Missing fingerprints incorrectly classified live auth as active")
    }

    @discardableResult
    private func writeConfig(_ config: AppConfig, to url: URL) throws -> Data {
        let data = try JSONEncoder.codexProfilePrettySorted.encode(config)
        try data.write(to: url)
        return data
    }

    private func makeFixture(_ name: String) throws -> (root: URL, paths: AppPaths) {
        let root = self.fileManager.temporaryDirectory
            .appendingPathComponent("codex-profile-rollback-\(name)-\(UUID().uuidString)", isDirectory: true)
        let home = root.appendingPathComponent("home", isDirectory: true)
        let paths = AppPaths(environment: ["CODEX_PROFILE_HOME": home.path])
        try self.fileManager.createDirectory(
            at: paths.liveCodexHome,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        try self.fileManager.createDirectory(
            at: paths.switcherHome,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        return (root, paths)
    }

    private func removeFixture(_ fixture: (root: URL, paths: AppPaths)) {
        try? self.fileManager.removeItem(at: fixture.root)
    }
}

private func authData(_ keySuffix: String, marker: String? = nil) -> Data {
    if let marker {
        return Data(#"{"OPENAI_API_KEY":"sk-test-\#(keySuffix)","marker":"\#(marker)"}"#.utf8)
    }
    return Data(#"{"OPENAI_API_KEY":"sk-test-\#(keySuffix)"}"#.utf8)
}

private func oauthWithoutStableIdentity(accessToken: String, refreshToken: String) -> Data {
    Data(#"{"tokens":{"access_token":"\#(accessToken)","refresh_token":"\#(refreshToken)"}}"#.utf8)
}
