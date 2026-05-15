@testable import CodexProfileCore
import Foundation
import Testing

private final class RecordingAuthVault: AuthVault {
    var blobs: [String: Data]
    var loadCount = 0
    var deleteCount = 0
    var hasCount = 0

    init(blobs: [String: Data] = [:]) {
        self.blobs = blobs
    }

    func listProfileIDs() throws -> [String] {
        return self.blobs.keys.sorted()
    }

    func loadAuthBlob(profileID: String) throws -> Data? {
        self.loadCount += 1
        return self.blobs[profileID]
    }

    func saveAuthBlob(_ data: Data, profileID: String) throws {
        self.blobs[profileID] = data
    }

    func deleteAuthBlob(profileID: String) throws {
        self.deleteCount += 1
        self.blobs.removeValue(forKey: profileID)
    }

    func hasAuthBlob(profileID: String) throws -> Bool {
        self.hasCount += 1
        return self.blobs[profileID] != nil
    }
}

final class MigratingAuthVaultTests {
    @Test
    func activationMigratesLegacyBlobAfterVerifiedDataProtectionWrite() throws {
        let legacyData = Data("legacy-auth".utf8)
        let dataProtection = RecordingAuthVault()
        let legacy = RecordingAuthVault(blobs: ["Work": legacyData])
        let vault = MigratingAuthVault(
            dataProtection: dataProtection,
            legacy: legacy,
            accessGroup: "TEAM.example",
            probeResult: .succeeded)

        #expect(try vault.loadAuthBlobForActivation(profileID: "Work") == legacyData)
        #expect(dataProtection.blobs["Work"] == legacyData)
        #expect(legacy.blobs["Work"] == nil)
        #expect(legacy.loadCount == 1)
        #expect(legacy.deleteCount == 1)
    }

    @Test
    func migrationCompleteSkipsLegacyFallback() throws {
        let dataProtection = RecordingAuthVault()
        let legacy = RecordingAuthVault(blobs: ["Work": Data("legacy".utf8)])
        let vault = MigratingAuthVault(
            dataProtection: dataProtection,
            legacy: legacy,
            accessGroup: "TEAM.example",
            probeResult: .succeeded,
            migrationComplete: true)

        #expect(try vault.authBlobAvailability(profileID: "Work") == .missing)
        #expect(try vault.loadAuthBlobForActivation(profileID: "Work") == nil)
        #expect(legacy.loadCount == 0)
        #expect(legacy.hasCount == 0)
    }

    @Test
    func availabilityOnlyReportsNeedsMigrationWhenLegacyBlobExists() throws {
        let dataProtection = RecordingAuthVault()
        let legacy = RecordingAuthVault()
        let vault = MigratingAuthVault(
            dataProtection: dataProtection,
            legacy: legacy,
            accessGroup: "TEAM.example",
            probeResult: .succeeded)

        #expect(try vault.authBlobAvailability(profileID: "Missing") == .missing)
        #expect(legacy.hasCount == 1)

        legacy.blobs["LegacyOnly"] = Data("legacy".utf8)
        #expect(try vault.authBlobAvailability(profileID: "LegacyOnly") == .needsMigration)
    }

    @Test
    func deleteRemovesBothBackendsWhenDataProtectionIsActive() throws {
        let dataProtection = RecordingAuthVault(blobs: ["Work": Data("dp".utf8)])
        let legacy = RecordingAuthVault(blobs: ["Work": Data("legacy".utf8)])
        let vault = MigratingAuthVault(
            dataProtection: dataProtection,
            legacy: legacy,
            accessGroup: "TEAM.example",
            probeResult: .succeeded)

        try vault.deleteAuthBlob(profileID: "Work")
        #expect(dataProtection.blobs["Work"] == nil)
        #expect(legacy.blobs["Work"] == nil)
        #expect(dataProtection.deleteCount == 1)
        #expect(legacy.deleteCount == 1)
    }

    @Test
    func duplicateAwareSaveChecksLegacyOnlyProfilesWithoutMigratingThem() throws {
        let existingData = Data(#"{"OPENAI_API_KEY":"sk-existing-duplicate-1111111111111111"}"#.utf8)
        let dataProtection = RecordingAuthVault()
        let legacy = RecordingAuthVault(blobs: ["Existing": existingData])
        let vault = MigratingAuthVault(
            dataProtection: dataProtection,
            legacy: legacy,
            accessGroup: "TEAM.example",
            probeResult: .succeeded)

        do {
            try DuplicateAwareAuthSaver.save(
                existingData,
                profileID: "Target",
                profiles: [
                    ProfileConfig(id: "Existing", label: "Existing Account"),
                    ProfileConfig(id: "Target", label: "Target"),
                ],
                vault: vault)
        } catch let error as DuplicateAwareAuthSaverError
            where error == .duplicate(existingLabel: "Existing Account") {
            #expect(dataProtection.blobs["Existing"] == nil)
            #expect(dataProtection.blobs["Target"] == nil)
            #expect(legacy.blobs["Existing"] == existingData)
            #expect(legacy.deleteCount == 0)
            return
        } catch {
            try envFail("Expected duplicate error, got \(error)")
        }

        try envFail("Duplicate legacy-only profile was not rejected")
    }

    @Test
    func switchMigratesOutgoingActiveProfileWhenOnlyLegacyMatchesLiveAuth() throws {
        let workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-profile-migrating-switch-\(UUID().uuidString)", isDirectory: true)
        let home = workDir.appendingPathComponent("home", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: workDir) }

        let activeData = Data(#"{"OPENAI_API_KEY":"sk-active-1111111111111111"}"#.utf8)
        let targetData = Data(#"{"OPENAI_API_KEY":"sk-target-2222222222222222"}"#.utf8)
        let dataProtection = RecordingAuthVault(blobs: ["Target": targetData])
        let legacy = RecordingAuthVault(blobs: ["Active": activeData])
        let vault = MigratingAuthVault(
            dataProtection: dataProtection,
            legacy: legacy,
            accessGroup: "TEAM.example",
            probeResult: .succeeded)
        let paths = AppPaths(environment: ["CODEX_PROFILE_HOME": home.path])
        try FileManager.default.createDirectory(
            at: paths.liveCodexHome,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        try FileManager.default.createDirectory(
            at: paths.switcherHome,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        try activeData.write(to: paths.liveAuthURL)
        let config = AppConfig(
            profiles: [
                ProfileConfig(id: "Active", label: "Active"),
                ProfileConfig(id: "Target", label: "Target"),
            ],
            activeProfile: "Active",
            authStorageVersion: 3)
        try JSONEncoder.codexProfilePrettySorted
            .encode(config)
            .write(to: paths.configURL)

        let transaction = try ProfileTransactionService(
            vault: vault,
            paths: paths,
            isCodexDesktopRunning: { false }
        ).prepareSwitch(to: "Target")
        try transaction.commit()

        #expect(dataProtection.blobs["Active"] == activeData)
        #expect(legacy.blobs["Active"] == nil)
        #expect(try Data(contentsOf: paths.liveAuthURL) == targetData)
    }
}
