import Foundation

public struct ProfileCandidate: Equatable {
    public let profileID: String
    public let effectiveScore: Int
    public let fetchedAt: Date?
    public let tier: ProfileTier

    public init(
        profileID: String,
        effectiveScore: Int,
        fetchedAt: Date?,
        tier: ProfileTier
    ) {
        self.profileID = profileID
        self.effectiveScore = effectiveScore
        self.fetchedAt = fetchedAt
        self.tier = tier
    }

    public enum ProfileTier: Int, Comparable {
        case preferred = 0
        case lastResort = 1
        case ineligible = 2

        public static func < (lhs: Self, rhs: Self) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }
}

public enum ProfileSelector {
    public struct Result: Equatable {
        public let profileID: String
        public let effectiveScore: Int
        public let tier: ProfileCandidate.ProfileTier
    }

    /// Scores every non-excluded profile (including ineligible ones) without
    /// applying the winner filter. Additive surface used to build the
    /// `best-auth --json` candidate list; does not change `selectBest`.
    public static func candidates(
        profiles: [ProfileConfig],
        cache: UsageCache,
        excludeIDs: Set<String> = [],
        now: Date = Date()
    ) -> [ProfileCandidate] {
        profiles
            .filter { !excludeIDs.contains($0.id) }
            .map { profile -> ProfileCandidate in
                if let override = cache.exhaustionOverrides[profile.id],
                   override.isActive(now: now) {
                    return ProfileCandidate(
                        profileID: profile.id,
                        effectiveScore: 100,
                        fetchedAt: nil,
                        tier: .ineligible)
                }

                guard let snapshot = cache.snapshots[profile.id] else {
                    return ProfileCandidate(
                        profileID: profile.id,
                        effectiveScore: 0,
                        fetchedAt: nil,
                        tier: .lastResort)
                }

                let score = effectiveScore(for: snapshot, now: now)
                let tier: ProfileCandidate.ProfileTier = score >= 100 ? .ineligible : .preferred
                return ProfileCandidate(
                    profileID: profile.id,
                    effectiveScore: score,
                    fetchedAt: snapshot.fetchedAt,
                    tier: tier)
            }
    }

    public static func selectBest(
        profiles: [ProfileConfig],
        cache: UsageCache,
        excludeIDs: Set<String> = [],
        now: Date = Date()
    ) -> Result? {
        let candidates = self.candidates(
            profiles: profiles,
            cache: cache,
            excludeIDs: excludeIDs,
            now: now)

        let sorted = candidates
            .filter { $0.tier != .ineligible }
            .sorted { a, b in
                if a.tier != b.tier { return a.tier < b.tier }
                if a.effectiveScore != b.effectiveScore { return a.effectiveScore < b.effectiveScore }
                if let aFetch = a.fetchedAt, let bFetch = b.fetchedAt, aFetch != bFetch {
                    return aFetch > bFetch
                }
                return a.profileID < b.profileID
            }

        guard let best = sorted.first else { return nil }
        return Result(
            profileID: best.profileID,
            effectiveScore: best.effectiveScore,
            tier: best.tier)
    }

    private static func effectiveScore(for snapshot: UsageSnapshot, now: Date) -> Int {
        max(
            effectiveWindowScore(
                snapshot.primaryUsedPercent,
                resetAt: snapshot.primaryResetAt,
                now: now),
            effectiveWindowScore(
                snapshot.secondaryUsedPercent,
                resetAt: snapshot.secondaryResetAt,
                now: now))
    }

    private static func effectiveWindowScore(
        _ usedPercent: Int,
        resetAt: Date?,
        now: Date
    ) -> Int {
        if let resetAt, resetAt < now {
            return 0
        }
        return usedPercent
    }
}
