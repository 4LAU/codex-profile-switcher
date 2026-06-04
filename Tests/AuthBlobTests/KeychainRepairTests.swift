@testable import CodexProfileCore
import Foundation
import Testing

final class KeychainRepairTests {
    @Test
    func testRepairReportsCompleteWhenAllSucceed() throws {
        let vault = RepairTestVault(authBlobs: ["1": Data("a".utf8), "2": Data("b".utf8)])
        let result = try vault.repairStoredAuthAccess()
        try expectEqual(result.total, 2, "Wrong repair total")
        try expectEqual(result.repaired, 2, "Wrong repaired count")
        try expectEqual(result.isComplete, true, "Repair should be complete")
    }

    @Test
    func testRepairReportsIncompleteWhenLoadFails() throws {
        let vault = RepairTestVault(
            authBlobs: ["1": Data("a".utf8), "2": Data("b".utf8)],
            failLoadFor: ["2"]
        )
        let result = try vault.repairStoredAuthAccess()
        try expectEqual(result.total, 2, "Wrong repair total")
        try expectEqual(result.repaired, 1, "Wrong repaired count")
        try expectEqual(result.isComplete, false, "Repair should be incomplete")
    }

    @Test
    func testRepairReportsCompleteWithNoProfiles() throws {
        let vault = RepairTestVault(authBlobs: [:])
        let result = try vault.repairStoredAuthAccess()
        try expectEqual(result.total, 0, "Wrong repair total")
        try expectEqual(result.repaired, 0, "Wrong repaired count")
        try expectEqual(result.isComplete, true, "Empty repair should be complete")
    }

    @Test
    func testRepairPreservesDataOnSuccess() throws {
        let vault = RepairTestVault(authBlobs: ["1": Data("original".utf8)])
        _ = try vault.repairStoredAuthAccess()
        try expectEqual(
            try vault.loadAuthBlob(profileID: "1"),
            Data("original".utf8),
            "Repair should preserve auth data")
    }
}

private final class RepairTestVault: AuthVault {
    private var authBlobs: [String: Data]
    private let failLoadFor: Set<String>

    init(authBlobs: [String: Data], failLoadFor: Set<String> = []) {
        self.authBlobs = authBlobs
        self.failLoadFor = failLoadFor
    }

    func listProfileIDs() throws -> [String] {
        Array(self.authBlobs.keys).sorted()
    }

    func loadAuthBlob(profileID: String) throws -> Data? {
        if self.failLoadFor.contains(profileID) {
            throw KeychainAuthVaultError.operationFailed(operation: "load", profileID: profileID, status: -25293)
        }
        return self.authBlobs[profileID]
    }

    func saveAuthBlob(_ data: Data, profileID: String) throws {
        self.authBlobs[profileID] = data
    }

    func deleteAuthBlob(profileID: String) throws {
        self.authBlobs[profileID] = nil
    }

    func hasAuthBlob(profileID: String) throws -> Bool {
        self.authBlobs[profileID] != nil
    }
}
