import Foundation

public struct UsageSnapshot: Codable, Equatable {
    public let planType: String?
    public let creditsRemaining: Double?
    public let primaryUsedPercent: Int
    public let primaryResetAt: Date?
    public let secondaryUsedPercent: Int
    public let secondaryResetAt: Date?
    public let fetchedAt: Date

    public init(
        planType: String?,
        creditsRemaining: Double?,
        primaryUsedPercent: Int,
        primaryResetAt: Date?,
        secondaryUsedPercent: Int,
        secondaryResetAt: Date?,
        fetchedAt: Date
    ) {
        self.planType = planType
        self.creditsRemaining = creditsRemaining
        self.primaryUsedPercent = primaryUsedPercent
        self.primaryResetAt = primaryResetAt
        self.secondaryUsedPercent = secondaryUsedPercent
        self.secondaryResetAt = secondaryResetAt
        self.fetchedAt = fetchedAt
    }
}

public struct ExhaustionOverride: Codable, Equatable {
    public let blockedUntil: Date
    public let reason: String
    public let source: String

    public init(blockedUntil: Date, reason: String, source: String) {
        self.blockedUntil = blockedUntil
        self.reason = reason
        self.source = source
    }

    public func isActive(now: Date = Date()) -> Bool {
        now < blockedUntil
    }
}

public struct UsageCache: Codable, Equatable {
    public var snapshots: [String: UsageSnapshot]
    public var exhaustionOverrides: [String: ExhaustionOverride]

    public init(
        snapshots: [String: UsageSnapshot],
        exhaustionOverrides: [String: ExhaustionOverride] = [:]
    ) {
        self.snapshots = snapshots
        self.exhaustionOverrides = exhaustionOverrides
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.snapshots = try container.decode([String: UsageSnapshot].self, forKey: .snapshots)
        self.exhaustionOverrides = try container.decodeIfPresent(
            [String: ExhaustionOverride].self,
            forKey: .exhaustionOverrides) ?? [:]
    }
}
