@testable import CodexProfileCore
@testable import CodexProfileSwitcherApp
import Foundation
import CryptoKit
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
    func _saveAuthBlobUnlocked(_ data: Data, profileID: String) throws {
        throw ProfileStoreEnvironmentTestFailure.failed("intentional save failure")
    }
    func _deleteAuthBlobUnlocked(profileID: String) throws {}
    func hasAuthBlob(profileID: String) throws -> Bool { false }
}

private final class MigrationTestVault: AuthVault, KeychainMigrationDestination, @unchecked Sendable {
    private(set) var blobs: [String: Data]
    private(set) var createCount = 0
    private(set) var deleteCount = 0

    init(blobs: [String: Data] = [:]) {
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
        self.deleteCount += 1
        self.blobs.removeValue(forKey: profileID)
    }

    func hasAuthBlob(profileID: String) throws -> Bool {
        self.blobs[profileID] != nil
    }

    func diagnostics() -> AuthVaultDiagnostics {
        AuthVaultDiagnostics(activeBackend: .dataProtectionKeychain)
    }

    func createAuthBlobIfAbsentForMigration(
        _ data: Data,
        profileID: String
    ) throws -> KeychainMigrationCreateResult {
        self.createCount += 1
        guard self.blobs[profileID] == nil else {
            return .alreadyExists
        }
        self.blobs[profileID] = data
        return .created
    }

    func _createAuthBlobIfAbsentForMigrationUnlocked(
        _ data: Data,
        profileID: String
    ) throws -> KeychainMigrationCreateResult {
        try self.createAuthBlobIfAbsentForMigration(data, profileID: profileID)
    }
}

private final class MigrationTestSource {
    var captures: [LegacyKeychainAuthBlobCapture]
    var shouldFailDelete = false
    private(set) var captureCount = 0
    private(set) var deleteCount = 0

    init(captures: [LegacyKeychainAuthBlobCapture]) {
        self.captures = captures
    }

    func capture() throws -> [LegacyKeychainAuthBlobCapture] {
        self.captureCount += 1
        return self.captures
    }

    func delete(_ capture: LegacyKeychainAuthBlobCapture) throws {
        self.deleteCount += 1
        guard !self.shouldFailDelete else {
            throw ProfileStoreEnvironmentTestFailure.failed("intentional cleanup failure")
        }
        self.captures.removeAll { $0.persistentReference == capture.persistentReference }
    }
}

private final class MigrationFactoryCounter {
    private(set) var invocationCount = 0

    func recordInvocation() {
        self.invocationCount += 1
    }
}

private func migrationCoordinatorFactory(
    source: MigrationTestSource,
    counter: MigrationFactoryCounter
) -> ProfileStore.KeychainMigrationCoordinatorFactory {
    { vault, profiles, states, pendingFingerprints, checkpoint in
        counter.recordInvocation()
        guard let destination = vault as? MigrationTestVault else {
            throw KeychainMigrationError.destinationUnavailable
        }
        return KeychainMigrationCoordinator(
            captureLegacyRecords: { try source.capture() },
            deleteLegacyRecord: { capture in try source.delete(capture) },
            destination: destination,
            profiles: profiles,
            migrationStates: states,
            pendingFingerprints: pendingFingerprints,
            checkpoint: checkpoint)
    }
}

private func migrationCapture(profileID: String, data: Data) -> LegacyKeychainAuthBlobCapture {
    LegacyKeychainAuthBlobCapture(
        profileID: profileID,
        authBlob: data,
        persistentReference: Data("persistent-reference-\(profileID)".utf8),
        service: LegacyKeychainAuthVault.defaultService)
}

private func expectMigrationError(
    _ expected: KeychainMigrationError,
    _ operation: () throws -> Void
) throws {
    do {
        try operation()
    } catch let error as KeychainMigrationError {
        try envExpect(error == expected, "Expected \(expected), got \(error)")
        return
    }
    try envFail("Expected migration error \(expected)")
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
            authVault: FileAuthVault(
                root: vaultRoot,
                authLockURL: AppPaths(environment: ["CODEX_PROFILE_HOME": home.path]).authLockURL),
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
        let vault = FileAuthVault(
            root: vaultRoot,
            authLockURL: AppPaths(environment: ["CODEX_PROFILE_HOME": home.path]).authLockURL)
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

    @Test @MainActor
    func testNormalProfileStorePathsNeverInvokeMigrationFactory() throws {
        let workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-profile-store-migration-boundary-tests-\(UUID().uuidString)", isDirectory: true)
        let home = workDir.appendingPathComponent("home", isDirectory: true)
        let auth = Data(#"{"OPENAI_API_KEY":"sk-test-normal-path-1111111111"}"#.utf8)
        defer { try? FileManager.default.removeItem(at: workDir) }

        let vault = MigrationTestVault(blobs: ["1": auth])
        let source = MigrationTestSource(captures: [migrationCapture(profileID: "1", data: auth)])
        let counter = MigrationFactoryCounter()
        let store = ProfileStore(
            authVault: vault,
            environment: ["CODEX_PROFILE_HOME": home.path],
            keychainMigrationCoordinatorFactory: migrationCoordinatorFactory(source: source, counter: counter))

        _ = store.debugSummaryLines()
        _ = store.usageAuthSource()
        _ = try store.prepareProfileSwitch(to: "1", isCodexDesktopRunning: { false })

        try envExpect(counter.invocationCount == 0, "A normal ProfileStore path invoked migration review")
        try envExpect(source.captureCount == 0, "A normal ProfileStore path read a legacy migration source")
        try envExpect(source.deleteCount == 0, "A normal ProfileStore path deleted a legacy migration source")
    }

    @Test @MainActor
    func testForcedUsageRefreshNeverInvokesMigrationFactory() async throws {
        let workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-profile-store-migration-usage-tests-\(UUID().uuidString)", isDirectory: true)
        let home = workDir.appendingPathComponent("home", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: workDir) }

        let vault = MigrationTestVault()
        let source = MigrationTestSource(captures: [])
        let counter = MigrationFactoryCounter()
        let store = ProfileStore(
            authVault: vault,
            environment: ["CODEX_PROFILE_HOME": home.path],
            keychainMigrationCoordinatorFactory: migrationCoordinatorFactory(source: source, counter: counter))
        let provider = UsageProvider(store: store)

        await withCheckedContinuation { continuation in
            provider.onRefreshComplete = { continuation.resume() }
            provider.refreshAll(force: true)
        }

        try envExpect(counter.invocationCount == 0, "Forced usage refresh invoked migration review")
        try envExpect(source.captureCount == 0, "Forced usage refresh read a legacy migration source")
        try envExpect(source.deleteCount == 0, "Forced usage refresh deleted a legacy migration source")
    }

    @Test @MainActor
    func testReviewRequiresInjectedFactoryForCustomDataProtectionVault() throws {
        let workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-profile-store-migration-default-tests-\(UUID().uuidString)", isDirectory: true)
        let home = workDir.appendingPathComponent("home", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: workDir) }

        let store = ProfileStore(
            authVault: MigrationTestVault(),
            environment: ["CODEX_PROFILE_HOME": home.path])

        try expectMigrationError(.destinationUnavailable) {
            _ = try store.reviewLegacyKeychainMigration()
        }
    }

    @Test @MainActor
    func testReviewDoesNotDeleteBeforeConfirmationAndCancelDiscardsSession() throws {
        let workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-profile-store-migration-review-tests-\(UUID().uuidString)", isDirectory: true)
        let home = workDir.appendingPathComponent("home", isDirectory: true)
        let auth = Data(#"{"OPENAI_API_KEY":"sk-test-review-1111111111"}"#.utf8)
        defer { try? FileManager.default.removeItem(at: workDir) }

        let vault = MigrationTestVault()
        let source = MigrationTestSource(captures: [migrationCapture(profileID: "1", data: auth)])
        let counter = MigrationFactoryCounter()
        let store = ProfileStore(
            authVault: vault,
            environment: ["CODEX_PROFILE_HOME": home.path],
            keychainMigrationCoordinatorFactory: migrationCoordinatorFactory(source: source, counter: counter))

        let preview = try store.reviewLegacyKeychainMigration()

        try envExpect(counter.invocationCount == 1, "Explicit review did not construct a migration coordinator")
        try envExpect(source.captureCount == 1, "Explicit review did not capture the migration source")
        try envExpect(source.deleteCount == 0, "Review deleted a legacy copy before confirmation")
        try envExpect(vault.createCount == 0, "Review wrote a Data Protection copy before confirmation")
        try envExpect(preview.candidateCount == 1, "Review did not expose the legacy candidate")

        store.cancelLegacyKeychainMigrationReview(preview)
        try expectMigrationError(.staleOrConsumedPreview) {
            try store.confirmLegacyKeychainMigration(preview, approvedCount: 1)
        }
        try envExpect(source.deleteCount == 0, "Cancel deleted a legacy copy")
    }

    @Test @MainActor
    func testMismatchedMigrationConfirmationDoesNotMutateEitherVault() throws {
        let workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-profile-store-migration-count-tests-\(UUID().uuidString)", isDirectory: true)
        let home = workDir.appendingPathComponent("home", isDirectory: true)
        let auth = Data(#"{"OPENAI_API_KEY":"sk-test-count-1111111111"}"#.utf8)
        defer { try? FileManager.default.removeItem(at: workDir) }

        let vault = MigrationTestVault()
        let source = MigrationTestSource(captures: [migrationCapture(profileID: "1", data: auth)])
        let store = ProfileStore(
            authVault: vault,
            environment: ["CODEX_PROFILE_HOME": home.path],
            keychainMigrationCoordinatorFactory: migrationCoordinatorFactory(
                source: source,
                counter: MigrationFactoryCounter()))
        let preview = try store.reviewLegacyKeychainMigration()

        try expectMigrationError(.candidateCountMismatch) {
            try store.confirmLegacyKeychainMigration(preview, approvedCount: 2)
        }

        try envExpect(source.deleteCount == 0, "Mismatched approval deleted a legacy copy")
        try envExpect(vault.createCount == 0, "Mismatched approval wrote a Data Protection copy")
        let destinationData = try vault.loadAuthBlob(profileID: "1")
        try envExpect(destinationData == nil, "Mismatched approval changed destination auth")
    }

    @Test @MainActor
    func testCleanupFailureKeepsDurablePendingState() throws {
        let workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-profile-store-migration-cleanup-tests-\(UUID().uuidString)", isDirectory: true)
        let home = workDir.appendingPathComponent("home", isDirectory: true)
        let auth = Data(#"{"OPENAI_API_KEY":"sk-test-cleanup-1111111111"}"#.utf8)
        defer { try? FileManager.default.removeItem(at: workDir) }

        let vault = MigrationTestVault()
        let source = MigrationTestSource(captures: [migrationCapture(profileID: "1", data: auth)])
        source.shouldFailDelete = true
        let store = ProfileStore(
            authVault: vault,
            environment: ["CODEX_PROFILE_HOME": home.path],
            keychainMigrationCoordinatorFactory: migrationCoordinatorFactory(
                source: source,
                counter: MigrationFactoryCounter()))
        let preview = try store.reviewLegacyKeychainMigration()

        try expectMigrationError(.legacyCleanupFailed) {
            try store.confirmLegacyKeychainMigration(preview, approvedCount: 1)
        }

        let configURL = home.appendingPathComponent(".codex-switcher/config.json")
        let config = try JSONDecoder().decode(AppConfig.self, from: Data(contentsOf: configURL))
        let destinationData = try vault.loadAuthBlob(profileID: "1")
        try envExpect(source.deleteCount == 1, "Confirmed migration did not attempt legacy cleanup")
        try envExpect(destinationData == auth, "Cleanup failure lost the verified destination copy")
        try envExpect(
            config.authMigrationStates?["1"] == .copiedCleanupPending,
            "Cleanup failure did not persist the pending migration checkpoint")
    }

    @Test @MainActor
    func testPendingOnlyCompletionRequiresTheRecordedCopiedCredential() throws {
        let workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-profile-store-migration-pending-tests-\(UUID().uuidString)", isDirectory: true)
        let home = workDir.appendingPathComponent("home", isDirectory: true)
        let switcherHome = home.appendingPathComponent(".codex-switcher", isDirectory: true)
        let auth = Data(#"{"OPENAI_API_KEY":"sk-test-pending-1111111111"}"#.utf8)
        defer { try? FileManager.default.removeItem(at: workDir) }

        try FileManager.default.createDirectory(
            at: switcherHome,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let initialConfig = AppConfig(
            profiles: [ProfileConfig(id: "1", label: "Saved account")],
            activeProfile: "1",
            authMigrationStates: ["1": .copiedCleanupPending])
        try JSONEncoder().encode(initialConfig).write(to: switcherHome.appendingPathComponent("config.json"))

        let vault = MigrationTestVault(blobs: ["1": auth])
        let source = MigrationTestSource(captures: [])
        let legacyPendingStore = ProfileStore(
            authVault: vault,
            environment: ["CODEX_PROFILE_HOME": home.path],
            keychainMigrationCoordinatorFactory: migrationCoordinatorFactory(
                source: source,
                counter: MigrationFactoryCounter()))
        let legacyPreview = try legacyPendingStore.reviewLegacyKeychainMigration()

        try envExpect(legacyPreview.candidateCount == 0, "Pending-only review exposed a destructive candidate")
        try envExpect(legacyPreview.pendingCompletionCount == 0,
                      "Legacy pending state without provenance was accepted")
        legacyPendingStore.cancelLegacyKeychainMigrationReview(legacyPreview)

        var config = try JSONDecoder().decode(
            AppConfig.self,
            from: Data(contentsOf: switcherHome.appendingPathComponent("config.json")))
        try envExpect(config.authMigrationStates?["1"] == .copiedCleanupPending,
                      "Legacy pending state was deleted instead of preserved for re-review")

        config.authMigrationPendingFingerprints = [
            "1": SHA256.hash(data: auth).map { String(format: "%02x", $0) }.joined(),
        ]
        try JSONEncoder().encode(config).write(to: switcherHome.appendingPathComponent("config.json"))

        let replacement = Data(#"{"tokens":{"access_token":"replacement-access","refresh_token":"replacement-refresh"}}"#.utf8)
        try vault.saveAuthBlob(replacement, profileID: "1")
        let replacementStore = ProfileStore(
            authVault: vault,
            environment: ["CODEX_PROFILE_HOME": home.path],
            keychainMigrationCoordinatorFactory: migrationCoordinatorFactory(
                source: source,
                counter: MigrationFactoryCounter()))
        // A destination copy that no longer matches its checkpoint is expected once a
        // credential renewal legitimately rewrites the item, so review no longer aborts.
        // The profile is excluded from completion and reported instead, which preserves
        // the property this test is named for: completion still requires the recorded copy.
        let replacementPreview = try replacementStore.reviewLegacyKeychainMigration()
        try envExpect(replacementPreview.pendingCompletionCount == 0,
                      "A changed destination copy was offered for completion")
        try envExpect(
            replacementPreview.pendingCompletionVerificationFailures["1"] == .stalePendingCompletionCheckpoint,
            "A changed destination copy was dropped without being reported")
        replacementStore.cancelLegacyKeychainMigrationReview(replacementPreview)

        try vault.saveAuthBlob(auth, profileID: "1")
        let store = ProfileStore(
            authVault: vault,
            environment: ["CODEX_PROFILE_HOME": home.path],
            keychainMigrationCoordinatorFactory: migrationCoordinatorFactory(
                source: source,
                counter: MigrationFactoryCounter()))
        let preview = try store.reviewLegacyKeychainMigration()
        try envExpect(preview.pendingCompletionCount == 1,
                      "Recorded pending copy was not available for completion")
        try store.completePendingKeychainMigration(preview, approvedCount: 1)

        config = try JSONDecoder().decode(
            AppConfig.self,
            from: Data(contentsOf: switcherHome.appendingPathComponent("config.json")))
        let destinationData = try vault.loadAuthBlob(profileID: "1")
        try envExpect(source.deleteCount == 0, "Pending-only completion deleted a legacy copy")
        try envExpect(destinationData == auth, "Pending-only completion changed destination auth")
        try envExpect(config.authMigrationStates?["1"] == .complete, "Pending-only completion did not checkpoint complete")
        try envExpect(config.authMigrationPendingFingerprints == nil,
                      "Completed migration retained its pending credential fingerprint")
    }

}
