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

public struct UsageCache: Codable, Equatable {
    public var snapshots: [String: UsageSnapshot]

    public init(snapshots: [String: UsageSnapshot]) {
        self.snapshots = snapshots
    }
}
