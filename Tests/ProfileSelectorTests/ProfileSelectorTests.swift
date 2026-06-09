@testable import CodexProfileCore
import Foundation
import Testing

// MARK: - Fixtures

private let past = Date(timeIntervalSince1970: 1_000_000)
private let future = Date(timeIntervalSince1970: 9_999_999_999)
private let now = Date(timeIntervalSince1970: 5_000_000)

/// A snapshot whose reset dates are in the future (active window), so usedPercent is taken as-is.
private func snapshot(
    primary: Int,
    secondary: Int = 0,
    primaryResetAt: Date? = future,
    secondaryResetAt: Date? = future,
    fetchedAt: Date = now
) -> UsageSnapshot {
    UsageSnapshot(
        planType: nil,
        creditsRemaining: nil,
        primaryUsedPercent: primary,
        primaryResetAt: primaryResetAt,
        secondaryUsedPercent: secondary,
        secondaryResetAt: secondaryResetAt,
        fetchedAt: fetchedAt)
}

private func profile(_ id: String) -> ProfileConfig {
    ProfileConfig(id: id, label: id)
}

private func override(until: Date) -> ExhaustionOverride {
    ExhaustionOverride(blockedUntil: until, reason: "test", source: "test")
}

// MARK: - Tests

@Suite("ProfileSelector")
struct ProfileSelectorTests {

    // MARK: 1. Highest-remaining-quota profile wins (lower usedPercent = higher quota = wins)

    @Test("lower usedPercent wins — preferred tier, ascending score sort")
    func lowerUsedPercentWins() {
        let profiles = [profile("a"), profile("b"), profile("c")]
        let cache = UsageCache(snapshots: [
            "a": snapshot(primary: 80),
            "b": snapshot(primary: 20),
            "c": snapshot(primary: 50),
        ])
        let result = ProfileSelector.selectBest(profiles: profiles, cache: cache, now: now)
        #expect(result?.profileID == "b")
        #expect(result?.effectiveScore == 20)
        #expect(result?.tier == .preferred)
    }

    @Test("score=100 demotes to ineligible, not selected")
    func score100IsIneligible() {
        let profiles = [profile("a"), profile("b")]
        let cache = UsageCache(snapshots: [
            "a": snapshot(primary: 100),  // score >= 100 → ineligible
            "b": snapshot(primary: 60),
        ])
        let result = ProfileSelector.selectBest(profiles: profiles, cache: cache, now: now)
        #expect(result?.profileID == "b")
        #expect(result?.tier == .preferred)
    }

    @Test("preferred tier beats lastResort regardless of score")
    func preferredTierBeatsLastResort() {
        // "a" has a snapshot with score 99 (preferred); "b" has no snapshot (lastResort, score 0)
        // preferred comes before lastResort, so "a" wins despite higher score
        let profiles = [profile("a"), profile("b")]
        let cache = UsageCache(snapshots: [
            "a": snapshot(primary: 99),
        ])
        let result = ProfileSelector.selectBest(profiles: profiles, cache: cache, now: now)
        #expect(result?.profileID == "a")
        #expect(result?.tier == .preferred)
    }

    // MARK: 2. Exhaustion override

    @Test("active override excludes profile")
    func activeOverrideExcludesProfile() {
        let profiles = [profile("a"), profile("b")]
        let cache = UsageCache(
            snapshots: [
                "a": snapshot(primary: 10),
                "b": snapshot(primary: 40),
            ],
            exhaustionOverrides: [
                "a": override(until: future),  // active
            ])
        let result = ProfileSelector.selectBest(profiles: profiles, cache: cache, now: now)
        #expect(result?.profileID == "b")
    }

    @Test("expired override re-includes profile")
    func expiredOverrideReIncludesProfile() {
        let profiles = [profile("a"), profile("b")]
        let cache = UsageCache(
            snapshots: [
                "a": snapshot(primary: 10),
                "b": snapshot(primary: 40),
            ],
            exhaustionOverrides: [
                "a": override(until: past),  // expired (past < now)
            ])
        let result = ProfileSelector.selectBest(profiles: profiles, cache: cache, now: now)
        // "a" has lower score (10 < 40), override expired, so "a" wins
        #expect(result?.profileID == "a")
    }

    @Test("all profiles overridden → returns nil")
    func allOverriddenReturnsNil() {
        let profiles = [profile("a")]
        let cache = UsageCache(
            snapshots: ["a": snapshot(primary: 10)],
            exhaustionOverrides: ["a": override(until: future)])
        let result = ProfileSelector.selectBest(profiles: profiles, cache: cache, now: now)
        #expect(result == nil)
    }

    // MARK: 3. Reset-time decay

    @Test("primary window past reset → score decays to 0")
    func primaryWindowPastResetDecaysToZero() {
        // primaryResetAt is in the past → effectiveWindowScore returns 0 for primary
        // secondary also past reset → overall score = max(0, 0) = 0
        let profiles = [profile("a"), profile("b")]
        let cache = UsageCache(snapshots: [
            "a": snapshot(primary: 90, secondary: 80, primaryResetAt: past, secondaryResetAt: past),
            "b": snapshot(primary: 50),
        ])
        // "a" has both windows past reset → score 0, preferred tier
        // "b" has score 50, preferred tier
        // lower score wins → "a" wins
        let result = ProfileSelector.selectBest(profiles: profiles, cache: cache, now: now)
        #expect(result?.profileID == "a")
        #expect(result?.effectiveScore == 0)
    }

    @Test("only primary window past reset — secondary still active, secondary score used")
    func onlyPrimaryPastResetUsesSecondary() {
        let profiles = [profile("a")]
        let cache = UsageCache(snapshots: [
            "a": snapshot(primary: 90, secondary: 40, primaryResetAt: past, secondaryResetAt: future),
        ])
        // primary decays to 0, secondary = 40; score = max(0, 40) = 40
        let result = ProfileSelector.selectBest(profiles: profiles, cache: cache, now: now)
        #expect(result?.effectiveScore == 40)
        #expect(result?.tier == .preferred)
    }

    @Test("snapshot with no resetAt dates — usedPercent used directly")
    func nilResetAtUsesUsedPercentDirectly() {
        // nil resetAt: the guard `if let resetAt, resetAt < now` is false → return usedPercent
        let profiles = [profile("a")]
        let cache = UsageCache(snapshots: [
            "a": snapshot(primary: 55, primaryResetAt: nil, secondaryResetAt: nil),
        ])
        let result = ProfileSelector.selectBest(profiles: profiles, cache: cache, now: now)
        #expect(result?.effectiveScore == 55)
    }

    // MARK: 4. Empty cache — degraded behavior (characterization)

    @Test("empty cache: all profiles are lastResort with score 0")
    func emptyCacheAllLastResort() {
        let profiles = [profile("a"), profile("b"), profile("c")]
        let cache = UsageCache(snapshots: [:])
        let result = ProfileSelector.selectBest(profiles: profiles, cache: cache, now: now)
        // All three get lastResort/score=0; tie-break is lexicographic profileID → "a" wins
        #expect(result != nil)
        #expect(result?.tier == .lastResort)
        #expect(result?.effectiveScore == 0)
        #expect(result?.profileID == "a")
    }

    @Test("empty profiles list → returns nil")
    func emptyProfilesListReturnsNil() {
        let cache = UsageCache(snapshots: [:])
        let result = ProfileSelector.selectBest(profiles: [], cache: cache, now: now)
        #expect(result == nil)
    }

    // MARK: 5. Exclusion list

    @Test("excluded profile IDs are not considered")
    func excludeIDsRespected() {
        let profiles = [profile("a"), profile("b"), profile("c")]
        let cache = UsageCache(snapshots: [
            "a": snapshot(primary: 10),  // best score, but excluded
            "b": snapshot(primary: 30),
            "c": snapshot(primary: 50),
        ])
        let result = ProfileSelector.selectBest(profiles: profiles, cache: cache, excludeIDs: ["a"], now: now)
        #expect(result?.profileID == "b")
    }

    @Test("excluding all profiles returns nil")
    func excludingAllReturnsNil() {
        let profiles = [profile("a"), profile("b")]
        let cache = UsageCache(snapshots: [
            "a": snapshot(primary: 10),
            "b": snapshot(primary: 20),
        ])
        let result = ProfileSelector.selectBest(profiles: profiles, cache: cache, excludeIDs: ["a", "b"], now: now)
        #expect(result == nil)
    }

    // MARK: 6. Tie-break: equal score, equal fetchedAt → lexicographic profileID ascending

    @Test("tie-break: equal score and fetchedAt → lexicographic profileID (ascending)")
    func tieBreakLexicographic() {
        let fetchTime = now
        let profiles = [profile("charlie"), profile("alpha"), profile("bravo")]
        let cache = UsageCache(snapshots: [
            "charlie": snapshot(primary: 30, fetchedAt: fetchTime),
            "alpha":   snapshot(primary: 30, fetchedAt: fetchTime),
            "bravo":   snapshot(primary: 30, fetchedAt: fetchTime),
        ])
        let result = ProfileSelector.selectBest(profiles: profiles, cache: cache, now: now)
        // All have same score (30) and fetchedAt → lexicographic: alpha < bravo < charlie
        #expect(result?.profileID == "alpha")
    }

    @Test("tie-break: equal score, different fetchedAt → more recent fetchedAt wins")
    func tieBreakFetchedAtMoreRecentWins() {
        // Sorting: `aFetch > bFetch` returns true → a comes first → more recent fetch wins
        let earlier = Date(timeIntervalSince1970: 3_000_000)
        let later   = Date(timeIntervalSince1970: 4_000_000)
        let profiles = [profile("a"), profile("b")]
        let cache = UsageCache(snapshots: [
            "a": snapshot(primary: 30, fetchedAt: earlier),
            "b": snapshot(primary: 30, fetchedAt: later),
        ])
        let result = ProfileSelector.selectBest(profiles: profiles, cache: cache, now: now)
        // "b" has a more recent fetchedAt → wins tie
        #expect(result?.profileID == "b")
    }
}
