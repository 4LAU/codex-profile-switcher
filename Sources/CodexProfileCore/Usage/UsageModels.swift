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
    public let availableResetCount: Int?

    public init(
        planType: String?,
        creditsRemaining: Double?,
        primaryUsedPercent: Int,
        primaryResetAt: Date?,
        secondaryUsedPercent: Int,
        secondaryResetAt: Date?,
        fetchedAt: Date,
        primaryWindowDurationMins: Int? = nil,
        secondaryWindowDurationMins: Int? = nil,
        availableResetCount: Int? = nil
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
        self.availableResetCount = availableResetCount
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

/// The outcome of one profile's renewal attempt. Defined here in Core rather
/// than privately in the CLI because it crosses a process boundary twice: the
/// CLI writes it into the renewal report the app parses, and into the
/// `renewalStates` cache the app reads on a later launch. Two private copies
/// of these strings would let the two sides drift silently — a case added on
/// one side would land in the other's `default` branch and do nothing, with
/// no compile error to catch it.
public enum RenewalAction: String, Codable, Sendable, CaseIterable {
    case renewed
    case skipped
    case rejected
    case unreachable
    case recovered
    /// The endpoint answered 200 but rotated nothing (empty response, or an
    /// empty-string token field). Deliberately distinct from `rejected`:
    /// unlike a 400/401 this does not indicate the refresh token itself is
    /// dead, so it must not feed the same "needs re-login" cache entry.
    case invalid
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

    /// `action` is stored as a raw string so a state written by a newer helper
    /// round-trips through an older app build intact. Nil means this build does
    /// not recognise the action.
    public var renewalAction: RenewalAction? {
        RenewalAction(rawValue: self.action)
    }

    private enum CodingKeys: String, CodingKey {
        case action, reason, timestamp, credentialFingerprint
    }

    /// Custom decode so a malformed `credentialFingerprint` (the only field
    /// added after this type's first release) doesn't condemn the whole
    /// `UsageCache` file to a failed decode. `action`, `reason`, and
    /// `timestamp` stay strictly required; `credentialFingerprint` tolerates
    /// being absent OR present-but-wrong-type, decoding to nil either way.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.action = try container.decode(String.self, forKey: .action)
        self.reason = try container.decode(String.self, forKey: .reason)
        self.timestamp = try container.decode(Date.self, forKey: .timestamp)
        self.credentialFingerprint = (try? container.decodeIfPresent(String.self, forKey: .credentialFingerprint)) ?? nil
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
