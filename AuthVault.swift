import Foundation

protocol AuthVault {
    func listProfileIDs() throws -> [String]
    func loadAuthBlob(profileID: String) throws -> Data?
    func saveAuthBlob(_ data: Data, profileID: String) throws
    func deleteAuthBlob(profileID: String) throws
    func hasAuthBlob(profileID: String) throws -> Bool
}
