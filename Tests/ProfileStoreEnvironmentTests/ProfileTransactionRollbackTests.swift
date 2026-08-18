@testable import CodexProfileCore
import Foundation
import Testing

// Test helper: mutated only from single-threaded test bodies, never shared
// across tasks, so unchecked Sendable is safe here.
private final class RollbackAuthVault: AuthVault, @unchecked Sendable {
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

    func _saveAuthBlobUnlocked(_ data: Data, profileID: String) throws {
        self.blobs[profileID] = data
    }

    func _deleteAuthBlobUnlocked(profileID: String) throws {
        self.blobs.removeValue(forKey: profileID)
    }

    func hasAuthBlob(profileID: String) throws -> Bool {
        self.blobs[profileID] != nil
    }
}

/// Fails atomic writes whose destination matches a substring, leaving reads and
/// directory operations intact so snapshot capture still works.
private final class ConfigWriteFailingFileManager: FileManager {
    let failPathSubstring: String

    init(failPathSubstring: String) {
        self.failPathSubstring = failPathSubstring
        super.init()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func matches(_ path: String) -> Bool {
        (path as NSString).lastPathComponent.contains(self.failPathSubstring)
    }

    // Report the config file as absent so `AtomicFileWriter` takes the
    // `moveItem` branch (which we can override) rather than the non-overridable
    // `replaceItemAt`. Snapshot capture treats it as absent (nil data), which is
    // irrelevant to this test's vault-rollback assertion.
    override func fileExists(atPath path: String) -> Bool {
        if self.matches(path) {
            return false
        }
        return super.fileExists(atPath: path)
    }

    override func moveItem(at srcURL: URL, to dstURL: URL) throws {
        if self.matches(dstURL.path) {
            throw CocoaError(.fileWriteUnknown)
        }
        try super.moveItem(at: srcURL, to: dstURL)
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
    func rollbackRestoresOutgoingVaultBlobAfterWriteFailure() throws {
        let fixture = try self.makeFixture("rollback-vault-restore")
        defer { self.removeFixture(fixture) }

        // Outgoing "Active" profile: its saved vault blob differs from the live
        // auth on disk, so commit will overwrite the vault entry with live data.
        let savedActive = authData("active-1111111111111111", marker: "saved")
        let liveActive = authData("active-1111111111111111", marker: "live")
        let targetData = authData("target-2222222222222222")
        try liveActive.write(to: fixture.paths.liveAuthURL)
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

        // Inject a FileManager that fails the config write specifically, so the
        // live-auth write and snapshot capture succeed but the second step fails,
        // exercising the vault rollback after the outgoing blob was overwritten.
        let failingFileManager = ConfigWriteFailingFileManager(failPathSubstring: "config.json")
        let transaction = try ProfileTransactionService(
            vault: vault,
            paths: fixture.paths,
            fileManager: failingFileManager
        ).prepareSwitch(to: "Target")

        do {
            _ = try transaction.commit()
            try envFail("Expected commit to fail on config write")
        } catch is ProfileSwitchCommitError {
            // Expected: write failed after the outgoing vault blob was overwritten.
        }

        // The outgoing profile's vault entry must be restored to its pre-save value.
        #expect(vault.blobs["Active"] == savedActive)
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
