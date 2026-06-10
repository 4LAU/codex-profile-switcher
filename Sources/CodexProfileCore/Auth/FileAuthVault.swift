import Foundation

public struct FileAuthVault: AuthVault {
    public let root: URL
    // Computed rather than stored: `FileManager` is a non-Sendable reference
    // type, and storing it would make this `Sendable` vault non-Sendable.
    // `FileManager.default` is documented thread-safe.
    private var fileManager: FileManager { .default }

    public init(root: URL) {
        self.root = root
    }

    public func listProfileIDs() throws -> [String] {
        guard self.fileManager.fileExists(atPath: self.root.path) else {
            return []
        }

        let urls = try self.fileManager.contentsOfDirectory(
            at: self.root,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )

        return urls.compactMap { url in
            guard url.pathExtension == "json" else { return nil }
            return url.deletingPathExtension().lastPathComponent
        }
        .sorted()
    }

    public func loadAuthBlob(profileID: String) throws -> Data? {
        let url = try self.authURL(profileID: profileID)
        guard self.fileManager.fileExists(atPath: url.path) else {
            return nil
        }
        return try Data(contentsOf: url)
    }

    public func saveAuthBlob(_ data: Data, profileID: String) throws {
        try self.ensureRoot()
        let url = try self.authURL(profileID: profileID)
        let temp = self.root.appendingPathComponent(".\(profileID).json.tmp-\(UUID().uuidString)")
        try data.write(to: temp, options: .withoutOverwriting)
        do {
            try self.fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temp.path)
            if self.fileManager.fileExists(atPath: url.path) {
                _ = try self.fileManager.replaceItemAt(url, withItemAt: temp)
            } else {
                try self.fileManager.moveItem(at: temp, to: url)
            }
        } catch {
            try? self.fileManager.removeItem(at: temp)
            throw error
        }
    }

    public func deleteAuthBlob(profileID: String) throws {
        let url = try self.authURL(profileID: profileID)
        if self.fileManager.fileExists(atPath: url.path) {
            try self.fileManager.removeItem(at: url)
        }
    }

    public func hasAuthBlob(profileID: String) throws -> Bool {
        self.fileManager.fileExists(atPath: try self.authURL(profileID: profileID).path)
    }

    public func diagnostics() -> AuthVaultDiagnostics {
        AuthVaultDiagnostics(activeBackend: .file)
    }

    // Defense-in-depth: reject profileIDs that fail the same rule
    // `ProfileValidator` enforces so a malformed or path-traversing ID cannot
    // escape the vault root. Throws `AuthError.notFound` (the closest existing
    // error) rather than introducing a new case.
    private func authURL(profileID: String) throws -> URL {
        guard ProfileValidator.isValid(profileID) else {
            throw AuthError.notFound
        }
        return self.root.appendingPathComponent("\(profileID).json")
    }

    private func ensureRoot() throws {
        try self.fileManager.createDirectory(
            at: self.root,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
    }
}
