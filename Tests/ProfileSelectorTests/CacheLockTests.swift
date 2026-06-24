@testable import CodexProfileCore
import Foundation
import Testing

@Suite("CacheLock")
struct CacheLockTests {

    private func tempLockURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("cache-lock-test-\(UUID().uuidString)")
            .appendingPathComponent("cache.lock")
    }

    // The lock must serialize concurrent critical sections: if two threads both
    // run read-modify-write under the lock, neither sees the other mid-update.
    @Test("withLock serializes concurrent critical sections (no interleave)")
    func serializesConcurrentSections() throws {
        let lockURL = self.tempLockURL()
        defer { try? FileManager.default.removeItem(at: lockURL.deletingLastPathComponent()) }

        let counter = Counter()
        let iterations = 200
        let group = DispatchGroup()

        for _ in 0..<iterations {
            group.enter()
            DispatchQueue.global().async {
                try? CacheLock.withLock(at: lockURL) {
                    // Non-atomic read-modify-write: only correct under mutual
                    // exclusion. A race would lose increments.
                    let v = counter.value
                    Thread.sleep(forTimeInterval: 0.0002)
                    counter.value = v + 1
                }
                group.leave()
            }
        }

        group.wait()
        #expect(counter.value == iterations)
    }

    // The lock is reentrant-free but must release on scope exit so a second
    // acquisition in the same thread succeeds (fd-per-call, not held forever).
    @Test("withLock releases on return so a later acquisition succeeds")
    func releasesOnReturn() throws {
        let lockURL = self.tempLockURL()
        defer { try? FileManager.default.removeItem(at: lockURL.deletingLastPathComponent()) }

        var hits = 0
        try CacheLock.withLock(at: lockURL) { hits += 1 }
        try CacheLock.withLock(at: lockURL) { hits += 1 }
        #expect(hits == 2)
    }

    // A throwing body must still release the lock (defer-based unlock).
    @Test("withLock releases even when the body throws")
    func releasesOnThrow() throws {
        let lockURL = self.tempLockURL()
        defer { try? FileManager.default.removeItem(at: lockURL.deletingLastPathComponent()) }

        struct Boom: Error {}
        #expect(throws: Boom.self) {
            try CacheLock.withLock(at: lockURL) { throw Boom() }
        }
        // If the lock were still held, this would deadlock; it returns, proving release.
        var ran = false
        try CacheLock.withLock(at: lockURL) { ran = true }
        #expect(ran)
    }
}

private final class Counter: @unchecked Sendable {
    var value = 0
}
