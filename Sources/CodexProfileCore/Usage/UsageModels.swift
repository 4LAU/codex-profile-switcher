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
    /// The renewed credential's fingerprint (the CLI's `renewalCredentialFingerprint`:
    /// SHA-256(refresh token), first 12 hex chars) at the moment this state was
    /// recorded. For a "rejected" state this is the fingerprint of the specific
    /// credential that was condemned, so a later `codex-profile login` that
    /// replaces the refresh token can be detected and the rejection cleared.
    /// Nil for states written before this field existed.
    public let credentialFingerprint: String?

    public init(action: String, reason: String, timestamp: Date, credentialFingerprint: String? = nil) {
        self.action = action
        self.reason = reason
        self.timestamp = timestamp
        self.credentialFingerprint = credentialFingerprint
    }
}

/// Records the outcome of the most recent `codex-profile renew` invocation
/// the app observed, so a nightly job that silently stops working looks
/// different from a healthy one instead of looking identical to it.
public struct LastRenewalRun: Codable, Equatable {
    public let timestamp: Date
    /// The process exit status. Nil means the helper could not even be
    /// launched (e.g. `codex-profile` was not found).
    public let exitStatus: Int32?
    /// Number of per-profile records in the run's report. Nil when the
    /// report could not be parsed.
    public let recordCount: Int?

    public init(timestamp: Date, exitStatus: Int32?, recordCount: Int?) {
        self.timestamp = timestamp
        self.exitStatus = exitStatus
        self.recordCount = recordCount
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
    public var lastRenewalRun: LastRenewalRun?

    public init(
        snapshots: [String: UsageSnapshot],
        exhaustionOverrides: [String: ExhaustionOverride] = [:],
        leases: [String: LeaseReservation] = [:],
        renewalStates: [String: RenewalState] = [:],
        lastRenewalRun: LastRenewalRun? = nil
    ) {
        self.snapshots = snapshots
        self.exhaustionOverrides = exhaustionOverrides
        self.leases = leases
        self.renewalStates = renewalStates
        self.lastRenewalRun = lastRenewalRun
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
        self.lastRenewalRun = try container.decodeIfPresent(
            LastRenewalRun.self,
            forKey: .lastRenewalRun)
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
    /// `lastRenewalRun` follows the same disk-authoritative rule as leases and
    /// renewal states: it can be written by either the app (an app-launch
    /// renewal) or the CLI (the nightly LaunchAgent renewal) as a separate
    /// process, so an in-memory copy is never trusted over disk. A writer that
    /// changes it must re-apply that delta after this merge.
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
        merged.lastRenewalRun = diskCache.lastRenewalRun
        return merged
    }
}
