import Cocoa
import SwiftUI

// MARK: - Models

struct ProfileConfig: Codable, Identifiable {
    let id: String
    var label: String
}

struct AppConfig: Codable {
    var profiles: [ProfileConfig]
    var activeProfile: String
}

struct UsageSnapshot: Codable {
    let planType: String?
    let primaryUsedPercent: Int
    let primaryResetAt: Date?
    let secondaryUsedPercent: Int
    let secondaryResetAt: Date?
    let fetchedAt: Date
}

struct UsageCache: Codable {
    var snapshots: [String: UsageSnapshot]
}

enum ProfileStatus {
    case available(UsageSnapshot)
    case loading
    case stale(UsageSnapshot?)
    case reloginNeeded(UsageSnapshot?)
    case notSetUp
}

// MARK: - ProfileStore

final class ProfileStore {
    private let configDir: URL
    private let configURL: URL
    private let cacheURL: URL

    private(set) var config: AppConfig
    private(set) var cache: UsageCache
    var statuses: [String: ProfileStatus] = [:]

    init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        self.configDir = home.appendingPathComponent(".codex-switcher")
        self.configURL = self.configDir.appendingPathComponent("config.json")
        self.cacheURL = self.configDir.appendingPathComponent("cache.json")

        try? FileManager.default.createDirectory(at: self.configDir, withIntermediateDirectories: true)

        if let data = try? Data(contentsOf: self.configURL),
           let loaded = try? JSONDecoder().decode(AppConfig.self, from: data) {
            self.config = loaded
        } else {
            self.config = AppConfig(profiles: [], activeProfile: "1")
        }

        if let data = try? Data(contentsOf: self.cacheURL),
           let loaded = try? JSONDecoder().decode(UsageCache.self, from: data) {
            self.cache = loaded
        } else {
            self.cache = UsageCache(snapshots: [:])
        }

        if self.config.profiles.isEmpty {
            self.discoverProfiles()
        }

        for profile in self.config.profiles {
            if let cached = self.cache.snapshots[profile.id] {
                self.statuses[profile.id] = .stale(cached)
            } else if self.authFileExists(for: profile.id) {
                self.statuses[profile.id] = .loading
            } else {
                self.statuses[profile.id] = .notSetUp
            }
        }
    }

    func discoverProfiles() {
        var profiles: [ProfileConfig] = []

        for i in 1...8 {
            let id = "\(i)"
            let existing = self.config.profiles.first { $0.id == id }
            profiles.append(ProfileConfig(id: id, label: existing?.label ?? "Profile \(id)"))
        }

        self.config.profiles = profiles
        self.saveConfig()
    }

    func codexHome(for profileId: String) -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".codex-\(profileId)")
    }

    func authFilePath(for profileId: String) -> URL {
        self.codexHome(for: profileId).appendingPathComponent("auth.json")
    }

    func authFileExists(for profileId: String) -> Bool {
        FileManager.default.fileExists(atPath: self.authFilePath(for: profileId).path)
    }

    func setActiveProfile(_ id: String) {
        self.config.activeProfile = id
        self.saveConfig()
    }

    func updateLabel(for id: String, label: String) {
        if let idx = self.config.profiles.firstIndex(where: { $0.id == id }) {
            self.config.profiles[idx].label = label
            self.saveConfig()
        }
    }

    func updateStatus(_ id: String, _ status: ProfileStatus) {
        self.statuses[id] = status
        if case let .available(snapshot) = status {
            self.cache.snapshots[id] = snapshot
            self.saveCache()
        }
    }

    private func saveConfig() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(self.config) else { return }
        try? data.write(to: self.configURL, options: .atomic)
    }

    private func saveCache() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(self.cache) else { return }
        try? data.write(to: self.cacheURL, options: .atomic)
    }
}

// MARK: - Auth Credentials (adapted from codexbar)

struct AuthCredentials {
    let accessToken: String
    let refreshToken: String
    let idToken: String?
    let accountId: String?
    let lastRefresh: Date?

    var needsRefresh: Bool {
        guard let lastRefresh else { return true }
        let eightDays: TimeInterval = 8 * 24 * 60 * 60
        return Date().timeIntervalSince(lastRefresh) > eightDays
    }
}

enum AuthCredentialLoader {
    static func load(from url: URL) throws -> AuthCredentials {
        let data = try Data(contentsOf: url)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AuthError.decodeFailed
        }

        if let apiKey = json["OPENAI_API_KEY"] as? String,
           !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return AuthCredentials(
                accessToken: apiKey, refreshToken: "",
                idToken: nil, accountId: nil, lastRefresh: nil)
        }

        guard let tokens = json["tokens"] as? [String: Any] else {
            throw AuthError.missingTokens
        }

        guard let accessToken = stringVal(tokens, "access_token", "accessToken"),
              let refreshToken = stringVal(tokens, "refresh_token", "refreshToken"),
              !accessToken.isEmpty else {
            throw AuthError.missingTokens
        }

        let idToken = stringVal(tokens, "id_token", "idToken")
        let accountId = stringVal(tokens, "account_id", "accountId")
        let lastRefresh = parseLastRefresh(json["last_refresh"])

        return AuthCredentials(
            accessToken: accessToken, refreshToken: refreshToken,
            idToken: idToken, accountId: accountId, lastRefresh: lastRefresh)
    }

    static func save(_ creds: AuthCredentials, to url: URL) throws {
        let fd = open(url.path, O_RDWR | O_CREAT, 0o600)
        guard fd >= 0 else { throw AuthError.writeFailed }
        defer { close(fd) }

        guard flock(fd, LOCK_EX) == 0 else { throw AuthError.writeFailed }
        defer { flock(fd, LOCK_UN) }

        var existingJSON: [String: Any] = [:]
        let fileSize = lseek(fd, 0, SEEK_END)
        if fileSize > 0 {
            lseek(fd, 0, SEEK_SET)
            var buffer = [UInt8](repeating: 0, count: Int(fileSize))
            let bytesRead = read(fd, &buffer, Int(fileSize))
            if bytesRead > 0 {
                let data = Data(buffer[0..<bytesRead])
                if let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    existingJSON = parsed
                }
            }
        }

        var tokens: [String: Any] = [
            "access_token": creds.accessToken,
            "refresh_token": creds.refreshToken,
        ]
        if let idToken = creds.idToken { tokens["id_token"] = idToken }
        if let accountId = creds.accountId { tokens["account_id"] = accountId }
        existingJSON["tokens"] = tokens
        existingJSON["last_refresh"] = ISO8601DateFormatter().string(from: Date())

        let data = try JSONSerialization.data(withJSONObject: existingJSON, options: [.prettyPrinted, .sortedKeys])

        ftruncate(fd, 0)
        lseek(fd, 0, SEEK_SET)
        try data.withUnsafeBytes { ptr in
            var remaining = data.count
            var offset = 0
            while remaining > 0 {
                let written = Darwin.write(fd, ptr.baseAddress! + offset, remaining)
                guard written > 0 else { throw AuthError.writeFailed }
                offset += written
                remaining -= written
            }
        }
        fsync(fd)
    }

    private static func stringVal(_ dict: [String: Any], _ snake: String, _ camel: String) -> String? {
        if let v = dict[snake] as? String, !v.isEmpty { return v }
        if let v = dict[camel] as? String, !v.isEmpty { return v }
        return nil
    }

    private static func parseLastRefresh(_ raw: Any?) -> Date? {
        guard let value = raw as? String, !value.isEmpty else { return nil }
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = fmt.date(from: value) { return d }
        fmt.formatOptions = [.withInternetDateTime]
        return fmt.date(from: value)
    }
}

enum AuthError: LocalizedError {
    case notFound, decodeFailed, missingTokens, writeFailed
    case refreshExpired, refreshReused, refreshRevoked
    case networkError(Error), invalidResponse(String)

    var errorDescription: String? {
        switch self {
        case .notFound: return "auth.json not found"
        case .decodeFailed: return "Failed to decode auth.json"
        case .missingTokens: return "No tokens in auth.json"
        case .writeFailed: return "Failed to write auth.json"
        case .refreshExpired: return "Refresh token expired"
        case .refreshReused: return "Refresh token already used"
        case .refreshRevoked: return "Refresh token revoked"
        case .networkError(let e): return "Network error: \(e.localizedDescription)"
        case .invalidResponse(let m): return "Invalid response: \(m)"
        }
    }
}

// MARK: - Token Refresh (adapted from codexbar)

enum AuthRefresher {
    private static let endpoint = URL(string: "https://auth.openai.com/oauth/token")!
    private static let clientID = "app_EMoamEEZ73f0CkXaXp7hrann"

    static func refreshIfNeeded(
        profileId: String,
        activeProfileId: String,
        authFileURL: URL
    ) async throws -> AuthCredentials {
        let creds = try AuthCredentialLoader.load(from: authFileURL)

        guard profileId != activeProfileId else { return creds }
        guard creds.needsRefresh else { return creds }
        guard !creds.refreshToken.isEmpty else { return creds }

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

        try AuthCredentialLoader.save(refreshed, to: authFileURL)
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

// MARK: - App Entry Point (placeholder — will be completed in Task 8)

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!

    func applicationDidFinishLaunching(_ notification: Notification) {
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.statusItem.button?.title = "CPS"
    }
}

@main
enum Main {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}
