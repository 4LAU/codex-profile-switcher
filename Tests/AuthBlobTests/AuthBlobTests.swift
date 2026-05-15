@testable import CodexProfileCore
import Foundation
import Testing

enum TestFailure: Error, CustomStringConvertible {
    case failed(String)

    var description: String {
        switch self {
        case .failed(let message): return message
        }
    }
}

func fail(_ message: String) throws -> Never {
    throw TestFailure.failed(message)
}

func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() {
        try fail(message)
    }
}

func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: String) throws {
    if actual != expected {
        try fail("\(message) (expected \(expected), got \(actual))")
    }
}

func expectMissingTokens(_ body: () throws -> Void) throws {
    do {
        try body()
    } catch AuthError.missingTokens {
        return
    } catch {
        try fail("Expected AuthError.missingTokens, got \(error)")
    }
    try fail("Expected AuthError.missingTokens, but no error was thrown")
}

func jsonData(_ object: [String: Any]) throws -> Data {
    try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
}

func jsonObject(_ data: Data) throws -> [String: Any] {
    guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        try fail("JSON data was not an object")
    }
    return object
}

func base64URLJSON(_ object: [String: Any]) throws -> String {
    let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    return data.base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}

func idToken(
    subject: String = "user-123",
    email: String = "user@example.test",
    accountID: String = "acct-123"
) throws -> String {
    let header = try base64URLJSON(["alg": "RS256", "typ": "JWT"])
    let payload = try base64URLJSON([
        "sub": subject,
        "email": email,
        "https://api.openai.com/auth": "user",
        "https://api.openai.com/account_id": accountID,
        "https://api.openai.com/user_id": "usr-123",
        "https://api.openai.com/organization_id": "org-123",
        "exp": 1_800_000_000,
    ])
    return "\(header).\(payload).signature"
}

func oauthAuthData(
    accessToken: String = "access-token",
    refreshToken: String = "refresh-token",
    idToken: String,
    accountID: String = "acct-123",
    lastRefresh: String = "2026-05-13T10:15:30Z"
) throws -> Data {
    try jsonData([
        "tokens": [
            "access_token": accessToken,
            "refresh_token": refreshToken,
            "id_token": idToken,
            "account_id": accountID,
        ],
        "last_refresh": lastRefresh,
    ])
}

final class AuthBlobTests {
    
    
    @Test
    
    
    func testLoadsSnakeCaseOAuthAuth() throws {
        let token = try idToken()
        let data = try oauthAuthData(idToken: token)
        let creds = try AuthBlob.load(from: data)

        try expectEqual(creds.accessToken, "access-token", "Wrong access token")
        try expectEqual(creds.refreshToken, "refresh-token", "Wrong refresh token")
        try expectEqual(creds.idToken, token, "Wrong ID token")
        try expectEqual(creds.accountId, "acct-123", "Wrong account ID")
        try expect(creds.lastRefresh != nil, "Expected last_refresh to parse")
    }

    
    
    @Test

    
    
    func testLoadsCamelCaseLegacyOAuthAuth() throws {
        let token = try idToken(accountID: "acct-legacy")
        let data = try jsonData([
            "tokens": [
                "accessToken": "legacy-access",
                "refreshToken": "legacy-refresh",
                "idToken": token,
                "accountId": "acct-legacy",
            ],
            "last_refresh": "2026-05-13T10:15:30.123Z",
        ])

        let creds = try AuthBlob.load(from: data)
        try expectEqual(creds.accessToken, "legacy-access", "Wrong legacy access token")
        try expectEqual(creds.refreshToken, "legacy-refresh", "Wrong legacy refresh token")
        try expectEqual(creds.idToken, token, "Wrong legacy ID token")
        try expectEqual(creds.accountId, "acct-legacy", "Wrong legacy account ID")
        try expect(creds.lastRefresh != nil, "Expected fractional last_refresh to parse")
    }

    
    
    @Test

    
    
    func testLoadsAPIKeyAuth() throws {
        let fakeKey = ["sk", "test", "key", "1234567890"].joined(separator: "-")
        let data = try jsonData(["OPENAI_API_KEY": fakeKey])
        let creds = try AuthBlob.load(from: data)

        try expectEqual(creds.accessToken, fakeKey, "Wrong API key")
        try expectEqual(creds.refreshToken, "", "API key auth should not synthesize refresh token")
        try expect(creds.idToken == nil, "API key auth should not have ID token")
        try expect(creds.accountId == nil, "API key auth should not have account ID")
    }

    
    
    @Test

    
    
    func testRejectsMalformedAuth() throws {
        try expectMissingTokens {
            _ = try AuthBlob.load(from: try jsonData(["tokens": ["access_token": "access-only"]]))
        }
        let refreshOnly = try jsonData(["tokens": ["refresh_token": "refresh-only"]])
        try expect(!AuthBlob.isPlausibleAuthBlob(refreshOnly),
                   "Refresh-only auth should not be considered usable")
        try expect(AuthBlob.identityFingerprint(from: Data("{not-json".utf8)) == nil,
                   "Invalid JSON should not produce a fingerprint")
    }

    
    
    @Test

    
    
    func testUpdatedDataPreservesUnrelatedFields() throws {
        let oldToken = try idToken(accountID: "acct-old")
        let existing = try jsonData([
            "tokens": [
                "accessToken": "old-access",
                "refreshToken": "old-refresh",
                "idToken": oldToken,
                "accountId": "acct-old",
                "token_type": "Bearer",
            ],
            "custom_root_field": "keep-me",
        ])
        let refreshed = AuthCredentials(
            accessToken: "new-access",
            refreshToken: "new-refresh",
            idToken: try idToken(accountID: "acct-new"),
            accountId: "acct-new",
            lastRefresh: nil)
        let lastRefresh = Date(timeIntervalSince1970: 1_778_688_000)

        let updated = try AuthBlob.updatedData(from: existing, with: refreshed, lastRefresh: lastRefresh)
        let object = try jsonObject(updated)
        guard let tokens = object["tokens"] as? [String: Any] else {
            try fail("Updated auth did not contain tokens object")
        }

        try expectEqual(object["custom_root_field"] as? String, "keep-me", "Dropped unrelated root field")
        try expectEqual(tokens["token_type"] as? String, "Bearer", "Dropped unrelated token field")
        try expectEqual(tokens["access_token"] as? String, "new-access", "Did not save snake_case access token")
        try expectEqual(tokens["refresh_token"] as? String, "new-refresh", "Did not save snake_case refresh token")
        try expect(tokens["accessToken"] == nil, "Legacy camelCase access token should be removed")
        try expect(tokens["refreshToken"] == nil, "Legacy camelCase refresh token should be removed")
        try expect(object["last_refresh"] as? String != nil, "Missing last_refresh after update")
    }

    
    
    @Test

    
    
    func testFingerprintIgnoresRotatingOAuthTokenValues() throws {
        let token = try idToken(subject: "same-user", email: "same@example.test", accountID: "acct-same")
        let first = try oauthAuthData(accessToken: "access-1", refreshToken: "refresh-1", idToken: token)
        let second = try oauthAuthData(accessToken: "access-2", refreshToken: "refresh-2", idToken: token)

        try expectEqual(
            AuthBlob.identityFingerprint(from: first),
            AuthBlob.identityFingerprint(from: second),
            "OAuth fingerprint changed when only rotating token values changed")
    }

    
    
    @Test

    
    
    func testFingerprintUsesAccountIDWithoutIDToken() throws {
        let first = try jsonData([
            "tokens": [
                "access_token": "access-1",
                "refresh_token": "refresh-1",
                "account_id": "acct-fallback",
            ],
        ])
        let second = try jsonData([
            "tokens": [
                "access_token": "access-2",
                "refresh_token": "refresh-2",
                "account_id": "acct-fallback",
            ],
        ])
        let other = try jsonData([
            "tokens": [
                "access_token": "access-3",
                "refresh_token": "refresh-3",
                "account_id": "acct-other",
            ],
        ])

        try expect(AuthBlob.identityFingerprint(from: first) != nil, "OAuth account ID should produce fingerprint")
        try expectEqual(
            AuthBlob.identityFingerprint(from: first),
            AuthBlob.identityFingerprint(from: second),
            "OAuth account ID fingerprint changed when only rotating token values changed")
        try expect(
            AuthBlob.identityFingerprint(from: first) != AuthBlob.identityFingerprint(from: other),
            "Different OAuth account IDs should not share a fingerprint")
    }

    @Test
    func testFingerprintDistinguishesDifferentUsersWithSameAccountID() throws {
        let first = try oauthAuthData(
            idToken: try idToken(subject: "first-user", email: "first@example.test", accountID: "acct-shared"),
            accountID: "acct-shared")
        let second = try oauthAuthData(
            idToken: try idToken(subject: "second-user", email: "second@example.test", accountID: "acct-shared"),
            accountID: "acct-shared")

        try expect(
            AuthBlob.identityFingerprint(from: first) != AuthBlob.identityFingerprint(from: second),
            "Different OAuth users with the same account ID should not share a fingerprint")
    }

    @Test
    func testFingerprintDistinguishesSameUserWithDifferentAccountID() throws {
        let first = try oauthAuthData(
            idToken: try idToken(subject: "same-user", email: "same@example.test", accountID: "acct-first"),
            accountID: "acct-first")
        let second = try oauthAuthData(
            idToken: try idToken(subject: "same-user", email: "same@example.test", accountID: "acct-second"),
            accountID: "acct-second")

        try expect(
            AuthBlob.identityFingerprint(from: first) != AuthBlob.identityFingerprint(from: second),
            "Same OAuth user with different account IDs should not share a fingerprint")
    }

    
    
    @Test

    
    
    func testAPIKeyFingerprintDistinguishesKeys() throws {
        let first = try jsonData(["OPENAI_API_KEY": "sk-test-key-1111111111111111"])
        let second = try jsonData(["OPENAI_API_KEY": "sk-test-key-2222222222222222"])

        try expect(AuthBlob.identityFingerprint(from: first) != nil, "API key should produce fingerprint")
        try expect(AuthBlob.identityFingerprint(from: first) != AuthBlob.identityFingerprint(from: second),
                   "Different API keys should not share a fingerprint")
    }
}
