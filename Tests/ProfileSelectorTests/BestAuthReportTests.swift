@testable import CodexProfileCore
import Foundation
import Testing

@Suite("BestAuthReport")
struct BestAuthReportTests {
    @Test("encodes the stable JSON shape with sorted keys")
    func encodesStableShape() throws {
        let report = BestAuthReport(
            selected: "2",
            tier: "preferred",
            score: 14,
            candidates: [
                BestAuthReport.Candidate(id: "1", tier: "exhausted", score: 0, snapshotAgeSeconds: 42),
                BestAuthReport.Candidate(id: "2", tier: "preferred", score: 14, snapshotAgeSeconds: 5),
            ],
            fetched: true)

        let json = try report.jsonString()

        // sortedKeys makes the byte output deterministic.
        #expect(json == "{\"candidates\":[{\"id\":\"1\",\"score\":0,\"snapshotAgeSeconds\":42,\"tier\":\"exhausted\"},{\"id\":\"2\",\"score\":14,\"snapshotAgeSeconds\":5,\"tier\":\"preferred\"}],\"fetched\":true,\"score\":14,\"selected\":\"2\",\"tier\":\"preferred\"}")
    }

    @Test("snapshotAgeSeconds is nullable and round-trips")
    func nullableAge() throws {
        let report = BestAuthReport(
            selected: "1",
            tier: "lastResort",
            score: 0,
            candidates: [BestAuthReport.Candidate(id: "1", tier: "lastResort", score: 0, snapshotAgeSeconds: nil)],
            fetched: false)

        let data = Data(try report.jsonString().utf8)
        let decoded = try JSONDecoder().decode(BestAuthReport.self, from: data)
        #expect(decoded == report)
        #expect(decoded.candidates.first?.snapshotAgeSeconds == nil)
        #expect(try report.jsonString().contains("\"snapshotAgeSeconds\":null"))
    }

    @Test("tier report names map from selector tiers")
    func tierNames() {
        #expect(ProfileCandidate.ProfileTier.preferred.reportName == "preferred")
        #expect(ProfileCandidate.ProfileTier.lastResort.reportName == "lastResort")
        #expect(ProfileCandidate.ProfileTier.ineligible.reportName == "exhausted")
    }
}
