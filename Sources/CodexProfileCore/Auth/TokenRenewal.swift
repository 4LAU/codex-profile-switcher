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
    /// A 200 response that rotated nothing: either no token fields at all
    /// (coalescing back onto the existing credentials would silently
    /// reproduce them and get reported as a renewal), or a token field that
    /// is present but empty (which would replace a real stored token with
    /// "" and get discarded downstream, wasting the network round trip).
    /// Distinct from `.rejected` because we have not observed the refresh
    /// token itself being invalid — only that this response is unusable.
    case emptyResponse(String)

    public var errorDescription: String? {
        switch self {
        case .rejected(let message): return message
        case .unreachable(let message): return message
        case .emptyResponse(let message): return message
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

    /// Caps a SINGLE token request. `renew`'s watchdog bounds the whole run and
    /// calls `exit()`, so without a per-request cap one endpoint that accepts
    /// the connection and then never answers takes every other credential
    /// group's renewal down with it and strands the lease it reserved. The
    /// default `URLSessionConfiguration` does not supply this: its 60s
    /// `timeoutIntervalForRequest` measures the gap between packets, which a
    /// server trickling bytes never trips, and its `timeoutIntervalForResource`
    /// is seven days. 30s is well past a healthy response from this endpoint
    /// and well under the 120s run watchdog.
    public static let defaultRequestTimeout: TimeInterval = 30

    private let session: URLSession

    public init(
        session: URLSession = .shared,
        timeout: TimeInterval = Self.defaultRequestTimeout
    ) {
        // Wrap the given session's configuration in one that refuses redirects,
        // rather than using `session` directly: a redirect response otherwise
        // makes URLSession silently re-send the POST body — refresh token
        // included — to whatever host the redirect names. `configuration` hands
        // back a copy, so bounding it here cannot affect the caller's session.
        let configuration = session.configuration
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        self.session = URLSession(
            configuration: configuration,
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
        return detail.map { "HTTP \(statusCode): \(TokenRenewal.sanitizedExternalMessage($0))" }
            ?? "Token endpoint returned HTTP \(statusCode)"
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

        // A response that names neither token field rotates nothing. Left
        // alone, `?? credentials.*` below would coalesce it back onto the
        // existing credentials, reproduce them byte-for-byte, and still get
        // written with a fresh `last_refresh` stamp and reported as
        // "renewed" — resetting the credential's age without rotating
        // anything. `idToken`/`accountId` are identity fields, not renewal
        // fields, so their absence alone does not make a response empty.
        guard response.accessToken != nil || response.refreshToken != nil else {
            throw TokenRenewalError.emptyResponse(
                "Token endpoint returned no renewed credentials")
        }

        // A token field that is present but "" is non-nil, so it would also
        // survive the `?? credentials.*` coalescing and overwrite a real
        // stored token with an empty string — which `AuthBlob.updatedData`
        // then refuses to write (missingTokens), discarding this refresh
        // after the network call already spent it. Catch it here, before
        // the result is used, so the caller can tell this apart from a
        // network failure instead of silently replaying the same request.
        if let accessToken = response.accessToken, accessToken.isEmpty {
            throw TokenRenewalError.emptyResponse(
                "Token endpoint returned an empty access token")
        }
        if let refreshToken = response.refreshToken, refreshToken.isEmpty {
            throw TokenRenewalError.emptyResponse(
                "Token endpoint returned an empty refresh token")
        }

        // An endpoint that echoes BOTH tokens back unchanged also rotates
        // nothing, and the coalescing below cannot tell that apart from a
        // real renewal. Only the both-unchanged case counts: a non-rotating
        // refresh token returned alongside a fresh access token is a normal
        // OAuth renewal, not an empty one.
        let renewedAccessToken = response.accessToken ?? credentials.accessToken
        let renewedRefreshToken = response.refreshToken ?? credentials.refreshToken
        guard renewedAccessToken != credentials.accessToken
            || renewedRefreshToken != credentials.refreshToken else {
            throw TokenRenewalError.emptyResponse(
                "Token endpoint returned the existing credentials unchanged")
        }

        return AuthCredentials(
            accessToken: renewedAccessToken,
            refreshToken: renewedRefreshToken,
            idToken: response.idToken ?? credentials.idToken,
            accountId: response.accountId ?? credentials.accountId,
            lastRefresh: credentials.lastRefresh)
    }

    /// Caps how much of a server- or system-controlled message is allowed to
    /// propagate into `RenewalRecord.reason`, raw CLI stdout, and the durable
    /// renewal-state cache (`~/.codex-switcher`). Strips control characters
    /// (which includes embedded newlines/CR, so the message can't forge extra
    /// log lines or terminal escapes) and truncates to a sane length.
    public static func sanitizedExternalMessage(_ raw: String, maxLength: Int = 200) -> String {
        let stripped = String(raw.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) })
        let trimmed = stripped.trimmingCharacters(in: .whitespaces)
        guard trimmed.count > maxLength else { return trimmed }
        return String(trimmed.prefix(maxLength)) + "…"
    }
}
