import Cocoa
import CodexProfileCore
import CryptoKit
import SwiftUI

// MARK: - Models

struct AuthIdentityDetails {
    enum Kind {
        case oauth
        case apiKey
    }

    let kind: Kind
    let email: String?
    let accountId: String?
    let userId: String?
    let organizationId: String?
    let subject: String?
    let lastRefresh: Date?
    let keyHash: String?

    var menuSummary: String {
        switch self.kind {
        case .oauth:
            if let email, !email.isEmpty { return email }
            if let accountId, !accountId.isEmpty { return shortIdentifier(accountId) }
            if let userId, !userId.isEmpty { return shortIdentifier(userId) }
            return "Saved OAuth account"
        case .apiKey:
            if let keyHash, !keyHash.isEmpty {
                return "API key \(shortHash(keyHash))"
            }
            return "Saved API key"
        }
    }

    var settingsTitle: String {
        switch self.kind {
        case .oauth:
            return self.email ?? "OAuth account"
        case .apiKey:
            return "API key login"
        }
    }

    var settingsDetails: String {
        var parts: [String] = []

        if let userId, !userId.isEmpty {
            parts.append("User \(shortIdentifier(userId))")
        }
        if let organizationId, !organizationId.isEmpty {
            parts.append("Org \(shortIdentifier(organizationId))")
        }
        if let subject, !subject.isEmpty, self.email == nil {
            parts.append("Sub \(shortIdentifier(subject))")
        }
        if let lastRefresh {
            parts.append("Refreshed \(DateFormatter.profileDetailTimestamp.string(from: lastRefresh))")
        }
        if self.kind == .apiKey, let keyHash, !keyHash.isEmpty {
            parts.append("Fingerprint \(shortHash(keyHash))")
        }

        return parts.isEmpty ? "No additional identity details" : parts.joined(separator: "  •  ")
    }
}

enum ProfileStatus {
    case available(UsageSnapshot)
    case loading
    case stale(UsageSnapshot?)
    case reloginNeeded(UsageSnapshot?)
    case notSetUp

    var snapshot: UsageSnapshot? {
        switch self {
        case .available(let s): return s
        case .stale(let s), .reloginNeeded(let s): return s
        default: return nil
        }
    }
}

enum UsageRefreshSource: String {
    case auto
    case oauth
    case cli
}

struct ProfileRefreshDiagnostics {
    var selectedMode: UsageRefreshSource = .auto
    var lastAttemptedSource: UsageRefreshSource?
    var lastSuccessfulSource: UsageRefreshSource?
    var lastFallbackReason: String?
    var lastDecision: String?
    var lastError: String?
}

enum OAuthFallbackReason: String {
    case usageUnauthorized = "oauth-unauthorized"
    case missingTokens = "oauth-missing-tokens"
    case refreshExpired = "refresh-expired"
    case refreshReused = "refresh-reused"
    case refreshRevoked = "refresh-revoked"
}

func dictStringValue(_ dict: [String: Any], _ keys: String...) -> String? {
    for key in keys {
        if let value = dict[key] as? String, !value.isEmpty { return value }
    }
    return nil
}

let iso8601WithFractional: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
}()

let iso8601Plain: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime]
    return f
}()

func parseISO8601Date(_ raw: Any?) -> Date? {
    guard let value = raw as? String, !value.isEmpty else { return nil }
    if let d = iso8601WithFractional.date(from: value) { return d }
    return iso8601Plain.date(from: value)
}

func shortIdentifier(_ value: String, head: Int = 10, tail: Int = 6) -> String {
    guard value.count > head + tail + 1 else { return value }
    let start = value.prefix(head)
    let end = value.suffix(tail)
    return "\(start)…\(end)"
}

func shortHash(_ value: String, head: Int = 6, tail: Int = 4) -> String {
    shortIdentifier(value, head: head, tail: tail)
}

extension DateFormatter {
    static let profileDetailTimestamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
}

func atomicWriteData(_ data: Data, to destination: URL) throws {
    try AtomicFileWriter.write(data, to: destination)
}

enum LiveAuthWarning: Equatable {
    case unmanaged
    case ambiguous

    var message: String {
        switch self {
        case .unmanaged: return "Live Codex auth is unmanaged"
        case .ambiguous: return "Live Codex auth matches multiple saved profiles"
        }
    }
}

enum ProfileMutationError: LocalizedError {
    case cannotClearActiveProfile
    case cannotRemoveActiveProfile

    var errorDescription: String? {
        switch self {
        case .cannotClearActiveProfile:
            return "Switch away from the active profile before clearing its saved auth."
        case .cannotRemoveActiveProfile:
            return "Switch away from the active profile before deleting it."
        }
    }
}

struct SettingsActionError: LocalizedError {
    let message: String

    var errorDescription: String? { self.message }
}
