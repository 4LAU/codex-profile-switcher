import Foundation

/// Stable machine-readable report emitted by `codex-profile best-auth --json`.
///
/// The shape is a public contract — external tooling parses it — so field names
/// and semantics must remain stable. `candidates` lists every profile that was
/// considered (including the selected one). `fetched` is true when at least one
/// live usage fetch succeeded for this run. `snapshotAgeSeconds` is null when no
/// snapshot was available for a candidate.
public struct BestAuthReport: Codable, Equatable {
    public struct Candidate: Codable, Equatable {
        public let id: String
        public let tier: String
        public let score: Int
        public let snapshotAgeSeconds: Int?

        public init(id: String, tier: String, score: Int, snapshotAgeSeconds: Int?) {
            self.id = id
            self.tier = tier
            self.score = score
            self.snapshotAgeSeconds = snapshotAgeSeconds
        }

        private enum CodingKeys: String, CodingKey {
            case id, tier, score, snapshotAgeSeconds
        }

        // Always emit `snapshotAgeSeconds`, as explicit `null` when absent, so
        // the JSON shape is stable for consumers (the default encoder would omit
        // a nil optional entirely).
        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(self.id, forKey: .id)
            try container.encode(self.tier, forKey: .tier)
            try container.encode(self.score, forKey: .score)
            try container.encode(self.snapshotAgeSeconds, forKey: .snapshotAgeSeconds)
        }
    }

    public let selected: String
    public let tier: String
    public let score: Int
    public let candidates: [Candidate]
    public let fetched: Bool

    public init(
        selected: String,
        tier: String,
        score: Int,
        candidates: [Candidate],
        fetched: Bool
    ) {
        self.selected = selected
        self.tier = tier
        self.score = score
        self.candidates = candidates
        self.fetched = fetched
    }

    /// Encodes to compact, key-sorted JSON suitable for a single stdout line.
    public func jsonString() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(self)
        return String(decoding: data, as: UTF8.self)
    }
}

/// Human-readable name for a selector tier, used in the JSON report.
public extension ProfileCandidate.ProfileTier {
    var reportName: String {
        switch self {
        case .preferred: return "preferred"
        case .lastResort: return "lastResort"
        case .ineligible: return "exhausted"
        }
    }
}
