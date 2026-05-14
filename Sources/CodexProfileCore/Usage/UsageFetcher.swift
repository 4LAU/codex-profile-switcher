import Foundation

// MARK: - Usage API (adapted from codexbar)

public struct UsageResponse: Decodable {
    public let planType: String?
    public let rateLimit: RateLimitInfo?
    public let credits: CreditInfo?

    enum CodingKeys: String, CodingKey {
        case planType = "plan_type"
        case rateLimit = "rate_limit"
        case credits
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.planType = try container.decodeIfPresent(String.self, forKey: .planType)
        self.rateLimit = try container.decodeIfPresent(RateLimitInfo.self, forKey: .rateLimit)
        self.credits = try? container.decodeIfPresent(CreditInfo.self, forKey: .credits)
    }

    public struct RateLimitInfo: Decodable {
        public let primaryWindow: WindowInfo?
        public let secondaryWindow: WindowInfo?

        enum CodingKeys: String, CodingKey {
            case primaryWindow = "primary_window"
            case secondaryWindow = "secondary_window"
        }
    }

    public struct WindowInfo: Decodable {
        public let usedPercent: Int
        public let resetAt: Int

        enum CodingKeys: String, CodingKey {
            case usedPercent = "used_percent"
            case resetAt = "reset_at"
        }
    }

    public struct CreditInfo: Decodable {
        public let balance: Double?

        enum CodingKeys: String, CodingKey {
            case balance
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            if let value = try? container.decode(Double.self, forKey: .balance) {
                self.balance = value
            } else if let raw = try? container.decode(String.self, forKey: .balance),
                      let value = Double(raw.replacingOccurrences(of: ",", with: "")) {
                self.balance = value
            } else {
                self.balance = nil
            }
        }
    }
}

public enum UsageFetcher {
    private static let usageURL = URL(string: "https://chatgpt.com/backend-api/wham/usage")!

    public static func fetch(accessToken: String, accountId: String?) async throws -> UsageResponse {
        var request = URLRequest(url: Self.usageURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 30
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let accountId, !accountId.isEmpty {
            request.setValue(accountId, forHTTPHeaderField: "ChatGPT-Account-Id")
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw UsageFetchError.invalidResponse
        }

        switch http.statusCode {
        case 200...299:
            return try JSONDecoder().decode(UsageResponse.self, from: data)
        case 401, 403:
            CoreLogger.warning("Usage API unauthorized", metadata: ["status": "\(http.statusCode)"])
            throw UsageFetchError.unauthorized
        default:
            CoreLogger.warning("Usage API server error", metadata: ["status": "\(http.statusCode)"])
            throw UsageFetchError.serverError(http.statusCode)
        }
    }
}

public enum UsageFetchError: LocalizedError, Equatable {
    case unauthorized, invalidResponse, serverError(Int)

    public var errorDescription: String? {
        switch self {
        case .unauthorized: return "Token expired or invalid"
        case .invalidResponse: return "Invalid API response"
        case .serverError(let c): return "Server error: \(c)"
        }
    }
}
