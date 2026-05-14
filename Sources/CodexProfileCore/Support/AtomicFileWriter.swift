import Foundation

public enum AtomicFileWriter {
    public static func ensurePrivateDirectory(_ url: URL, fileManager: FileManager = .default) throws {
        try fileManager.createDirectory(
            at: url,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
    }

    public static func write(_ data: Data, to destination: URL, fileManager: FileManager = .default) throws {
        try self.ensurePrivateDirectory(destination.deletingLastPathComponent(), fileManager: fileManager)
        let temp = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(destination.lastPathComponent).tmp-\(UUID().uuidString)")
        try data.write(to: temp, options: .withoutOverwriting)
        do {
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temp.path)
            if fileManager.fileExists(atPath: destination.path) {
                _ = try fileManager.replaceItemAt(destination, withItemAt: temp)
            } else {
                try fileManager.moveItem(at: temp, to: destination)
            }
        } catch {
            try? fileManager.removeItem(at: temp)
            throw error
        }
    }
}
