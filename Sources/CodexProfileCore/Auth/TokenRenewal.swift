import Foundation

public struct RenewalPolicy: Sendable {
    public let renewAfter: TimeInterval

    public init(renewAfter: TimeInterval = 3 * 24 * 60 * 60) {
        self.renewAfter = renewAfter
    }

    public func isDue(lastRefresh: Date?, now: Date) -> Bool {
        guard let lastRefresh else { return true }

        // Five minutes absorbs normal clock skew; a larger future date signals invalid stored state.
        let materiallyFuture = lastRefresh.timeIntervalSince(now) > 5 * 60
        return materiallyFuture || now.timeIntervalSince(lastRefresh) >= self.renewAfter
    }
}

public struct TokenRefreshResponse: Sendable {
    public let accessToken: String?
    public let refreshToken: String?
    public let idToken: String?
    public let accountId: String?

    public init(
        accessToken: String? = nil,
        refreshToken: String? = nil,
        idToken: String? = nil,
        accountId: String? = nil
    ) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.idToken = idToken
        self.accountId = accountId
    }
}

public protocol TokenRefreshing: Sendable {
    func refresh(refreshToken: String) async throws -> TokenRefreshResponse
}

public enum TokenRenewalError: LocalizedError, Equatable {
    case rejected(String)
    case unreachable(String)

    public var errorDescription: String? {
        switch self {
        case .rejected(let message): return message
        case .unreachable(let message): return message
        }
    }
}

public struct URLSessionTokenRefresher: TokenRefreshing {
    private static var endpoint: URL {
        let environment = ProcessInfo.processInfo.environment
        let override = environment["CODEX_PROFILE_TEST_TOKEN_ENDPOINT"]
        let store = environment["CODEX_PROFILE_TEST_AUTH_STORE_DIR"]
        if let override,
           !override.isEmpty,
           let store,
           !store.isEmpty,
           let url = URL(string: override),
           let host = url.host?.lowercased(),
           ["127.0.0.1", "::1", "localhost"].contains(host) {
            // Tests may use only loopback for the override itself. That alone
            // does not stop a loopback server from answering with an HTTP
            // redirect to a remote host — `session` refuses every redirect (see
            // `RedirectRefusingDelegate` below), which is what actually keeps
            // the refresh token, sent in the POST body, from following one.
            return url
        }
        return URL(string: "https://auth.openai.com/oauth/token")!
    }
    private static let clientID = "app_EMoamEEZ73f0CkXaXp7hrann"
    // Matches the request measured working against this endpoint on 2026-08-17.
    // A rejected refresh here costs the credential, so the shape does not vary.
    private static let scope = "openid profile email"

    private let session: URLSession

    public init(session: URLSession = .shared) {
        // Wrap the given session's configuration in one that refuses redirects,
        // rather than using `session` directly: a redirect response otherwise
        // makes URLSession silently re-send the POST body — refresh token
        // included — to whatever host the redirect names.
        self.session = URLSession(
            configuration: session.configuration,
            delegate: RedirectRefusingDelegate(),
            delegateQueue: session.delegateQueue)
    }

    public func refresh(refreshToken: String) async throws -> TokenRefreshResponse {
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "client_id": Self.clientID,
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "scope": Self.scope,
        ])

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await self.session.data(for: request)
        } catch {
            throw TokenRenewalError.unreachable(error.localizedDescription)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw TokenRenewalError.unreachable("Token endpoint returned a non-HTTP response")
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            let message = Self.errorMessage(from: data, statusCode: httpResponse.statusCode)
            if [400, 401].contains(httpResponse.statusCode) {
                throw TokenRenewalError.rejected(message)
            }
            throw TokenRenewalError.unreachable(message)
        }

        do {
            return try JSONDecoder().decode(TokenRefreshResponse.self, from: data)
        } catch {
            throw TokenRenewalError.unreachable(
                "Invalid token endpoint response: " + error.localizedDescription)
        }
    }

    private static func errorMessage(from data: Data, statusCode: Int) -> String {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return "Token endpoint returned HTTP \(statusCode)"
        }
        let detail = (json["error_description"] as? String) ?? (json["error"] as? String)
        return detail.map { "HTTP \(statusCode): \($0)" } ?? "Token endpoint returned HTTP \(statusCode)"
    }
}

/// Refuses every HTTP redirect the token endpoint sends back. Without this,
/// `URLSession`'s default behavior re-sends the refresh POST — body and all —
/// to the redirect target, so a 3xx response silently hands the refresh token
/// (and, on success, reports the redirect target's response as a renewal) to
/// whatever host the redirect names. `completionHandler(nil)` makes the
/// original 3xx response terminate the task in place of following it.
private final class RedirectRefusingDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

extension TokenRefreshResponse: Decodable {
    private enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case idToken = "id_token"
        case accountId = "account_id"
    }
}

public enum TokenRenewal {
    public static func renew(
        credentials: AuthCredentials,
        using refresher: any TokenRefreshing
    ) async throws -> AuthCredentials {
        let response = try await refresher.refresh(refreshToken: credentials.refreshToken)
        return AuthCredentials(
            accessToken: response.accessToken ?? credentials.accessToken,
            refreshToken: response.refreshToken ?? credentials.refreshToken,
            idToken: response.idToken ?? credentials.idToken,
            accountId: response.accountId ?? credentials.accountId,
            lastRefresh: credentials.lastRefresh)
    }
}
