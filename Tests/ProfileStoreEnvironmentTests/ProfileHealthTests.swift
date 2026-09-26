@testable import CodexProfileSwitcherApp
import CodexProfileCore
import Foundation
import Testing

struct ProfileHealthTests {
    @Test
    func autoSwitchPicksTheNextAccountWhenTheActiveOneIsExhausted() throws {
        let records = Self.health(
            activeUsed: 100,
            otherUsed: 12)
        let target = ProfileHealth.autoSwitchTarget(from: records)
        try envExpect(target?.profile.id == "2", "Auto Switch did not pick the remaining account")
    }

    @Test
    func autoSwitchDoesNothingWhenTheActiveAccountStillHasQuota() throws {
        let records = Self.health(
            activeUsed: 80,
            otherUsed: 10)
        try envExpect(ProfileHealth.autoSwitchTarget(from: records) == nil,
                      "Auto Switch fired before the active account was exhausted")
    }

    @Test
    func autoSwitchDoesNothingWhenEveryAccountIsExhausted() throws {
        let records = Self.health(
            activeUsed: 100,
            otherUsed: 100)
        try envExpect(ProfileHealth.autoSwitchTarget(from: records) == nil,
                      "Auto Switch tried to move to another exhausted account")
    }

    private static func health(activeUsed: Int, otherUsed: Int) -> [ProfileHealth] {
        let now = Date()
        func snapshot(_ used: Int) -> UsageSnapshot {
            UsageSnapshot(
                planType: "plus",
                creditsRemaining: nil,
                primaryUsedPercent: used,
                primaryResetAt: now.addingTimeInterval(3600),
                secondaryUsedPercent: 10,
                secondaryResetAt: now.addingTimeInterval(86400),
                fetchedAt: now)
        }
        return ProfileHealth.build(
            profiles: [
                ProfileConfig(id: "1", label: "one"),
                ProfileConfig(id: "2", label: "two"),
            ],
            statuses: [
                "1": .available(snapshot(activeUsed)),
                "2": .available(snapshot(otherUsed)),
            ],
            activeProfileId: "1",
            canActivateAuth: { _ in true })
    }
}
