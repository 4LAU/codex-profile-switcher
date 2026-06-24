import Foundation

#if canImport(Glibc)
import Glibc
#endif

/// Cross-process advisory lock (POSIX `flock`) serializing every
/// read-modify-write of the shared usage cache.
///
/// Why this exists: the cache file is mutated by several whole-cache writers —
/// the CLI's lease commands, `mark-exhausted`, `persistCacheMerge` during
/// `best-auth`/`exec`, and the long-lived menu-bar app's `saveCache`. Each does
/// read-disk → mutate → atomic-replace. `AtomicFileWriter` makes the *replace*
/// atomic, but it does NOT make the read-modify-write *transaction* isolated:
/// if process B commits a lease between process A's disk read and A's atomic
/// replace, A writes back a map that predates B's lease and silently drops it.
/// The `mergingDiskOverrides` merge shrinks this window for the leases map but
/// cannot close it — `persistCacheMerge` reads disk seconds before it writes
/// (the select+seed in `performBestAuth` sits in between). An advisory lock held
/// across the whole read-modify-write is the only correct fix.
///
/// `flock` is advisory and per-open-file-description; every cache writer in both
/// the CLI and the app must funnel through `CacheLock.withLock` for it to help.
/// The lock is process-scoped (an `flock` is released when the fd closes or the
/// process dies), so a crash never strands the lock.
public enum CacheLock {
    public enum LockError: Error {
        case open(String, Int32)
        case lock(String, Int32)
    }

    /// Runs `body` while holding an exclusive advisory lock on `lockURL`.
    /// Blocks until the lock is acquired. The lock file is created if missing
    /// (0600) and is intentionally never written to or deleted — deleting a lock
    /// file under a concurrent holder breaks mutual exclusion.
    @discardableResult
    public static func withLock<T>(
        at lockURL: URL,
        fileManager: FileManager = .default,
        _ body: () throws -> T
    ) throws -> T {
        try AtomicFileWriter.ensurePrivateDirectory(
            lockURL.deletingLastPathComponent(), fileManager: fileManager)

        let fd = open(lockURL.path, O_RDONLY | O_CREAT, 0o600)
        guard fd >= 0 else {
            throw LockError.open(lockURL.path, errno)
        }
        defer { close(fd) }

        // Retry across EINTR so a signal does not spuriously fail the lock.
        while flock(fd, LOCK_EX) != 0 {
            if errno == EINTR { continue }
            throw LockError.lock(lockURL.path, errno)
        }
        defer { _ = flock(fd, LOCK_UN) }

        return try body()
    }
}
