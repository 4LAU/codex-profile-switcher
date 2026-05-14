import Foundation

struct FileAuthVault: AuthVault {
    let root: URL
    private let fileManager = FileManager.default

    func listProfileIDs() throws -> [String] {
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

    func loadAuthBlob(profileID: String) throws -> Data? {
        let url = self.authURL(profileID: profileID)
        guard self.fileManager.fileExists(atPath: url.path) else {
            return nil
        }
        return try Data(contentsOf: url)
    }

    func saveAuthBlob(_ data: Data, profileID: String) throws {
        try self.ensureRoot()
        let url = self.authURL(profileID: profileID)
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

    func deleteAuthBlob(profileID: String) throws {
        let url = self.authURL(profileID: profileID)
        if self.fileManager.fileExists(atPath: url.path) {
            try self.fileManager.removeItem(at: url)
        }
    }

    func hasAuthBlob(profileID: String) throws -> Bool {
        self.fileManager.fileExists(atPath: self.authURL(profileID: profileID).path)
    }

    private func authURL(profileID: String) -> URL {
        self.root.appendingPathComponent("\(profileID).json")
    }

    private func ensureRoot() throws {
        try self.fileManager.createDirectory(
            at: self.root,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
    }
}
