@testable import CodexProfileSwitcherApp
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
}
