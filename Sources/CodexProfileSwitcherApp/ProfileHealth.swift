import CodexProfileCore
import Foundation

enum ProfileHealthTier: Int, Comparable {
    case knownSwitchable
    case unknownUsage
    case notSwitchable

    static func < (lhs: ProfileHealthTier, rhs: ProfileHealthTier) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

struct ProfileHealth {
    let profile: ProfileConfig
    let status: ProfileStatus
    let isActive: Bool
    let isSwitchable: Bool
    let score: Int?
    let limitingWindowResetAt: Date?
    let tier: ProfileHealthTier

    init(
        profile: ProfileConfig,
        status: ProfileStatus,
        isActive: Bool,
        isSwitchable: Bool,
        score: Int?,
        limitingWindowResetAt: Date?,
        tier: ProfileHealthTier
    ) {
        self.profile = profile
        self.status = status
        self.isActive = isActive
        self.isSwitchable = isSwitchable
        self.score = score
        self.limitingWindowResetAt = limitingWindowResetAt
        self.tier = tier
    }

    static func build(
        profiles: [ProfileConfig],
        statuses: [String: ProfileStatus],
        activeProfileId: String?,
        canActivateAuth: (String) -> Bool
    ) -> [ProfileHealth] {
        profiles.map { profile in
            Self(
                profile: profile,
                status: statuses[profile.id] ?? .notSetUp,
                isActive: profile.id == activeProfileId,
                canActivateAuth: canActivateAuth(profile.id))
        }
    }

    static func recommendation(
        from records: [ProfileHealth],
        activeMinimumScore: Int = 70,
        minimumScoreGap: Int = 20
    ) -> ProfileHealth? {
        guard let active = records.first(where: \.isActive),
              let activeScore = active.score,
              activeScore >= activeMinimumScore else {
            return nil
        }

        return records
            .filter {
                !$0.isActive &&
                    $0.tier == .knownSwitchable &&
                    $0.isSwitchable &&
                    ($0.score ?? Int.max) <= activeScore - minimumScoreGap
            }
            .enumerated()
            .min { lhs, rhs in
                Self.isBetterRecommendation(lhs.element, than: rhs.element, lhsOffset: lhs.offset, rhsOffset: rhs.offset)
            }?
            .element
    }

    static func menuOrderedInactive(_ records: [ProfileHealth]) -> [ProfileHealth] {
        records
            .filter { !$0.isActive }
            .enumerated()
            .sorted { lhs, rhs in
                if lhs.element.tier != rhs.element.tier {
                    return lhs.element.tier < rhs.element.tier
                }
                return lhs.offset < rhs.offset
            }
            .map(\.element)
    }

    private init(
        profile: ProfileConfig,
        status: ProfileStatus,
        isActive: Bool,
        canActivateAuth: Bool
    ) {
        switch status {
        case .available(let snapshot):
            let healthScore = Self.healthScore(for: snapshot)
            self.init(
                profile: profile,
                status: status,
                isActive: isActive,
                isSwitchable: canActivateAuth,
                score: healthScore.score,
                limitingWindowResetAt: healthScore.resetAt,
                tier: .knownSwitchable)
        case .loading, .stale:
            self.init(
                profile: profile,
                status: status,
                isActive: isActive,
                isSwitchable: canActivateAuth,
                score: nil,
                limitingWindowResetAt: nil,
                tier: .unknownUsage)
        case .reloginNeeded:
            self.init(
                profile: profile,
                status: status,
                isActive: isActive,
                isSwitchable: canActivateAuth,
                score: nil,
                limitingWindowResetAt: nil,
                tier: canActivateAuth ? .unknownUsage : .notSwitchable)
        case .needsMigration, .notSetUp:
            self.init(
                profile: profile,
                status: status,
                isActive: isActive,
                isSwitchable: false,
                score: nil,
                limitingWindowResetAt: nil,
                tier: .notSwitchable)
        }
    }

    private static func healthScore(for snapshot: UsageSnapshot) -> (score: Int, resetAt: Date?) {
        if snapshot.primaryUsedPercent > snapshot.secondaryUsedPercent {
            return (snapshot.primaryUsedPercent, snapshot.primaryResetAt)
        }
        if snapshot.secondaryUsedPercent > snapshot.primaryUsedPercent {
            return (snapshot.secondaryUsedPercent, snapshot.secondaryResetAt)
        }
        return (
            snapshot.primaryUsedPercent,
            Self.earlierReset(snapshot.primaryResetAt, snapshot.secondaryResetAt)
        )
    }

    private static func isBetterRecommendation(
        _ lhs: ProfileHealth,
        than rhs: ProfileHealth,
        lhsOffset: Int,
        rhsOffset: Int
    ) -> Bool {
        let lhsScore = lhs.score ?? Int.max
        let rhsScore = rhs.score ?? Int.max
        if lhsScore != rhsScore { return lhsScore < rhsScore }
        if lhs.limitingWindowResetAt != rhs.limitingWindowResetAt {
            return Self.isEarlierReset(lhs.limitingWindowResetAt, than: rhs.limitingWindowResetAt)
        }
        return lhsOffset < rhsOffset
    }

    private static func earlierReset(_ lhs: Date?, _ rhs: Date?) -> Date? {
        guard let lhs else { return rhs }
        guard let rhs else { return lhs }
        return min(lhs, rhs)
    }

    private static func isEarlierReset(_ lhs: Date?, than rhs: Date?) -> Bool {
        switch (lhs, rhs) {
        case let (l?, r?):
            return l < r
        case (_?, nil):
            return true
        case (nil, _?):
            return false
        case (nil, nil):
            return false
        }
    }
}
