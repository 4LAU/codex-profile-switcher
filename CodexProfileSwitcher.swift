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

    var snapshot: UsageSnapshot? {
        switch self {
        case .available(let s): return s
        case .stale(let s), .reloginNeeded(let s): return s
        default: return nil
        }
    }
}

// MARK: - ProfileStore

final class ProfileStore {
    private let configDir: URL
    private let configURL: URL
    private let cacheURL: URL

    private(set) var config: AppConfig
    private(set) var cache: UsageCache
    private(set) var statuses: [String: ProfileStatus] = [:]

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

        if let data = try? Data(contentsOf: self.cacheURL) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            self.cache = (try? decoder.decode(UsageCache.self, from: data)) ?? UsageCache(snapshots: [:])
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

// MARK: - Usage API (adapted from codexbar)

struct UsageResponse: Decodable {
    let planType: String?
    let rateLimit: RateLimitInfo?

    enum CodingKeys: String, CodingKey {
        case planType = "plan_type"
        case rateLimit = "rate_limit"
    }

    struct RateLimitInfo: Decodable {
        let primaryWindow: WindowInfo?
        let secondaryWindow: WindowInfo?

        enum CodingKeys: String, CodingKey {
            case primaryWindow = "primary_window"
            case secondaryWindow = "secondary_window"
        }
    }

    struct WindowInfo: Decodable {
        let usedPercent: Int
        let resetAt: Int
        let limitWindowSeconds: Int

        enum CodingKeys: String, CodingKey {
            case usedPercent = "used_percent"
            case resetAt = "reset_at"
            case limitWindowSeconds = "limit_window_seconds"
        }
    }
}

enum UsageFetcher {
    private static let usageURL = URL(string: "https://chatgpt.com/backend-api/wham/usage")!

    static func fetch(accessToken: String, accountId: String?) async throws -> UsageResponse {
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
            throw UsageFetchError.unauthorized
        default:
            throw UsageFetchError.serverError(http.statusCode)
        }
    }
}

enum UsageFetchError: LocalizedError, Equatable {
    case unauthorized, invalidResponse, serverError(Int)

    var errorDescription: String? {
        switch self {
        case .unauthorized: return "Token expired or invalid"
        case .invalidResponse: return "Invalid API response"
        case .serverError(let c): return "Server error: \(c)"
        }
    }
}

// MARK: - UsageProvider

final class UsageProvider {
    private let store: ProfileStore
    private var activeRefreshTask: Task<Void, Never>?
    private var lastRefreshAll: Date = .distantPast
    var onRefreshComplete: (() -> Void)?

    init(store: ProfileStore) {
        self.store = store
    }

    func refreshAll(force: Bool = false) {
        guard force || Date().timeIntervalSince(self.lastRefreshAll) > 60 else { return }
        self.lastRefreshAll = Date()
        self.activeRefreshTask?.cancel()
        self.activeRefreshTask = Task {
            await withTaskGroup(of: Void.self) { group in
                for profile in self.store.config.profiles {
                    group.addTask { await self.refreshProfile(profile.id) }
                }
            }
            await MainActor.run { self.onRefreshComplete?() }
        }
    }

    func refreshActive() {
        let id = self.store.config.activeProfile
        Task {
            await self.refreshProfile(id)
            await MainActor.run { self.onRefreshComplete?() }
        }
    }

    private func refreshProfile(_ id: String) async {
        let authURL = self.store.authFilePath(for: id)
        guard FileManager.default.fileExists(atPath: authURL.path) else {
            await MainActor.run { self.store.updateStatus(id, .notSetUp) }
            return
        }

        let cached = self.store.cache.snapshots[id]

        do {
            let creds = try await AuthRefresher.refreshIfNeeded(
                profileId: id,
                activeProfileId: self.store.config.activeProfile,
                authFileURL: authURL)

            let response = try await UsageFetcher.fetch(
                accessToken: creds.accessToken,
                accountId: creds.accountId)

            let snapshot = UsageSnapshot(
                planType: response.planType,
                primaryUsedPercent: response.rateLimit?.primaryWindow?.usedPercent ?? 0,
                primaryResetAt: response.rateLimit?.primaryWindow.map {
                    Date(timeIntervalSince1970: TimeInterval($0.resetAt))
                },
                secondaryUsedPercent: response.rateLimit?.secondaryWindow?.usedPercent ?? 0,
                secondaryResetAt: response.rateLimit?.secondaryWindow.map {
                    Date(timeIntervalSince1970: TimeInterval($0.resetAt))
                },
                fetchedAt: Date())

            await MainActor.run { self.store.updateStatus(id, .available(snapshot)) }
        } catch is CancellationError {
            return
        } catch let error as UsageFetchError where error == .unauthorized {
            await MainActor.run { self.store.updateStatus(id, .reloginNeeded(cached)) }
        } catch let error as AuthError {
            switch error {
            case .refreshExpired, .refreshReused, .refreshRevoked:
                await MainActor.run { self.store.updateStatus(id, .reloginNeeded(cached)) }
            case .notFound:
                await MainActor.run { self.store.updateStatus(id, .notSetUp) }
            default:
                await MainActor.run { self.store.updateStatus(id, .stale(cached)) }
            }
        } catch {
            await MainActor.run { self.store.updateStatus(id, .stale(cached)) }
        }
    }
}

// MARK: - Helpers

func resetCountdown(from date: Date?) -> String {
    guard let date, date > Date() else { return "" }
    let diff = Int(date.timeIntervalSinceNow)
    let days = diff / 86400
    let hours = (diff % 86400) / 3600
    let mins = (diff % 3600) / 60
    if days > 0 { return "\(days)d\(hours)h" }
    if hours > 0 { return "\(hours)h\(mins)m" }
    return "\(mins)m"
}

func progressColor(for percent: Int) -> Color {
    if percent >= 80 { return .red }
    if percent >= 50 { return .orange }
    return .green
}

func planDisplayName(_ raw: String?) -> String {
    guard let raw, !raw.isEmpty else { return "" }
    switch raw {
    case "pro": return "Pro"
    case "plus": return "Plus"
    case "team": return "Team"
    case "business": return "Business"
    case "enterprise": return "Enterprise"
    case "free": return "Free"
    case "edu", "education": return "Edu"
    default: return raw.capitalized
    }
}

// MARK: - SwiftUI Views (progress bar adapted from codexbar)

struct UsageBar: View {
    let percent: Double
    let tint: Color

    var body: some View {
        Canvas { context, size in
            let fillWidth = size.width * min(100, max(0, self.percent)) / 100
            let cornerRadius = size.height / 2
            let cornerSize = CGSize(width: cornerRadius, height: cornerRadius)
            let rect = CGRect(origin: .zero, size: size)

            let trackPath = Path { p in p.addRoundedRect(in: rect, cornerSize: cornerSize) }
            context.fill(trackPath, with: .color(.gray.opacity(0.25)))

            if fillWidth > 0 {
                let fillRect = CGRect(x: 0, y: 0, width: min(fillWidth, size.width), height: size.height)
                let fillPath = Path { p in p.addRoundedRect(in: fillRect, cornerSize: cornerSize) }
                context.fill(fillPath, with: .color(self.tint))
            }
        }
        .frame(height: 6)
    }
}

struct UsageRow: View {
    let label: String
    let percent: Int
    let resetAt: Date?

    var body: some View {
        HStack(spacing: 6) {
            Text(self.label)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 22, alignment: .leading)

            UsageBar(percent: Double(self.percent), tint: progressColor(for: self.percent))
                .frame(width: 160)

            Text("\(self.percent)%")
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 32, alignment: .trailing)

            Text(resetCountdown(from: self.resetAt))
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.tertiary)
                .frame(width: 40, alignment: .trailing)
        }
    }
}

struct ProfileCardView: View {
    let profile: ProfileConfig
    let status: ProfileStatus
    let isActive: Bool
    let onSwitch: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            self.headerRow
            self.statusContent
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(width: 310, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture { self.onSwitch() }
    }

    private var headerRow: some View {
        HStack(spacing: 6) {
            if self.isActive {
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.primary)
            } else {
                Spacer().frame(width: 13)
            }

            Text("\(self.profile.id)")
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(.secondary)

            Text(self.profile.label)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)

            Spacer()

            if let planName = self.planType {
                Text(planName)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.gray.opacity(0.15))
                    .cornerRadius(4)
            }
        }
    }

    @ViewBuilder
    private var statusContent: some View {
        switch self.status {
        case .available(let snap):
            self.usageBars(snap)
        case .loading:
            Text("Refreshing...")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .padding(.leading, 19)
        case .stale(let snap):
            if let snap {
                self.usageBars(snap)
                Text("Data may be stale")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .padding(.leading, 19)
            } else {
                Text("No data yet")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 19)
            }
        case .reloginNeeded(let snap):
            if let snap { self.usageBars(snap) }
            Text("Re-login needed")
                .font(.system(size: 10))
                .foregroundStyle(.red)
                .padding(.leading, 19)
        case .notSetUp:
            Text("Not set up — click to set up")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .padding(.leading, 19)
        }
    }

    private func usageBars(_ snap: UsageSnapshot) -> some View {
        VStack(spacing: 2) {
            UsageRow(label: "5h", percent: snap.primaryUsedPercent, resetAt: snap.primaryResetAt)
            UsageRow(label: "Wk", percent: snap.secondaryUsedPercent, resetAt: snap.secondaryResetAt)
        }
        .padding(.leading, 19)
    }

    private var planType: String? {
        guard let snap = self.status.snapshot else { return nil }
        return planDisplayName(snap.planType)
    }
}

// MARK: - Menu Bar Icon

enum IconRenderer {
    static let iconSize = CGSize(width: 18, height: 18)
    private static let scale: CGFloat = 2

    static func render(primaryPercent: Int, secondaryPercent: Int) -> NSImage {
        let size = Self.iconSize

        let image = NSImage(size: size, flipped: false) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            ctx.scaleBy(x: Self.scale, y: Self.scale)

            let barWidth: CGFloat = 12
            let barHeight: CGFloat = 3
            let barX: CGFloat = (size.width - barWidth) / 2
            let gap: CGFloat = 2
            let totalHeight = barHeight * 2 + gap
            let startY = (size.height - totalHeight) / 2

            Self.drawCapsule(ctx: ctx, x: barX, y: startY + barHeight + gap,
                             width: barWidth, height: barHeight,
                             fillPercent: max(0, 100 - primaryPercent))

            Self.drawCapsule(ctx: ctx, x: barX, y: startY,
                             width: barWidth, height: barHeight,
                             fillPercent: max(0, 100 - secondaryPercent))

            return true
        }

        image.isTemplate = true
        return image
    }

    static func renderEmpty() -> NSImage {
        Self.render(primaryPercent: 100, secondaryPercent: 100)
    }

    private static func drawCapsule(
        ctx: CGContext, x: CGFloat, y: CGFloat,
        width: CGFloat, height: CGFloat, fillPercent: Int
    ) {
        let radius = height / 2
        let trackRect = CGRect(x: x, y: y, width: width, height: height)
        let trackPath = CGPath(roundedRect: trackRect, cornerWidth: radius, cornerHeight: radius, transform: nil)

        ctx.setFillColor(NSColor.gray.withAlphaComponent(0.4).cgColor)
        ctx.addPath(trackPath)
        ctx.fillPath()

        let fillWidth = width * CGFloat(min(100, max(0, fillPercent))) / 100
        if fillWidth > 0 {
            let fillRect = CGRect(x: x, y: y, width: fillWidth, height: height)
            let fillPath = CGPath(roundedRect: fillRect, cornerWidth: radius, cornerHeight: radius, transform: nil)
            ctx.setFillColor(NSColor.black.cgColor)
            ctx.addPath(fillPath)
            ctx.fillPath()
        }
    }
}

// MARK: - CodexBridge (shells out to codex-profile wrapper)

enum CodexBridge {
    private static var activeLogins: Set<String> = []

    private static func codexProfilePath() -> String? {
        let candidates: [String?] = [
            Bundle.main.executableURL?
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("bin/codex-profile").path,
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".local/bin/codex-profile").path,
        ]
        return candidates.compactMap { $0 }.first {
            FileManager.default.isExecutableFile(atPath: $0)
        }
    }

    static func switchToProfile(_ profileId: String) async -> Bool {
        await withCheckedContinuation { continuation in
            guard let path = Self.codexProfilePath() else {
                continuation.resume(returning: false)
                return
            }
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: path)
            proc.arguments = ["app", profileId]
            proc.standardOutput = FileHandle.nullDevice
            proc.standardError = FileHandle.nullDevice
            proc.terminationHandler = { p in
                continuation.resume(returning: p.terminationStatus == 0)
            }
            do {
                try proc.run()
            } catch {
                continuation.resume(returning: false)
            }
        }
    }

    static func startLogin(profileId: String, completion: @escaping (Bool) -> Void) {
        guard !Self.activeLogins.contains(profileId) else { return }
        guard let path = Self.codexProfilePath() else {
            completion(false)
            return
        }

        Self.activeLogins.insert(profileId)

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: path)
        proc.arguments = ["login", profileId]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice

        proc.terminationHandler = { p in
            DispatchQueue.main.async {
                Self.activeLogins.remove(profileId)
                completion(p.terminationStatus == 0)
            }
        }

        do {
            try proc.run()
        } catch {
            Self.activeLogins.remove(profileId)
            completion(false)
        }
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var store: ProfileStore!
    private var usageProvider: UsageProvider!
    private var activeRefreshTimer: Timer?
    private var menu: NSMenu!

    func applicationDidFinishLaunching(_ notification: Notification) {
        self.store = ProfileStore()
        self.usageProvider = UsageProvider(store: self.store)

        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.statusItem.button?.image = IconRenderer.renderEmpty()
        self.statusItem.button?.imageScaling = .scaleNone

        self.menu = NSMenu()
        self.menu.delegate = self
        self.statusItem.menu = self.menu

        self.usageProvider.onRefreshComplete = { [weak self] in self?.updateIcon() }
        self.usageProvider.refreshAll()
        self.startActiveProfileTimer()
    }

    // MARK: - NSMenuDelegate

    func menuWillOpen(_ menu: NSMenu) {
        self.rebuildMenu()
        self.usageProvider.refreshAll()
    }

    // MARK: - Timer

    private func startActiveProfileTimer() {
        self.activeRefreshTimer?.invalidate()
        self.activeRefreshTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            self?.usageProvider.refreshActive()
            self?.updateIcon()
        }
    }

    // MARK: - Icon

    func updateIcon() {
        let activeId = self.store.config.activeProfile
        if let snap = self.store.statuses[activeId]?.snapshot {
            self.statusItem.button?.image = IconRenderer.render(
                primaryPercent: snap.primaryUsedPercent,
                secondaryPercent: snap.secondaryUsedPercent)
        } else {
            self.statusItem.button?.image = IconRenderer.renderEmpty()
        }
    }

    // MARK: - Menu Construction

    private func rebuildMenu() {
        self.menu.removeAllItems()

        for profile in self.store.config.profiles {
            let isActive = profile.id == self.store.config.activeProfile
            let status = self.store.statuses[profile.id] ?? .notSetUp

            let cardView = ProfileCardView(
                profile: profile,
                status: status,
                isActive: isActive,
                onSwitch: { [weak self] in self?.switchToProfile(profile.id) })

            let hostView = NSHostingView(rootView: cardView)
            hostView.frame = NSRect(x: 0, y: 0, width: 310, height: self.cardHeight(for: status))

            let menuItem = NSMenuItem()
            menuItem.view = hostView
            self.menu.addItem(menuItem)

            if profile.id != self.store.config.profiles.last?.id {
                self.menu.addItem(.separator())
            }
        }

        self.menu.addItem(.separator())

        let refreshItem = NSMenuItem(title: "Refresh All", action: #selector(self.refreshAll), keyEquivalent: "r")
        refreshItem.target = self
        self.menu.addItem(refreshItem)

        let editItem = NSMenuItem(title: "Edit Labels...", action: #selector(self.editLabels), keyEquivalent: "")
        editItem.target = self
        self.menu.addItem(editItem)

        self.menu.addItem(.separator())

        let launchItem = NSMenuItem(title: "Launch at Login", action: #selector(self.toggleLaunchAtLogin), keyEquivalent: "")
        launchItem.target = self
        launchItem.state = LaunchAtLogin.isEnabled ? .on : .off
        self.menu.addItem(launchItem)

        let quitItem = NSMenuItem(title: "Quit CodexProfileSwitcher", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        self.menu.addItem(quitItem)
    }

    private func cardHeight(for status: ProfileStatus) -> CGFloat {
        switch status {
        case .available: return 58
        case .stale(let s) where s != nil: return 68
        case .reloginNeeded(let s) where s != nil: return 68
        default: return 42
        }
    }

    // MARK: - Actions

    private func switchToProfile(_ id: String) {
        self.menu.cancelTracking()

        let isActive = id == self.store.config.activeProfile
        let status = self.store.statuses[id]

        switch status {
        case .notSetUp, .reloginNeeded:
            CodexBridge.startLogin(profileId: id) { [weak self] success in
                if success {
                    self?.usageProvider.refreshAll(force: true)
                }
            }
            return
        default:
            if isActive { return }
        }

        Task {
            let success = await CodexBridge.switchToProfile(id)
            if success {
                self.store.setActiveProfile(id)
                self.usageProvider.refreshActive()
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.updateIcon() }
            }
        }
    }

    @objc private func refreshAll() {
        self.usageProvider.refreshAll(force: true)
    }

    @objc private func editLabels() {
        EditLabelsWindow.show(store: self.store)
    }

    @objc private func toggleLaunchAtLogin() {
        LaunchAtLogin.toggle()
    }
}

// MARK: - Edit Labels Window

enum EditLabelsWindow {
    private static var windowController: NSWindowController?

    static func show(store: ProfileStore) {
        if let wc = Self.windowController {
            wc.showWindow(nil)
            wc.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 340),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false)
        window.title = "Edit Profile Labels"
        window.center()
        window.isReleasedWhenClosed = false

        let view = EditLabelsView(store: store, onSave: { window.close() })
        window.contentView = NSHostingView(rootView: view)

        let wc = NSWindowController(window: window)
        Self.windowController = wc
        wc.showWindow(nil)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

struct EditLabelsView: View {
    let store: ProfileStore
    let onSave: () -> Void
    @State private var labels: [String: String] = [:]

    var body: some View {
        VStack(spacing: 12) {
            ForEach(self.store.config.profiles) { profile in
                HStack {
                    Text(profile.id)
                        .font(.system(size: 13, weight: .bold, design: .monospaced))
                        .frame(width: 24)

                    TextField("Label", text: self.binding(for: profile.id, default: profile.label))
                        .textFieldStyle(.roundedBorder)
                }
            }

            HStack {
                Spacer()
                Button("Save") {
                    for (id, label) in self.labels {
                        self.store.updateLabel(for: id, label: label)
                    }
                    self.onSave()
                }
                .keyboardShortcut(.return)
            }
        }
        .padding()
        .onAppear {
            for profile in self.store.config.profiles {
                self.labels[profile.id] = profile.label
            }
        }
    }

    private func binding(for id: String, default defaultValue: String) -> Binding<String> {
        Binding(
            get: { self.labels[id] ?? defaultValue },
            set: { self.labels[id] = $0 })
    }
}

// MARK: - Launch at Login

enum LaunchAtLogin {
    private static let plistURL: URL = {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent("Library/LaunchAgents/com.codex-profile-switcher.plist")
    }()

    static var isEnabled: Bool {
        FileManager.default.fileExists(atPath: Self.plistURL.path)
    }

    static func toggle() {
        if Self.isEnabled {
            try? FileManager.default.removeItem(at: Self.plistURL)
        } else {
            Self.enable()
        }
    }

    private static func enable() {
        let arg0 = ProcessInfo.processInfo.arguments.first ?? ""
        let binaryPath = URL(fileURLWithPath: arg0).resolvingSymlinksInPath().path
        let plistDict: [String: Any] = [
            "Label": "com.codex-profile-switcher",
            "ProgramArguments": [binaryPath],
            "RunAtLoad": true,
            "KeepAlive": false,
        ]
        let dir = Self.plistURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        guard let data = try? PropertyListSerialization.data(fromPropertyList: plistDict, format: .xml, options: 0) else { return }
        try? data.write(to: Self.plistURL, options: .atomic)
    }
}

// MARK: - Entry Point

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
