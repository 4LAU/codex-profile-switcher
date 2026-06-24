@testable import CodexProfileCore
import Foundation
import Testing

// MARK: - Fixtures

private let now = Date(timeIntervalSince1970: 5_000_000)
private let future = Date(timeIntervalSince1970: 9_999_999_999)

private func lease(
    token: String,
    home: String = "/tmp/codex-home",
    expiresAt: Date = future
) -> LeaseReservation {
    LeaseReservation(token: token, home: home, expiresAt: expiresAt, createdAt: now)
}

/// Encodes `cache` to a unique temp file and returns its URL. The caller is
/// responsible for removing the file when done.
private func writeTempCache(_ cache: UsageCache) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("usage-cache-lease-\(UUID().uuidString).json")
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    try encoder.encode(cache).write(to: url)
    return url
}

private func iso8601Decoder() -> JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
}

// MARK: - Tests

@Suite("UsageCacheLease")
struct UsageCacheLeaseTests {

    // MARK: 1. Round-trip — encode/decode preserves leases

    @Test("encode/decode round-trips leases")
    func roundTripsLeases() throws {
        let original = UsageCache(
            snapshots: [:],
            leases: ["a": lease(token: "tok-a")])

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(original)

        let decoded = try iso8601Decoder().decode(UsageCache.self, from: data)

        #expect(decoded == original)
    }

    // MARK: 2. Backward compatibility — old cache files without a `leases` key

    @Test("cache JSON without a leases key decodes to empty leases")
    func missingLeasesKeyDecodesEmpty() throws {
        let json = """
        {
          "snapshots": {},
          "exhaustionOverrides": {}
        }
        """
        let cache = try iso8601Decoder().decode(UsageCache.self, from: Data(json.utf8))

        #expect(cache.leases == [:])
    }

    // MARK: 3. Leases are taken from disk verbatim (disk is authoritative)

    @Test("merge replaces in-memory leases with the disk lease map")
    func mergeTakesDiskLeasesVerbatim() throws {
        let diskURL = try writeTempCache(UsageCache(snapshots: [:], leases: ["b": lease(token: "tok-b")]))
        defer { try? FileManager.default.removeItem(at: diskURL) }

        // In-memory holds lease "a"; disk holds lease "b". The result is exactly
        // disk's map — "b" only, "a" dropped — because a writer never knows the
        // whole lease map, only the one entry it is about to mutate.
        let memory = UsageCache(snapshots: [:], leases: ["a": lease(token: "tok-a")])
        let merged = memory.mergingDiskOverrides(fromCacheAt: diskURL, decoder: iso8601Decoder())

        #expect(merged.leases["b"]?.token == "tok-b")
        #expect(merged.leases["a"] == nil)
        #expect(merged.leases.count == 1)
    }

    // MARK: 4. A stale in-memory lease NEVER wins over disk (the resurrection fix)

    @Test("disk lease wins over a stale in-memory lease for the same profile")
    func diskLeaseWinsOverStaleMemory() throws {
        let diskURL = try writeTempCache(UsageCache(snapshots: [:], leases: ["a": lease(token: "disk")]))
        defer { try? FileManager.default.removeItem(at: diskURL) }

        let memory = UsageCache(snapshots: [:], leases: ["a": lease(token: "stale-memory")])
        let merged = memory.mergingDiskOverrides(fromCacheAt: diskURL, decoder: iso8601Decoder())

        #expect(merged.leases["a"]?.token == "disk")
    }

    // MARK: 5. A lease ended on disk is NOT resurrected by a stale in-memory copy

    @Test("a lease absent on disk but present in memory is dropped, not resurrected")
    func endedLeaseNotResurrected() throws {
        // Disk has no leases (the lease was ended). A long-lived reader (e.g. the
        // menu app) still holds it in memory. The merge must not write it back.
        let diskURL = try writeTempCache(UsageCache(snapshots: [:], leases: [:]))
        defer { try? FileManager.default.removeItem(at: diskURL) }

        let memory = UsageCache(snapshots: [:], leases: ["a": lease(token: "ended")])
        let merged = memory.mergingDiskOverrides(fromCacheAt: diskURL, decoder: iso8601Decoder())

        #expect(merged.leases["a"] == nil)
        #expect(merged.leases.isEmpty)
    }
}
