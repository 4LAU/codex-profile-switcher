import Foundation

public enum AuthCredentialLoader {
    public static func load(from data: Data) throws -> AuthCredentials {
        try AuthBlob.load(from: data)
    }
}

// MARK: - Token Refresh (adapted from codexbar)

public enum AuthRefresher {
    private static let endpoint = URL(string: "https://auth.openai.com/oauth/token")!
    private static let clientID = "app_EMoamEEZ73f0CkXaXp7hrann"

    public static func refreshIfNeeded(
        profileId: String,
        activeProfileId: String,
        authData: Data,
        currentAuthData: () throws -> Data?,
        saveUpdatedAuthData: (Data) throws -> Void
    ) async throws -> AuthCredentials {
        let creds = try AuthCredentialLoader.load(from: authData)

        // Skip refresh for the active profile — Codex CLI manages its own auth.json at runtime.
        guard profileId != activeProfileId else { return creds }
        guard creds.needsRefresh else { return creds }
        guard !creds.refreshToken.isEmpty else { return creds }
        try Task.checkCancellation()
        CoreLogger.info("Refreshing inactive OAuth token", metadata: ["profile": profileId])

        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: String] = [
            "client_id": Self.clientID,
            "grant_type": "refresh_token",
            "refresh_token": creds.refreshToken,
            "scope": "openid profile email",
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse else {
            throw AuthError.invalidResponse("No HTTP response")
        }

        guard http.statusCode == 200 else {
            throw Self.mapError(statusCode: http.statusCode, data: data)
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AuthError.invalidResponse("Invalid JSON")
        }

        let refreshed = AuthCredentials(
            accessToken: json["access_token"] as? String ?? creds.accessToken,
            refreshToken: json["refresh_token"] as? String ?? creds.refreshToken,
            idToken: json["id_token"] as? String ?? creds.idToken,
            accountId: creds.accountId,
            lastRefresh: Date())

        guard let currentData = try currentAuthData() else {
            throw AuthError.notFound
        }
        let current = try AuthCredentialLoader.load(from: currentData)
        guard current.refreshToken == creds.refreshToken else {
            CoreLogger.warning("Skipped OAuth token refresh save because auth changed",
                              metadata: ["profile": profileId])
            return current
        }
        try Task.checkCancellation()
        let updatedData = try AuthBlob.updatedData(from: currentData, with: refreshed)
        try saveUpdatedAuthData(updatedData)
        CoreLogger.info("OAuth token refresh succeeded", metadata: ["profile": profileId])
        return refreshed
    }

    private static func mapError(statusCode: Int, data: Data) -> AuthError {
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let code: String? =
                (json["error"] as? [String: Any])?["code"] as? String
                ?? json["error"] as? String
                ?? json["code"] as? String

            switch code?.lowercased() {
            case "refresh_token_expired": return .refreshExpired
            case "refresh_token_reused": return .refreshReused
            case "invalid_grant", "refresh_token_invalidated": return .refreshRevoked
            default: break
            }
        }
        if statusCode == 401 { return .refreshExpired }
        return .invalidResponse("Status \(statusCode)")
    }
}
