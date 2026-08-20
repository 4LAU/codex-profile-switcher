import CryptoKit
import Foundation

public struct AuthCredentials {
    public let accessToken: String
    public let refreshToken: String
    public let idToken: String?
    public let accountId: String?
    public let lastRefresh: Date?

    public init(
        accessToken: String,
        refreshToken: String,
        idToken: String?,
        accountId: String?,
        lastRefresh: Date?
    ) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.idToken = idToken
        self.accountId = accountId
        self.lastRefresh = lastRefresh
    }
}

public enum AuthError: LocalizedError {
    case notFound, decodeFailed, missingTokens, writeFailed
    case networkError(Error), invalidResponse(String)

    public var errorDescription: String? {
        switch self {
        case .notFound: return "auth.json not found"
        case .decodeFailed: return "Failed to decode auth.json"
        case .missingTokens: return "No tokens in auth.json"
        case .writeFailed: return "Failed to write auth.json"
        case .networkError(let e): return "Network error: \(e.localizedDescription)"
        case .invalidResponse(let m): return "Invalid response: \(m)"
        }
    }
}

public enum AuthBlob {
    public static func load(from data: Data) throws -> AuthCredentials {
        let json = try parseTopLevelObject(from: data)

        if let apiKey = nonEmptyString(json["OPENAI_API_KEY"]) {
            return AuthCredentials(
                accessToken: apiKey,
                refreshToken: "",
                idToken: nil,
                accountId: nil,
                lastRefresh: nil)
        }

        guard let tokens = json["tokens"] as? [String: Any],
              hasUsableOAuthTokenFields(tokens),
              let accessToken = tokenString(tokens, snakeCase: "access_token", camelCase: "accessToken"),
              let refreshToken = tokenString(tokens, snakeCase: "refresh_token", camelCase: "refreshToken") else {
            throw AuthError.missingTokens
        }

        return AuthCredentials(
            accessToken: accessToken,
            refreshToken: refreshToken,
            idToken: self.tokenString(tokens, snakeCase: "id_token", camelCase: "idToken"),
            accountId: self.tokenString(tokens, snakeCase: "account_id", camelCase: "accountId"),
            lastRefresh: self.parseLastRefresh(json["last_refresh"]))
    }

    public static func updatedData(
        from existingData: Data,
        with credentials: AuthCredentials,
        lastRefresh: Date = Date()
    ) throws -> Data {
        var json = try parseTopLevelObject(from: existingData)
        json["tokens"] = self.updatedTokens(
            preserving: json["tokens"] as? [String: Any],
            with: credentials)
        json["last_refresh"] = self.iso8601Fractional.string(from: lastRefresh)

        guard self.isPlausibleAuthBlob(json) else {
            throw AuthError.missingTokens
        }

        return try JSONSerialization.data(
            withJSONObject: json,
            options: [.prettyPrinted, .sortedKeys])
    }

    public static func isPlausibleAuthBlob(_ data: Data) -> Bool {
        guard let json = try? parseTopLevelObject(from: data) else { return false }
        return self.isPlausibleAuthBlob(json)
    }

    public static func identityFingerprint(from data: Data) -> String? {
        guard let json = try? parseTopLevelObject(from: data),
              let identity = authIdentity(from: json),
              JSONSerialization.isValidJSONObject(identity),
              let normalized = try? JSONSerialization.data(withJSONObject: identity, options: [.sortedKeys]) else {
            return nil
        }

        let digest = SHA256.hash(data: normalized)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Compares two blobs' identities by VALUE rather than by the shape of the
    /// whole identity dictionary. A refresh response that merely ADDS an
    /// identifying field (e.g. an `id_token` the stored blob never had) is not
    /// treated as an account change: only a differing value for a field present
    /// on BOTH sides counts as a mismatch. `identityFingerprint` hashes the
    /// entire dictionary and so cannot make this distinction — it flags any
    /// shape change as a different account, including a same-account rotation
    /// that only adds a field. At least one non-`kind` claim must match on both
    /// sides, or the comparison is inconclusive and returns false: `kind` alone
    /// (e.g. `"oauth"`) is shared by every OAuth blob, so a replacement that has
    /// dropped every distinguishing claim would otherwise vacuously match any
    /// other account's blob.
    public static func identityMatches(_ current: Data, _ replacement: Data) -> Bool {
        guard let currentJSON = try? parseTopLevelObject(from: current),
              let replacementJSON = try? parseTopLevelObject(from: replacement),
              let currentIdentity = authIdentity(from: currentJSON),
              let replacementIdentity = authIdentity(from: replacementJSON) else {
            return false
        }
        var matchedNonKindClaims = 0
        for (key, value) in currentIdentity {
            guard let replacementValue = replacementIdentity[key] else { continue }
            guard "\(value)" == "\(replacementValue)" else { return false }
            if key != "kind" {
                matchedNonKindClaims += 1
            }
        }
        return matchedNonKindClaims > 0
    }

    private static func parseTopLevelObject(from data: Data) throws -> [String: Any] {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AuthError.decodeFailed
        }
        return json
    }

    private static func updatedTokens(
        preserving existingTokens: [String: Any]?,
        with credentials: AuthCredentials
    ) -> [String: Any] {
        var tokens = existingTokens ?? [:]

        tokens["accessToken"] = nil
        tokens["refreshToken"] = nil
        tokens["idToken"] = nil
        tokens["accountId"] = nil

        tokens["access_token"] = credentials.accessToken
        tokens["refresh_token"] = credentials.refreshToken
        if let idToken = credentials.idToken {
            tokens["id_token"] = idToken
        } else {
            tokens["id_token"] = nil
        }
        if let accountId = credentials.accountId {
            tokens["account_id"] = accountId
        } else {
            tokens["account_id"] = nil
        }

        return tokens
    }

    private static func isPlausibleAuthBlob(_ json: [String: Any]) -> Bool {
        if self.nonEmptyString(json["OPENAI_API_KEY"]) != nil {
            return true
        }

        guard let tokens = json["tokens"] as? [String: Any] else {
            return false
        }
        return self.hasUsableOAuthTokenFields(tokens)
    }

    private static func hasUsableOAuthTokenFields(_ tokens: [String: Any]) -> Bool {
        self.tokenString(tokens, snakeCase: "access_token", camelCase: "accessToken") != nil
            && self.tokenString(tokens, snakeCase: "refresh_token", camelCase: "refreshToken") != nil
    }

    private static func tokenString(
        _ tokens: [String: Any],
        snakeCase: String,
        camelCase: String
    ) -> String? {
        self.nonEmptyString(tokens[snakeCase]) ?? self.nonEmptyString(tokens[camelCase])
    }

    private static func nonEmptyString(_ raw: Any?) -> String? {
        guard let value = raw as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static let iso8601Fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let iso8601Plain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static func parseLastRefresh(_ raw: Any?) -> Date? {
        guard let value = nonEmptyString(raw) else { return nil }
        if let date = iso8601Fractional.date(from: value) { return date }
        return self.iso8601Plain.date(from: value)
    }

    private static func authIdentity(from json: [String: Any]) -> [String: Any]? {
        if let apiKey = nonEmptyString(json["OPENAI_API_KEY"]) {
            let digest = SHA256.hash(data: Data(apiKey.utf8))
            return [
                "kind": "api-key",
                "keyHash": digest.map { String(format: "%02x", $0) }.joined(),
            ]
        }

        guard let tokens = json["tokens"] as? [String: Any] else { return nil }

        let accountId = self.tokenString(tokens, snakeCase: "account_id", camelCase: "accountId")
        let idToken = self.tokenString(tokens, snakeCase: "id_token", camelCase: "idToken")
        if var userIdentity = idToken.flatMap(userIdentity(fromIDToken:)) {
            if let accountId {
                userIdentity["accountId"] = accountId
            }
            return userIdentity
        }

        if let accountId {
            return [
                "kind": "oauth",
                "accountId": accountId,
            ]
        }

        return nil
    }

    private static func userIdentity(fromIDToken idToken: String) -> [String: Any]? {
        let parts = idToken.split(separator: ".")
        guard parts.count >= 2,
              let payloadData = base64URLDecode(String(parts[1])),
              let payload = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any] else {
            return nil
        }

        for key in ["sub", "https://api.openai.com/user_id"] {
            if let value = payload[key] as? String, !value.isEmpty {
                return [
                    "kind": "oauth",
                    "userId": value,
                ]
            }
        }

        if let email = payload["email"] as? String, !email.isEmpty {
            return [
                "kind": "oauth",
                "email": email.lowercased(),
            ]
        }

        return nil
    }

    private static func base64URLDecode(_ value: String) -> Data? {
        var base64 = value
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let padding = (4 - base64.count % 4) % 4
        base64.append(String(repeating: "=", count: padding))
        return Data(base64Encoded: base64)
    }
}
