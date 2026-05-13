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

        let cacheDecoder = JSONDecoder()
        cacheDecoder.dateDecodingStrategy = .iso8601
        let cacheData = try? Data(contentsOf: self.cacheURL)
        self.cache = cacheData.flatMap { try? cacheDecoder.decode(UsageCache.self, from: $0) }
            ?? UsageCache(snapshots: [:])

        if self.config.profiles.isEmpty {
            self.discoverProfiles()
        } else if self.config.profiles.contains(where: { $0.id == "0" }) {
            self.config.profiles.removeAll { $0.id == "0" }
            if self.config.activeProfile == "0" {
                self.config.activeProfile = self.config.profiles.first?.id ?? "1"
            }
            self.saveConfig()
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

        let home = FileManager.default.homeDirectoryForCurrentUser
        let fm = FileManager.default
        if let contents = try? fm.contentsOfDirectory(atPath: home.path) {
            for name in contents.sorted() where name.hasPrefix(".codex-") {
                let id = String(name.dropFirst(7))
                guard !id.isEmpty, id.rangeOfCharacter(from: CharacterSet.alphanumerics.inverted) == nil else { continue }
                if !profiles.contains(where: { $0.id == id }) {
                    profiles.append(ProfileConfig(id: id, label: "Profile \(id)"))
                }
            }
        }

        if profiles.isEmpty {
            profiles.append(ProfileConfig(id: "1", label: "Profile 1"))
        }

        self.config.profiles = profiles
        self.saveConfig()
    }

    func addProfile() -> ProfileConfig {
        let existingIds = Set(self.config.profiles.map(\.id))
        var nextId = 1
        while existingIds.contains("\(nextId)") { nextId += 1 }
        let profile = ProfileConfig(id: "\(nextId)", label: "Profile \(nextId)")
        self.config.profiles.append(profile)
        self.statuses[profile.id] = .notSetUp
        self.saveConfig()
        return profile
    }

    func removeProfile(_ id: String) {
        self.config.profiles.removeAll { $0.id == id }
        self.statuses.removeValue(forKey: id)
        self.cache.snapshots.removeValue(forKey: id)
        self.saveConfig()
        self.saveCache()
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

    func saveConfigPublic() { self.saveConfig() }

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
        let cached = self.store.cache.snapshots[id]

        func setStatus(_ status: ProfileStatus) async {
            await MainActor.run { self.store.updateStatus(id, status) }
        }

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

            await setStatus(.available(snapshot))
        } catch is CancellationError {
            return
        } catch let error as UsageFetchError where error == .unauthorized {
            await setStatus(.reloginNeeded(cached))
        } catch let error as AuthError {
            switch error {
            case .refreshExpired, .refreshReused, .refreshRevoked:
                await setStatus(.reloginNeeded(cached))
            case .notFound:
                await setStatus(.notSetUp)
            default:
                await setStatus(.stale(cached))
            }
        } catch {
            await setStatus(.stale(cached))
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

// MARK: - Toast

enum ToastStyle { case success, error, info }

final class ToastState: ObservableObject {
    @Published var message: String = ""
    @Published var style: ToastStyle = .success
    @Published var isVisible: Bool = false
    private var hideTask: DispatchWorkItem?

    func show(_ message: String, style: ToastStyle = .success) {
        self.hideTask?.cancel()
        self.message = message
        self.style = style
        withAnimation(.easeOut(duration: 0.2)) { self.isVisible = true }
        let item = DispatchWorkItem { [weak self] in
            withAnimation(.easeIn(duration: 0.3)) { self?.isVisible = false }
        }
        self.hideTask = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0, execute: item)
    }
}

struct ToastOverlay: View {
    @ObservedObject var state: ToastState

    var body: some View {
        if self.state.isVisible {
            VStack {
                Spacer()

                HStack(spacing: 6) {
                    Image(systemName: self.iconName)
                        .font(.system(size: 11, weight: .semibold))
                    Text(self.state.message)
                        .font(.system(size: 11, weight: .medium))
                        .lineLimit(2)
                }
                .foregroundStyle(self.foregroundColor)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(self.borderColor, lineWidth: 0.5)
                )
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .shadow(color: .black.opacity(0.25), radius: 8, y: 2)
            }
            .padding(.bottom, 12)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    private var iconName: String {
        switch self.state.style {
        case .success: "checkmark.circle.fill"
        case .error: "xmark.circle.fill"
        case .info: "info.circle.fill"
        }
    }

    private var foregroundColor: Color {
        switch self.state.style {
        case .success: .green
        case .error: .red
        case .info: .blue
        }
    }

    private var borderColor: Color {
        switch self.state.style {
        case .success: Color.green.opacity(0.3)
        case .error: Color.red.opacity(0.3)
        case .info: Color.blue.opacity(0.3)
        }
    }
}

// MARK: - SwiftUI Views (progress bar adapted from codexbar)

struct UsageBar: View {
    let percent: Double
    let tint: Color

    private static let markerPercents: [Double] = [25, 50, 75]

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

            let markerWidth: CGFloat = 1.5
            for markerPct in Self.markerPercents {
                let x = size.width * markerPct / 100
                let markerRect = CGRect(x: x - markerWidth / 2, y: 0, width: markerWidth, height: size.height)
                context.fill(Path(markerRect), with: .color(.primary.opacity(0.3)))
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
        HStack(spacing: 4) {
            Text(self.label)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.tertiary)
                .frame(width: 16, alignment: .leading)

            UsageBar(percent: Double(self.percent), tint: progressColor(for: self.percent))

            Text("\(self.percent)%")
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 30, alignment: .trailing)

            Text(resetCountdown(from: self.resetAt))
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.tertiary)
                .frame(width: 42, alignment: .trailing)
        }
    }
}

struct ProfileCardView: View {
    let profile: ProfileConfig
    let status: ProfileStatus
    let isActive: Bool
    let onSwitch: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(self.isActive ? Color.blue : Color.clear)
                .frame(width: 3)
                .padding(.vertical, 2)

            VStack(alignment: .leading, spacing: 4) {
                self.headerRow
                self.statusContent
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
        .frame(width: 290, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture { self.onSwitch() }
    }

    private var headerRow: some View {
        HStack(spacing: 6) {
            Text(self.profile.label)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)

            Spacer()

            if let planName = self.planType {
                Text(planName)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
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
        case .stale(let snap):
            if let snap {
                self.usageBars(snap)
            } else {
                Text("No data yet")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        case .reloginNeeded(let snap):
            if let snap { self.usageBars(snap) }
            HStack(spacing: 4) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 9))
                Text("Re-login needed")
                    .font(.system(size: 10))
            }
            .foregroundStyle(.orange)
        case .notSetUp:
            Text("Click to set up")
                .font(.system(size: 10))
                .foregroundStyle(.blue)
        }
    }

    private func usageBars(_ snap: UsageSnapshot) -> some View {
        VStack(spacing: 2) {
            UsageRow(label: "5h", percent: snap.primaryUsedPercent, resetAt: snap.primaryResetAt)
            UsageRow(label: "Wk", percent: snap.secondaryUsedPercent, resetAt: snap.secondaryResetAt)
        }
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
        self.syncActiveProfile()
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
            hostView.frame = NSRect(x: 0, y: 0, width: 290, height: self.cardHeight(for: status))

            let menuItem = NSMenuItem()
            menuItem.view = hostView
            self.menu.addItem(menuItem)

            if profile.id != self.store.config.profiles.last?.id {
                self.menu.addItem(.separator())
            }
        }

        self.menu.addItem(.separator())

        let refreshItem = NSMenuItem(title: "Refresh", action: #selector(self.refreshAll), keyEquivalent: "r")
        refreshItem.target = self
        refreshItem.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: nil)
        refreshItem.image?.size = NSSize(width: 13, height: 13)
        self.menu.addItem(refreshItem)

        let settingsItem = NSMenuItem(title: "Settings...", action: #selector(self.openSettings), keyEquivalent: ",")
        settingsItem.target = self
        settingsItem.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: nil)
        settingsItem.image?.size = NSSize(width: 13, height: 13)
        self.menu.addItem(settingsItem)

        self.menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
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

    // MARK: - Profile Sync

    private func syncActiveProfile() {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/bash")
        proc.arguments = ["-c", "for pid in $(pgrep -x Codex 2>/dev/null); do ps eww -p $pid 2>/dev/null | tr ' ' '\\n' | grep '^CODEX_HOME='; done"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        try? proc.run()
        proc.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        let runningHome: URL
        if output.isEmpty {
            runningHome = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
        } else {
            runningHome = URL(fileURLWithPath: output.replacingOccurrences(of: "CODEX_HOME=", with: ""))
        }

        guard let runningAccountId = self.accountId(from: runningHome) else { return }

        for profile in self.store.config.profiles {
            let profileHome = self.store.codexHome(for: profile.id)
            if let profileAccountId = self.accountId(from: profileHome),
               profileAccountId == runningAccountId {
                if self.store.config.activeProfile != profile.id {
                    self.store.setActiveProfile(profile.id)
                }
                return
            }
        }

        if !self.store.config.activeProfile.isEmpty {
            self.store.setActiveProfile("")
        }
    }

    private func accountId(from codexHome: URL) -> String? {
        let authFile = codexHome.appendingPathComponent("auth.json")
        guard let data = try? Data(contentsOf: authFile),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = json["tokens"] as? [String: Any],
              let accountId = tokens["account_id"] as? String else { return nil }
        return accountId
    }

    // MARK: - Actions

    private func switchToProfile(_ id: String) {
        self.menu.cancelTracking()

        let isActive = id == self.store.config.activeProfile
        let status = self.store.statuses[id]

        switch status {
        case .notSetUp, .reloginNeeded:
            CodexBridge.startLogin(profileId: id) { [weak self] success in
                guard let self, success else { return }
                self.usageProvider.refreshAll(force: true)
                self.updateIcon()
            }
            return
        default:
            if isActive { return }
        }

        let profileLabel = self.store.config.profiles.first { $0.id == id }?.label ?? "Profile \(id)"
        let alert = NSAlert()
        alert.messageText = "Switch to \(profileLabel)?"
        alert.informativeText = "This will quit the current Codex instance and relaunch with the selected profile."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Switch")
        alert.addButton(withTitle: "Cancel")

        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }

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

    @objc private func openSettings() {
        self.menu.cancelTracking()
        SettingsWindow.show(store: self.store)
    }
}

// MARK: - Settings Window

enum SettingsWindow {
    private static var windowController: NSWindowController?

    static func show(store: ProfileStore) {
        if let wc = Self.windowController {
            wc.showWindow(nil)
            wc.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 460),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false)
        window.title = "Settings"
        window.center()
        window.isReleasedWhenClosed = false

        let view = SettingsView(store: store)
        window.contentView = NSHostingView(rootView: view)

        let wc = NSWindowController(window: window)
        Self.windowController = wc
        wc.showWindow(nil)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

struct SettingsView: View {
    let store: ProfileStore
    @State private var selectedTab = 0
    @StateObject private var toast = ToastState()

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                Picker("", selection: self.$selectedTab) {
                    Label("Profiles", systemImage: "person.2").tag(0)
                    Label("General", systemImage: "gearshape").tag(1)
                    Label("About", systemImage: "info.circle").tag(2)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, 8)

                Divider()

                switch self.selectedTab {
                case 0: ProfilesTab(store: self.store, toast: self.toast)
                case 1: GeneralTab()
                case 2: AboutTab()
                default: EmptyView()
                }
            }

            ToastOverlay(state: self.toast)
        }
    }
}

struct ProfilesTab: View {
    let store: ProfileStore
    @ObservedObject var toast: ToastState
    @State private var labels: [String: String] = [:]
    @State private var profiles: [ProfileConfig] = []
    @State private var linkedProfiles: Set<String> = []
    @State private var pendingDeleteId: String?

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 0) {
                    HStack(spacing: 8) {
                        Text("Name")
                            .frame(maxWidth: .infinity, alignment: .leading)

                        Text("Share Data")
                            .frame(width: 70)
                            .help("Shares sessions, plugins, and memories from your default Codex installation (~/.codex). Requires a profile restart to take effect.")

                        Color.clear.frame(width: 20)
                    }
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 20)
                    .padding(.top, 12)
                    .padding(.bottom, 6)

                    ForEach(self.profiles) { profile in
                        HStack(spacing: 8) {
                            TextField("Label", text: self.labelBinding(for: profile.id, default: profile.label))
                                .textFieldStyle(.roundedBorder)

                            Toggle("", isOn: self.linkBinding(for: profile.id))
                                .toggleStyle(.checkbox)
                                .labelsHidden()
                                .frame(width: 70)

                            Button(action: { self.pendingDeleteId = profile.id }) {
                                Image(systemName: "minus.circle.fill")
                                    .foregroundStyle(.red.opacity(0.7))
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.horizontal, 20)
                        .padding(.vertical, 5)
                    }
                }
                .padding(.bottom, 8)
            }

            Divider()

            HStack {
                Spacer()

                Button(action: self.addProfile) {
                    Label("Add", systemImage: "plus")
                }

                Button("Save") { self.saveAll() }
                    .keyboardShortcut(.return)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
        }
        .onAppear { self.reload() }
        .alert("Delete Profile", isPresented: Binding(
            get: { self.pendingDeleteId != nil },
            set: { if !$0 { self.pendingDeleteId = nil } }
        )) {
            Button("Cancel", role: .cancel) { self.pendingDeleteId = nil }
            Button("Delete", role: .destructive) {
                if let id = self.pendingDeleteId {
                    let label = self.labels[id] ?? id
                    self.removeProfile(id)
                    self.toast.show("Deleted \(label)", style: .info)
                }
                self.pendingDeleteId = nil
            }
        } message: {
            if let id = self.pendingDeleteId {
                Text("Are you sure you want to delete \"\(self.labels[id] ?? id)\"? This cannot be undone.")
            }
        }
    }

    private func reload() {
        self.profiles = self.store.config.profiles
        self.labels = [:]
        self.linkedProfiles = []
        for profile in self.profiles {
            self.labels[profile.id] = profile.label
            let codexHome = self.store.codexHome(for: profile.id)
            let sessionsPath = codexHome.appendingPathComponent("sessions").path
            var isDir: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: sessionsPath, isDirectory: &isDir)
            if exists {
                let attrs = try? FileManager.default.attributesOfItem(atPath: sessionsPath)
                if attrs?[.type] as? FileAttributeType == .typeSymbolicLink {
                    self.linkedProfiles.insert(profile.id)
                }
            }
        }
    }

    private func saveAll() {
        for (id, label) in self.labels {
            self.store.updateLabel(for: id, label: label)
        }
        self.applyLinks()
        self.toast.show("Settings saved", style: .success)
    }

    private func addProfile() {
        let profile = self.store.addProfile()
        self.labels[profile.id] = profile.label
        self.profiles = self.store.config.profiles
        self.toast.show("Added \(profile.label)", style: .success)
    }

    private func removeProfile(_ id: String) {
        self.store.removeProfile(id)
        self.labels.removeValue(forKey: id)
        self.linkedProfiles.remove(id)
        self.profiles = self.store.config.profiles
    }

    private func applyLinks() {
        for profile in self.profiles {
            let isLinked = self.linkedProfiles.contains(profile.id)
            let codexHome = self.store.codexHome(for: profile.id)
            let sessionsPath = codexHome.appendingPathComponent("sessions").path
            let attrs = try? FileManager.default.attributesOfItem(atPath: sessionsPath)
            let currentlyLinked = attrs?[.type] as? FileAttributeType == .typeSymbolicLink

            if isLinked && !currentlyLinked {
                Self.runProfileCommand("link", profile.id)
            } else if !isLinked && currentlyLinked {
                Self.runProfileCommand("unlink", profile.id)
            }
        }
    }

    private static func runProfileCommand(_ command: String, _ profileId: String) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let path = home.appendingPathComponent(".local/bin/codex-profile").path
        guard FileManager.default.isExecutableFile(atPath: path) else { return }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: path)
        proc.arguments = [command, profileId]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        try? proc.run()
        proc.waitUntilExit()
    }

    private func labelBinding(for id: String, default defaultValue: String) -> Binding<String> {
        Binding(
            get: { self.labels[id] ?? defaultValue },
            set: { self.labels[id] = $0 })
    }

    private func linkBinding(for id: String) -> Binding<Bool> {
        Binding(
            get: { self.linkedProfiles.contains(id) },
            set: { checked in
                if checked { self.linkedProfiles.insert(id) }
                else { self.linkedProfiles.remove(id) }
            })
    }
}

struct GeneralTab: View {
    @State private var launchAtLogin = LaunchAtLogin.isEnabled

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("STARTUP")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)

            Toggle("Launch at Login", isOn: self.$launchAtLogin)
                .onChange(of: self.launchAtLogin) { _ in LaunchAtLogin.toggle() }

            Text("Automatically opens CodexProfileSwitcher when you start your Mac.")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)

            Spacer()
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct AboutTab: View {
    var body: some View {
        VStack(spacing: 16) {
            Spacer()

            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.system(size: 40))
                .foregroundStyle(.blue)

            Text("CodexProfileSwitcher")
                .font(.system(size: 16, weight: .bold))

            Text("Version 0.1.0")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

            Text("Switch between OpenAI Codex accounts\nfrom your menu bar.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Divider().padding(.horizontal, 40)

            Text("MIT License")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)

            Spacer()
        }
        .padding(20)
        .frame(maxWidth: .infinity)
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

        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        let editMenuItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        editMenuItem.submenu = editMenu
        let mainMenu = NSMenu()
        mainMenu.addItem(editMenuItem)
        app.mainMenu = mainMenu

        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}
