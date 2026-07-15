@testable import CodexProfileCore
import Foundation
import Testing

@Suite("Codex rate-limit snapshots")
struct CodexRateLimitsTests {

    @Test("captures a weekly primary window when secondary is absent")
    func capturesWeeklyPrimaryWindow() throws {
        let json = """
        {
          "rateLimits": {
            "primary": {
              "usedPercent": 18,
              "windowDurationMins": 10080,
              "resetsAt": 1784487871
            },
            "secondary": null,
            "credits": {
              "hasCredits": false,
              "unlimited": false,
              "balance": null
            },
            "planType": "team"
          }
        }
        """

        let response = try JSONDecoder().decode(RPCRateLimitsResponse.self, from: Data(json.utf8))
        let snapshot = try CLIUsageFetcher.makeSnapshot(from: response.rateLimits)

        #expect(snapshot.primaryUsedPercent == 18)
        #expect(snapshot.primaryWindowDurationMins == 10_080)
        #expect(snapshot.secondaryUsedPercent == 0)
        #expect(snapshot.secondaryWindowDurationMins == nil)
    }

    @Test("decodes snapshots cached before window durations were recorded")
    func decodesLegacySnapshot() throws {
        let json = """
        {
          "planType": "team",
          "creditsRemaining": null,
          "primaryUsedPercent": 18,
          "primaryResetAt": "2026-07-19T20:00:00Z",
          "secondaryUsedPercent": 0,
          "secondaryResetAt": null,
          "fetchedAt": "2026-07-14T20:00:00Z"
        }
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let snapshot = try decoder.decode(UsageSnapshot.self, from: Data(json.utf8))

        #expect(snapshot.primaryWindowDurationMins == nil)
        #expect(snapshot.secondaryWindowDurationMins == nil)
    }
}
