import Foundation
import Testing
@testable import CodexProfileCore

struct TokenRenewalTests {
    @Test
    func renewalIsDueForMissingStaleAndFutureRefreshDates() {
        let policy = RenewalPolicy()
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        #expect(policy.isDue(lastRefresh: nil, now: now))
        #expect(!policy.isDue(lastRefresh: now.addingTimeInterval(-60), now: now))
        #expect(policy.isDue(lastRefresh: now.addingTimeInterval(10 * 60), now: now))
    }
}
