@testable import CodexProfileSwitcherApp
import Foundation
import Testing

@Suite("Usage window labels")
struct UsageWindowLabelTests {

    @Test("uses the reported duration instead of a fixed five-hour label")
    func usesReportedDuration() {
        #expect(usageWindowLabel(durationMins: 15, legacyLabel: "5h") == "15m")
        #expect(usageWindowLabel(durationMins: 300, legacyLabel: "5h") == "5h")
        #expect(usageWindowLabel(durationMins: 10_080, legacyLabel: "5h") == "Wk")
    }

    @Test("uses legacy labels for snapshots cached before durations were recorded")
    func usesLegacyLabelWhenDurationMissing() {
        #expect(usageWindowLabel(durationMins: nil, legacyLabel: "Wk") == "Wk")
    }

    @Test("usage display mode switches between remaining and used percentages")
    func switchesUsageDisplayMode() {
        #expect(UsageDisplayMode.remaining.displayPercent(fromUsedPercent: 35) == 65)
        #expect(UsageDisplayMode.used.displayPercent(fromUsedPercent: 35) == 35)
        #expect(UsageDisplayMode.remaining.displayText(fromUsedPercent: 77) == "23% remaining")
        #expect(UsageDisplayMode.used.displayText(fromUsedPercent: 77) == "77% used")
        #expect(UsageDisplayMode.remaining.displayPercent(fromUsedPercent: -1) == 100)
        #expect(UsageDisplayMode.remaining.displayPercent(fromUsedPercent: 101) == 0)
    }

    @Test("usage warning level follows the selected display semantics")
    func warningLevelFollowsDisplayMode() {
        #expect(UsageDisplayMode.remaining.level(forDisplayedPercent: 10) == .critical)
        #expect(UsageDisplayMode.remaining.level(forDisplayedPercent: 30) == .warning)
        #expect(UsageDisplayMode.remaining.level(forDisplayedPercent: 65) == .normal)
        #expect(UsageDisplayMode.used.level(forDisplayedPercent: 90) == .critical)
        #expect(UsageDisplayMode.used.level(forDisplayedPercent: 70) == .warning)
        #expect(UsageDisplayMode.used.level(forDisplayedPercent: 35) == .normal)
    }

    @Test("formats an available reset count independently of the credit balance")
    func formatsAvailableResetCount() {
        #expect(resetCountDisplayName(0) == "0 re")
        #expect(resetCountDisplayName(1) == "1 re")
    }

    @Test("usage display preferences preserve the existing used-percent default")
    @MainActor
    func persistsUsageDisplayMode() {
        let suiteName = "UsageDisplayPreferencesTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        #expect(UsageDisplayPreferences(defaults: defaults).mode == .used)
        defaults.set(UsageDisplayMode.remaining.rawValue, forKey: "usageDisplayMode")
        #expect(UsageDisplayPreferences(defaults: defaults).mode == .remaining)
    }
}
