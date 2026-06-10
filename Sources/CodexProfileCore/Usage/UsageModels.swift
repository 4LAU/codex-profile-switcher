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
        now < self.blockedUntil
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

    /// Returns a copy of this cache with any exhaustion overrides found on disk
    /// (but absent in memory) merged back in. A concurrent writer
    /// (`mark-exhausted`) may have added overrides between our reads, so this
    /// keeps the upcoming write from clobbering them.
    ///
    /// The merge is purely additive: an override already present in this copy
    /// wins, and `self` is never mutated. Pass `excluding` to skip merging a
    /// specific profile's disk override — used when that profile's override was
    /// deliberately removed in memory, so the removal still sticks on disk while
    /// every other profile's concurrent override is preserved.
    public func mergingDiskOverrides(
        fromCacheAt url: URL,
        excluding excludedID: String? = nil,
        decoder: JSONDecoder
    ) -> UsageCache {
        guard let diskData = try? Data(contentsOf: url),
              let diskCache = try? decoder.decode(UsageCache.self, from: diskData) else {
            return self
        }
        var merged = self
        for (id, override) in diskCache.exhaustionOverrides
            where id != excludedID && merged.exhaustionOverrides[id] == nil {
            merged.exhaustionOverrides[id] = override
        }
        return merged
    }
}
