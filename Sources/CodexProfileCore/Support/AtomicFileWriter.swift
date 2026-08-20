import Darwin
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
        try self.createFilePrivately(at: temp, contents: data)
        do {
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

    /// Creates `url` at mode 0600 from the moment it exists, instead of writing
    /// with the process's default permissions (0644 under a typical umask) and
    /// narrowing afterward. A crash between those two steps would otherwise
    /// leave a live credential briefly world-readable on disk. `O_EXCL`
    /// preserves the no-overwrite guarantee the caller relies on for its
    /// randomly-named temp file.
    private static func createFilePrivately(at url: URL, contents: Data) throws {
        let fd = url.path.withCString { open($0, O_WRONLY | O_CREAT | O_EXCL, 0o600) }
        guard fd >= 0 else {
            throw POSIXError(POSIXError.Code(rawValue: errno) ?? .EIO)
        }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        try handle.write(contentsOf: contents)
        // Force the written bytes to stable storage before the rename that
        // publishes this temp file over the destination. `replaceItemAt` makes
        // the RENAME atomic, but without this the data itself can still be
        // sitting in a page cache: a power loss between the write and the
        // rename could publish a zero-length or truncated file over a live
        // credential.
        guard fsync(fd) == 0 else {
            throw POSIXError(POSIXError.Code(rawValue: errno) ?? .EIO)
        }
        try handle.close()
    }
}
