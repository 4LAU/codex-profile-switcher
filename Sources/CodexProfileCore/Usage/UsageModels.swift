import Foundation

public struct UsageSnapshot: Codable, Equatable {
    public let planType: String?
    public let creditsRemaining: Double?
    public let primaryUsedPercent: Int
    public let primaryResetAt: Date?
    public let secondaryUsedPercent: Int
    public let secondaryResetAt: Date?
    public let fetchedAt: Date
    public let primaryWindowDurationMins: Int?
    public let secondaryWindowDurationMins: Int?

    public init(
        planType: String?,
        creditsRemaining: Double?,
        primaryUsedPercent: Int,
        primaryResetAt: Date?,
        secondaryUsedPercent: Int,
        secondaryResetAt: Date?,
        fetchedAt: Date,
        primaryWindowDurationMins: Int? = nil,
        secondaryWindowDurationMins: Int? = nil
    ) {
        self.planType = planType
        self.creditsRemaining = creditsRemaining
        self.primaryUsedPercent = primaryUsedPercent
        self.primaryResetAt = primaryResetAt
        self.secondaryUsedPercent = secondaryUsedPercent
        self.secondaryResetAt = secondaryResetAt
        self.fetchedAt = fetchedAt
        self.primaryWindowDurationMins = primaryWindowDurationMins
        self.secondaryWindowDurationMins = secondaryWindowDurationMins
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

public struct RenewalState: Codable, Equatable {
    public let action: String
    public let reason: String
    public let timestamp: Date

    public init(action: String, reason: String, timestamp: Date) {
        self.action = action
        self.reason = reason
        self.timestamp = timestamp
    }
}

/// A short-lived reservation of a profile by a warm `codex-profile lease`
/// session, recorded in the cache (keyed by profile ID) so concurrent runs
/// never select the same account. Mirrors the ExhaustionOverride TTL pattern.
/// `home` is the absolute path of the seeded throwaway Codex home, recorded so
/// `lease gc` can find and remove an orphaned home after a crash. `token`
/// identifies the lease across its lifecycle (begin → swap → end).
public struct LeaseReservation: Codable, Equatable {
    public let token: String
    public let home: String
    public let expiresAt: Date
    public let createdAt: Date

    public init(token: String, home: String, expiresAt: Date, createdAt: Date) {
        self.token = token
        self.home = home
        self.expiresAt = expiresAt
        self.createdAt = createdAt
    }

    public func isActive(now: Date = Date()) -> Bool {
        now < self.expiresAt
    }
}

public struct UsageCache: Codable, Equatable {
    public var snapshots: [String: UsageSnapshot]
    public var exhaustionOverrides: [String: ExhaustionOverride]
    public var leases: [String: LeaseReservation]
    public var renewalStates: [String: RenewalState]

    public init(
        snapshots: [String: UsageSnapshot],
        exhaustionOverrides: [String: ExhaustionOverride] = [:],
        leases: [String: LeaseReservation] = [:],
        renewalStates: [String: RenewalState] = [:]
    ) {
        self.snapshots = snapshots
        self.exhaustionOverrides = exhaustionOverrides
        self.leases = leases
        self.renewalStates = renewalStates
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.snapshots = try container.decode([String: UsageSnapshot].self, forKey: .snapshots)
        self.exhaustionOverrides = try container.decodeIfPresent(
            [String: ExhaustionOverride].self,
            forKey: .exhaustionOverrides) ?? [:]
        self.leases = try container.decodeIfPresent(
            [String: LeaseReservation].self,
            forKey: .leases) ?? [:]
        self.renewalStates = try container.decodeIfPresent(
            [String: RenewalState].self,
            forKey: .renewalStates) ?? [:]
    }

    /// Returns a copy of this cache reconciled with on-disk state before a write.
    ///
    /// Exhaustion overrides merge ADDITIVELY (an override already present in this
    /// copy wins; a concurrent `mark-exhausted`'s disk override is preserved).
    /// Pass `excluding` to skip merging a specific profile's disk override — used
    /// when that override was deliberately removed in memory so the removal sticks.
    ///
    /// Leases are taken from DISK VERBATIM, never merged in-memory-wins. A writer
    /// only ever legitimately knows the ONE lease it is currently mutating, never
    /// the whole map; a stale in-memory `leases` (e.g. the long-lived menu-bar app
    /// cache, or any reader that held the cache across a lease's lifetime) must
    /// NOT be able to resurrect a lease that was ended on disk. So non-lease
    /// writers get disk leases unchanged, and the lease commands re-apply their
    /// single add/remove delta on top of this reconciled copy.
    ///
    /// Renewal states follow the same disk-authoritative rule. A writer that
    /// changes one profile's state must re-apply that single-profile delta
    /// after this merge.
    ///
    /// `self` is never mutated.
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
        merged.leases = diskCache.leases
        merged.renewalStates = diskCache.renewalStates
        return merged
    }
}
