@testable import CodexProfileCore
import Foundation
import Testing

final class DuplicateAwareAuthSaverTests {
    @Test
    func testRejectsDuplicateAndPreservesOriginalTargetAuthBlob() throws {
        let originalTargetData = try oauthAuthData(
            idToken: try idToken(subject: "target-user", email: "target@example.test", accountID: "acct-target"),
            accountID: "acct-target")
        let existingData = try oauthAuthData(
            accessToken: "existing-access",
            refreshToken: "existing-refresh",
            idToken: try idToken(subject: "existing-user", email: "existing@example.test", accountID: "acct-existing"),
            accountID: "acct-existing")
        let duplicateData = try oauthAuthData(
            accessToken: "new-access",
            refreshToken: "new-refresh",
            idToken: try idToken(subject: "existing-user", email: "existing@example.test", accountID: "acct-existing"),
            accountID: "acct-existing")
        let vault = MemoryAuthVault(authBlobs: [
            "target": originalTargetData,
            "existing": existingData,
        ])

        do {
            try DuplicateAwareAuthSaver.save(
                duplicateData,
                profileID: "target",
                profiles: [
                    ProfileConfig(id: "target", label: "Target"),
                    ProfileConfig(id: "existing", label: "Existing Account"),
                ],
                vault: vault)
        } catch let error as DuplicateAwareAuthSaverError {
            try expectEqual(
                error.errorDescription,
                "This account is already saved as 'Existing Account'.",
                "Wrong duplicate rejection message")
        } catch {
            try fail("Expected duplicate-aware auth saver error, got \(error)")
        }

        try expectEqual(
            try vault.loadAuthBlob(profileID: "target"),
            originalTargetData,
            "Duplicate rejection overwrote original target auth")
        try expectEqual(vault.savedProfileIDs, [], "Duplicate rejection should happen before saving")
    }

    @Test
    func testRejectsMissingFingerprintBeforeSaving() throws {
        let vault = MemoryAuthVault()

        do {
            try DuplicateAwareAuthSaver.save(
                try jsonData(["tokens": ["access_token": "access", "refresh_token": "refresh"]]),
                profileID: "target",
                profiles: [ProfileConfig(id: "target", label: "Target")],
                vault: vault)
        } catch DuplicateAwareAuthSaverError.missingFingerprint {
            try expectEqual(vault.savedProfileIDs, [], "Missing fingerprint rejection should happen before saving")
            return
        } catch {
            try fail("Expected missing fingerprint error, got \(error)")
        }

        try fail("Expected missing fingerprint error")
    }
}

private final class MemoryAuthVault: AuthVault {
    private var authBlobs: [String: Data]
    private(set) var savedProfileIDs: [String] = []

    init(authBlobs: [String: Data] = [:]) {
        self.authBlobs = authBlobs
    }

    func listProfileIDs() throws -> [String] {
        Array(self.authBlobs.keys)
    }

    func loadAuthBlob(profileID: String) throws -> Data? {
        self.authBlobs[profileID]
    }

    func saveAuthBlob(_ data: Data, profileID: String) throws {
        self.savedProfileIDs.append(profileID)
        self.authBlobs[profileID] = data
    }

    func deleteAuthBlob(profileID: String) throws {
        self.authBlobs[profileID] = nil
    }

    func hasAuthBlob(profileID: String) throws -> Bool {
        self.authBlobs[profileID] != nil
    }
}
