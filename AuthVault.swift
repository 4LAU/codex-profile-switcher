import Foundation

protocol AuthVault {
    func listProfileIDs() throws -> [String]
    func loadAuthBlob(profileID: String) throws -> Data?
    func saveAuthBlob(_ data: Data, profileID: String) throws
    func deleteAuthBlob(profileID: String) throws
    func hasAuthBlob(profileID: String) throws -> Bool
    func repairStoredAuthAccess() throws -> Int
}

extension AuthVault {
    func repairStoredAuthAccess() throws -> Int {
        var repaired = 0
        for profileID in try self.listProfileIDs() {
            guard let data = try self.loadAuthBlob(profileID: profileID) else { continue }
            try self.saveAuthBlob(data, profileID: profileID)
            repaired += 1
        }
        return repaired
    }
}
