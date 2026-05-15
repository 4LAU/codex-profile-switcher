@testable import CodexProfileCore
@testable import CodexProfileSwitcherApp
import Foundation
import Testing

final class ProfileHealthTests {
    @Test
    func statusMappingExcludesUnknownAndStaleUsageFromScoring() throws {
        let staleSnapshot = snapshot(primary: 91, secondary: 92)
        let profiles = [
            profile("available"),
            profile("loading"),
            profile("stale"),
            profile("relogin-auth"),
            profile("relogin-missing"),
            profile("migration"),
            profile("new"),
        ]
        let records = ProfileHealth.build(
            profiles: profiles,
            statuses: [
                "available": .available(snapshot(primary: 35, secondary: 62)),
                "loading": .loading,
                "stale": .stale(staleSnapshot),
                "relogin-auth": .reloginNeeded(nil),
                "relogin-missing": .reloginNeeded(nil),
                "migration": .needsMigration,
                "new": .notSetUp,
            ],
            activeProfileId: "available",
            canActivateAuth: { ["available", "loading", "stale", "relogin-auth", "migration"].contains($0) })

        let available = try record("available", in: records)
        #expect(available.tier == .knownSwitchable)
        #expect(available.isSwitchable)
        #expect(available.score == 62)
        #expect(available.limitingWindowResetAt == resetDate(20))

        let loading = try record("loading", in: records)
        #expect(loading.tier == .unknownUsage)
        #expect(loading.isSwitchable)
        #expect(loading.score == nil)

        let stale = try record("stale", in: records)
        #expect(stale.tier == .unknownUsage)
        #expect(stale.isSwitchable)
        #expect(stale.score == nil)
        #expect(stale.limitingWindowResetAt == nil)

        let reloginAuth = try record("relogin-auth", in: records)
        #expect(reloginAuth.tier == .unknownUsage)
        #expect(reloginAuth.isSwitchable)
        #expect(reloginAuth.score == nil)

        let reloginMissing = try record("relogin-missing", in: records)
        #expect(reloginMissing.tier == .notSwitchable)
        #expect(!reloginMissing.isSwitchable)

        let migration = try record("migration", in: records)
        #expect(migration.tier == .notSwitchable)
        #expect(!migration.isSwitchable)

        let notSetUp = try record("new", in: records)
        #expect(notSetUp.tier == .notSwitchable)
        #expect(!notSetUp.isSwitchable)
    }

    @Test
    func recommendationRequiresHealthyInactiveSwitchableCandidate() throws {
        let profiles = [
            profile("active"),
            profile("too-close"),
            profile("best-late"),
            profile("best-early"),
            profile("best-early-later-config"),
            profile("unknown"),
            profile("not-switchable"),
        ]
        let records = ProfileHealth.build(
            profiles: profiles,
            statuses: [
                "active": .available(snapshot(primary: 90, secondary: 12)),
                "too-close": .available(snapshot(primary: 71, secondary: 15)),
                "best-late": .available(snapshot(primary: 60, secondary: 20, primaryResetMinutes: 40)),
                "best-early": .available(snapshot(primary: 60, secondary: 20, primaryResetMinutes: 30)),
                "best-early-later-config": .available(snapshot(primary: 60, secondary: 20, primaryResetMinutes: 30)),
                "unknown": .stale(snapshot(primary: 5, secondary: 7)),
                "not-switchable": .available(snapshot(primary: 1, secondary: 2)),
            ],
            activeProfileId: "active",
            canActivateAuth: { $0 != "not-switchable" })

        let recommendation = try #require(ProfileHealth.recommendation(from: records))
        #expect(recommendation.profile.id == "best-early")

        let lowActiveRecords = ProfileHealth.build(
            profiles: [profile("active"), profile("candidate")],
            statuses: [
                "active": .available(snapshot(primary: 69, secondary: 0)),
                "candidate": .available(snapshot(primary: 10, secondary: 0)),
            ],
            activeProfileId: "active",
            canActivateAuth: { _ in true })
        #expect(ProfileHealth.recommendation(from: lowActiveRecords) == nil)
    }

}

private func profile(_ id: String) -> ProfileConfig {
    ProfileConfig(id: id, label: id)
}

private func snapshot(
    primary: Int,
    secondary: Int,
    primaryResetMinutes: TimeInterval = 10,
    secondaryResetMinutes: TimeInterval = 20
) -> UsageSnapshot {
    UsageSnapshot(
        planType: "pro",
        creditsRemaining: nil,
        primaryUsedPercent: primary,
        primaryResetAt: resetDate(primaryResetMinutes),
        secondaryUsedPercent: secondary,
        secondaryResetAt: resetDate(secondaryResetMinutes),
        fetchedAt: resetDate(0))
}

private func resetDate(_ minutes: TimeInterval) -> Date {
    Date(timeIntervalSince1970: 1_800_000_000 + minutes * 60)
}

private func record(_ id: String, in records: [ProfileHealth]) throws -> ProfileHealth {
    try #require(records.first { $0.profile.id == id })
}
