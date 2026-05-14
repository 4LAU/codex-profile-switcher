import Cocoa
import CryptoKit
import SwiftUI

// MARK: - App Info

enum AppInfo {
    static let name = "CodexProfileSwitcher"
    static let version = "0.1.2"
    static let issueURL = URL(string: "https://github.com/4LAU/codex-profile-switcher/issues/new")!
}

// MARK: - Logging (adapted from CodexBar)

enum LogLevel: String {
    case info = "INFO"
    case warning = "WARN"
    case error = "ERROR"
}

enum LogRedactor {
    private static let fallbackRegex = try! NSRegularExpression(pattern: "$^")
    private static let emailRegex = Self.makeRegex(#"[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}"#,
                                                   options: [.caseInsensitive])
    private static let cookieHeaderRegex = Self.makeRegex(#"(?i)(cookie\s*:\s*)([^\r\n]+)"#)
    private static let authorizationRegex = Self.makeRegex(#"(?i)(authorization\s*:\s*)([^\r\n]+)"#)
    private static let bearerRegex = Self.makeRegex(#"(?i)\bbearer\s+[a-z0-9._\-]+=*\b"#)
    private static let openAIKeyRegex = Self.makeRegex(#"(?i)sk-[a-z0-9_\-]{16,}"#)
    private static let tokenFieldRegex = Self.makeRegex(
        #"(?i)("(?:access|refresh|id)_token"\s*:\s*")[^"]+(")"#)
    private static let sensitiveQueryRegex = Self.makeRegex(
        #"(?i)([?&](?:code|device_code|user_code|access_token|refresh_token|id_token|state)=)[^&\s]+"#)

    static func redact(_ text: String) -> String {
        var output = text
        output = self.replace(self.emailRegex, in: output, with: "<redacted-email>")
        output = self.replace(self.cookieHeaderRegex, in: output, with: "$1<redacted>")
        output = self.replace(self.authorizationRegex, in: output, with: "$1<redacted>")
        output = self.replace(self.bearerRegex, in: output, with: "Bearer <redacted>")
        output = self.replace(self.openAIKeyRegex, in: output, with: "<redacted-openai-key>")
        output = self.replace(self.tokenFieldRegex, in: output, with: "$1<redacted>$2")
        output = self.replace(self.sensitiveQueryRegex, in: output, with: "$1<redacted>")
        return output
    }

    static func excerpt(_ text: String, maxLength: Int = 2_000) -> String {
        let singleLine = self.redact(text).replacingOccurrences(of: "\n", with: "\\n")
        guard singleLine.count > maxLength else { return singleLine }
        let end = singleLine.index(singleLine.startIndex, offsetBy: maxLength)
        return "\(singleLine[..<end])...<truncated>"
    }

    private static func makeRegex(_ pattern: String, options: NSRegularExpression.Options = [])
        -> NSRegularExpression
    {
        (try? NSRegularExpression(pattern: pattern, options: options)) ?? self.fallbackRegex
    }

    private static func replace(_ regex: NSRegularExpression, in text: String, with template: String) -> String {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: template)
    }
}

enum AppLogger {
    static let logURL: URL = {
        let base = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library", isDirectory: true)
        return base
            .appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent(AppInfo.name, isDirectory: true)
            .appendingPathComponent("\(AppInfo.name).log")
    }()

    private static let queue = DispatchQueue(label: "com.codex-profile-switcher.log", qos: .utility)
    private static let maxBytes: UInt64 = 2 * 1024 * 1024

    static func info(_ message: String, metadata: [String: String] = [:]) {
        self.write(level: .info, message: message, metadata: metadata)
    }

    static func warning(_ message: String, metadata: [String: String] = [:]) {
        self.write(level: .warning, message: message, metadata: metadata)
    }

    static func error(_ message: String, metadata: [String: String] = [:]) {
        self.write(level: .error, message: message, metadata: metadata)
    }

    static func recentLines(limit: Int = 200) -> String {
        guard let data = try? Data(contentsOf: self.logURL),
              let text = String(data: data, encoding: .utf8) else {
            return "<no log file>"
        }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).suffix(limit)
        return lines.joined(separator: "\n")
    }

    private static func write(level: LogLevel, message: String, metadata: [String: String]) {
        let safeMessage = LogRedactor.redact(message)
        let safeMetadata = metadata
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\(LogRedactor.excerpt($0.value))" }
            .joined(separator: " ")
        let suffix = safeMetadata.isEmpty ? "" : " \(safeMetadata)"
        let line = "[\(Self.timestamp())] [\(level.rawValue)] \(safeMessage)\(suffix)\n"

        self.queue.async {
            do {
                try self.prepareFile()
                let data = Data(line.utf8)
                let handle = try FileHandle(forWritingTo: self.logURL)
                defer { try? handle.close() }
                handle.seekToEndOfFile()
                try handle.write(contentsOf: data)
            } catch {
                NSLog("%@: log write failed: %@", AppInfo.name, error.localizedDescription)
            }
        }
    }

    private static func prepareFile() throws {
        let fm = FileManager.default
        let dir = self.logURL.deletingLastPathComponent()
        try fm.createDirectory(at: dir, withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])

        if fm.fileExists(atPath: self.logURL.path) {
            let attrs = try fm.attributesOfItem(atPath: self.logURL.path)
            let size = (attrs[.size] as? NSNumber)?.uint64Value ?? 0
            if size > self.maxBytes {
                let rotated = dir.appendingPathComponent("\(AppInfo.name).old.log")
                try? fm.removeItem(at: rotated)
                try? fm.moveItem(at: self.logURL, to: rotated)
            }
        }

        if !fm.fileExists(atPath: self.logURL.path) {
            fm.createFile(atPath: self.logURL.path, contents: nil,
                          attributes: [.posixPermissions: 0o600])
        }
    }

    private static let timestampFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static func timestamp() -> String {
        return timestampFormatter.string(from: Date())
    }
}

// MARK: - Models

struct ProfileConfig: Codable, Identifiable {
    let id: String
    var label: String
}

struct AppConfig: Codable {
    var profiles: [ProfileConfig]
    var activeProfile: String
    var authStorageVersion: Int?
}

struct UsageSnapshot: Codable {
    let planType: String?
    let creditsRemaining: Double?
    let primaryUsedPercent: Int
    let primaryResetAt: Date?
    let secondaryUsedPercent: Int
    let secondaryResetAt: Date?
    let fetchedAt: Date
}

struct UsageCache: Codable {
    var snapshots: [String: UsageSnapshot]
}

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

private func dictStringValue(_ dict: [String: Any], _ keys: String...) -> String? {
    for key in keys {
        if let value = dict[key] as? String, !value.isEmpty { return value }
    }
    return nil
}

private let iso8601WithFractional: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
}()

private let iso8601Plain: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime]
    return f
}()

private func parseISO8601Date(_ raw: Any?) -> Date? {
    guard let value = raw as? String, !value.isEmpty else { return nil }
    if let d = iso8601WithFractional.date(from: value) { return d }
    return iso8601Plain.date(from: value)
}

private func shortIdentifier(_ value: String, head: Int = 10, tail: Int = 6) -> String {
    guard value.count > head + tail + 1 else { return value }
    let start = value.prefix(head)
    let end = value.suffix(tail)
    return "\(start)…\(end)"
}

private func shortHash(_ value: String, head: Int = 6, tail: Int = 4) -> String {
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

private func atomicWriteData(_ data: Data, to destination: URL) throws {
    let dir = destination.deletingLastPathComponent()
    let tempPath = dir.appendingPathComponent(
        ".\(destination.lastPathComponent).tmp-\(UUID().uuidString)").path
    let fd = open(tempPath, O_WRONLY | O_CREAT | O_EXCL, 0o600)
    guard fd >= 0 else { throw AuthError.writeFailed }

    do {
        let written = data.withUnsafeBytes { ptr -> Bool in
            guard let base = ptr.baseAddress else { return data.isEmpty }
            var remaining = data.count
            var offset = 0
            while remaining > 0 {
                let n = Darwin.write(fd, base + offset, remaining)
                guard n > 0 else { return false }
                offset += n
                remaining -= n
            }
            return true
        }
        guard written else { throw AuthError.writeFailed }
        fsync(fd)
        close(fd)
    } catch {
        close(fd)
        unlink(tempPath)
        throw error
    }

    guard rename(tempPath, destination.path) == 0 else {
        unlink(tempPath)
        throw AuthError.writeFailed
    }
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

    var errorDescription: String? {
        switch self {
        case .cannotClearActiveProfile:
            return "Switch away from the active profile before clearing its saved auth."
        }
    }
}

struct SettingsActionError: LocalizedError {
    let message: String

    var errorDescription: String? { self.message }
}

// MARK: - ProfileStore

final class ProfileStore {
    private static let keychainAuthStorageVersion = 2
    private static let keychainAccessRepairVersion = 3

    private let configDir: URL
    private let configURL: URL
    private let cacheURL: URL
    private let authStoreDir: URL
    private let authVault: AuthVault
    private let authStorageDescription: String
    private let codexHome: URL
    private let codexAuthPath: URL
    private let codexGlobalStateURL: URL
    private let fileManager = FileManager.default
    private let authMutationLock = NSLock()
    private var authMutationInProgress = false
    private var cacheDirty = false

    private(set) var config: AppConfig
    private(set) var cache: UsageCache
    private(set) var statuses: [String: ProfileStatus] = [:]
    private(set) var refreshDiagnostics: [String: ProfileRefreshDiagnostics] = [:]
    private(set) var liveProfileId: String?

    init(authVault: AuthVault? = nil, environment: [String: String] = ProcessInfo.processInfo.environment) {
        let keychainService = Self.keychainService(environment: environment)
        if let authVault {
            self.authVault = authVault
            self.authStorageDescription = "custom auth vault"
        } else {
            self.authVault = KeychainAuthVault(service: keychainService)
            self.authStorageDescription = "macOS Keychain (\(keychainService))"
        }

        let home = Self.userHome(environment: environment)
        self.configDir = home.appendingPathComponent(".codex-switcher")
        self.configURL = self.configDir.appendingPathComponent("config.json")
        self.cacheURL = self.configDir.appendingPathComponent("cache.json")
        self.authStoreDir = self.configDir.appendingPathComponent("auth", isDirectory: true)
        self.codexHome = home.appendingPathComponent(".codex", isDirectory: true)
        self.codexAuthPath = self.codexHome.appendingPathComponent("auth.json")
        self.codexGlobalStateURL = self.codexHome.appendingPathComponent(".codex-global-state.json")

        do {
            try self.fileManager.createDirectory(at: self.configDir, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        } catch {
            AppLogger.error("Failed to create app directories", metadata: ["error": error.localizedDescription])
        }

        let isFirstLaunch: Bool
        if let data = try? Data(contentsOf: self.configURL),
           let loaded = try? JSONDecoder().decode(AppConfig.self, from: data) {
            self.config = loaded
            isFirstLaunch = false
        } else {
            if self.fileManager.fileExists(atPath: self.configURL.path) {
                AppLogger.warning("Config exists but could not be decoded",
                                  metadata: ["path": self.configURL.path])
            }
            self.config = AppConfig(profiles: [], activeProfile: "1", authStorageVersion: nil)
            isFirstLaunch = true
        }

        let cacheDecoder = JSONDecoder()
        cacheDecoder.dateDecodingStrategy = .iso8601
        let cacheData = try? Data(contentsOf: self.cacheURL)
        self.cache = cacheData.flatMap { try? cacheDecoder.decode(UsageCache.self, from: $0) }
            ?? UsageCache(snapshots: [:])
        if cacheData != nil, self.cache.snapshots.isEmpty {
            AppLogger.warning("Cache exists but could not be decoded", metadata: ["path": self.cacheURL.path])
        }

        if isFirstLaunch, self.legacyAuthStoreFiles().isEmpty {
            self.config.authStorageVersion = Self.keychainAccessRepairVersion
            self.config.profiles = [ProfileConfig(id: "1", label: "Profile 1")]
            self.statuses["1"] = .notSetUp
            self.saveConfig()
        } else {
            self.migrateLegacyProfiles()
            self.repairKeychainAccessIfNeeded()
            self.discoverProfiles()
            self.refreshStatusesFromStoredAuth()
        }
        self.liveProfileId = self.config.activeProfile.isEmpty ? nil : self.config.activeProfile
    }

    static func keychainService(environment: [String: String]) -> String {
        if let service = environment["CODEX_PROFILE_KEYCHAIN_SERVICE"], !service.isEmpty {
            return service
        }
        return KeychainAuthVault.defaultService
    }

    static func userHome(environment: [String: String]) -> URL {
        if let path = environment["CODEX_PROFILE_HOME"], !path.isEmpty {
            return URL(fileURLWithPath: path).standardizedFileURL
        }
        if let path = environment["CODEX_PROFILE_TEST_HOME"], !path.isEmpty {
            return URL(fileURLWithPath: path).standardizedFileURL
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    func discoverProfiles() {
        var merged: [ProfileConfig] = []
        var seen = Set<String>()

        for profile in self.config.profiles where Self.isValidProfileId(profile.id) {
            guard seen.insert(profile.id).inserted else { continue }
            merged.append(profile)
        }

        for id in self.savedProfileIDs() where seen.insert(id).inserted {
            merged.append(ProfileConfig(id: id, label: "Profile \(id)"))
        }

        if merged.isEmpty {
            merged.append(ProfileConfig(id: "1", label: "Profile 1"))
        }

        self.config.profiles = merged
        if self.config.activeProfile.isEmpty || !seen.contains(self.config.activeProfile) {
            self.config.activeProfile = merged.first?.id ?? "1"
        }
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

    func removeProfile(_ id: String) throws {
        try self.authVault.deleteAuthBlob(profileID: id)

        self.config.profiles.removeAll { $0.id == id }
        self.statuses.removeValue(forKey: id)
        self.refreshDiagnostics.removeValue(forKey: id)
        self.cache.snapshots.removeValue(forKey: id)
        if self.config.activeProfile == id {
            self.config.activeProfile = self.config.profiles.first?.id ?? ""
        }
        if self.liveProfileId == id {
            self.liveProfileId = nil
        }
        self.saveConfig()
        self.saveCache()
    }

    func authStoreExists(for profileId: String) -> Bool {
        (try? self.authVault.hasAuthBlob(profileID: profileId)) ?? false
    }

    func syncSavedAuthToLive(for profileId: String) throws {
        guard let data = try self.authVault.loadAuthBlob(profileID: profileId) else {
            throw AuthError.notFound
        }
        try self.replaceFile(at: self.codexAuthPath, with: data)
    }

    func authDetails(for profileId: String) -> AuthIdentityDetails? {
        if let data = try? self.authVault.loadAuthBlob(profileID: profileId),
           let details = Self.authDetails(from: data) {
            return details
        }

        if self.liveProfileId == profileId {
            return Self.authDetails(at: self.codexAuthPath)
        }

        return nil
    }

    func codexConfigURL() -> URL {
        self.codexHome.appendingPathComponent("config.toml")
    }

    func setActiveProfile(_ id: String) {
        self.config.activeProfile = id
        self.saveConfig()
    }

    func setLiveProfileId(_ id: String?) {
        self.liveProfileId = id
    }

    func liveAuthModificationDate() -> Date? {
        let attrs = try? self.fileManager.attributesOfItem(atPath: self.codexAuthPath.path)
        return attrs?[.modificationDate] as? Date
    }

    func liveAuthExists() -> Bool {
        self.fileManager.fileExists(atPath: self.codexAuthPath.path)
    }

    func authDataForUsage(profileId: String, activeProfileId: String) throws -> Data? {
        if profileId == activeProfileId {
            guard self.fileManager.fileExists(atPath: self.codexAuthPath.path) else { return nil }
            return try Data(contentsOf: self.codexAuthPath)
        }
        return try self.authVault.loadAuthBlob(profileID: profileId)
    }

    func currentSavedAuthData(for profileId: String) throws -> Data? {
        try self.authVault.loadAuthBlob(profileID: profileId)
    }

    func saveAuthDataToVault(_ data: Data, for profileId: String) throws {
        try self.authVault.saveAuthBlob(data, profileID: profileId)
    }

    func relaunchWorkspacePath() -> String? {
        guard let data = try? Data(contentsOf: self.codexGlobalStateURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        for key in ["active-workspace-roots", "electron-saved-workspace-roots"] {
            guard let values = json[key] as? [String] else { continue }
            for value in values {
                guard let normalized = self.normalizedDirectoryPath(value) else { continue }
                return normalized
            }
        }

        return nil
    }

    func debugSummaryLines() -> [String] {
        var lines: [String] = [
            "config: \(self.configURL.path)",
            "cache: \(self.cacheURL.path)",
            "auth_storage: \(self.authStorageDescription)",
            "legacy_auth_store: \(self.authStoreDir.path)",
            "codex_home: \(self.codexHome.path)",
            "codex_auth_exists: \(self.liveAuthExists())",
            "config_active_profile: \(self.config.activeProfile)",
            "auth_storage_version: \(self.config.authStorageVersion.map(String.init) ?? "<none>")",
            "live_profile_id: \(self.liveProfileId ?? "<none>")",
            "profile_count: \(self.config.profiles.count)",
        ]

        for profile in self.config.profiles {
            let status = self.statuses[profile.id] ?? .notSetUp
            let cacheAge = self.cache.snapshots[profile.id].map { Int(Date().timeIntervalSince($0.fetchedAt)) }
            let cacheText = cacheAge.map { "\($0)s" } ?? "<none>"
            let diagnostics = self.refreshDiagnostics[profile.id]
            let attemptedSource = diagnostics?.lastAttemptedSource?.rawValue ?? "<none>"
            let successfulSource = diagnostics?.lastSuccessfulSource?.rawValue ?? "<none>"
            let fallbackReason = diagnostics?.lastFallbackReason ?? "<none>"
            let decision = diagnostics?.lastDecision ?? "<none>"
            let error = diagnostics?.lastError.map { LogRedactor.excerpt($0, maxLength: 120) } ?? "<none>"
            lines.append(
                "profile[\(profile.id)]: label=\"\(profile.label)\" status=\(Self.debugStatusName(status)) " +
                    "auth_saved=\(self.authStoreExists(for: profile.id)) cache_age=\(cacheText) " +
                    "last_attempted_source=\(attemptedSource) last_successful_source=\(successfulSource) " +
                    "last_fallback_reason=\(fallbackReason) last_decision=\(decision) last_error=\(error)")
        }

        return lines
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
            self.cacheDirty = true
        }
    }

    func updateRefreshDiagnostics(_ id: String, _ diagnostics: ProfileRefreshDiagnostics) {
        self.refreshDiagnostics[id] = diagnostics
    }

    func duplicateProfileIDs(for profileId: String) -> [String] {
        let groups = self.duplicateProfileGroups()
        guard let match = groups.first(where: { $0.contains(profileId) }) else { return [] }
        return match.filter { $0 != profileId }
    }

    func duplicateProfileGroups() -> [[String]] {
        var idsByFingerprint: [String: [String]] = [:]

        for profile in self.config.profiles {
            guard let fingerprint = self.savedAuthFingerprint(for: profile.id) else { continue }
            idsByFingerprint[fingerprint, default: []].append(profile.id)
        }

        return idsByFingerprint.values
            .filter { $0.count > 1 }
            .map { $0.sorted() }
            .sorted { lhs, rhs in
                (lhs.first ?? "") < (rhs.first ?? "")
            }
    }

    func clearSavedAuth(for id: String) throws {
        if self.liveProfileId == id {
            throw ProfileMutationError.cannotClearActiveProfile
        }

        try self.authVault.deleteAuthBlob(profileID: id)
        self.cache.snapshots.removeValue(forKey: id)
        self.refreshDiagnostics.removeValue(forKey: id)
        self.statuses[id] = .notSetUp
        self.saveCache()
    }

    func flushCacheIfDirty() {
        guard self.cacheDirty else { return }
        self.cacheDirty = false
        self.saveCache()
    }

    func beginAuthMutation() {
        self.authMutationLock.lock()
        self.authMutationInProgress = true
        self.authMutationLock.unlock()
    }

    func endAuthMutation() {
        self.authMutationLock.lock()
        self.authMutationInProgress = false
        self.authMutationLock.unlock()
    }

    func isAuthMutationInProgress() -> Bool {
        self.authMutationLock.lock()
        defer { self.authMutationLock.unlock() }
        return self.authMutationInProgress
    }

    func authFingerprint(for url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return self.authFingerprint(for: data)
    }

    func authFingerprint(for data: Data) -> String? {
        AuthBlob.identityFingerprint(from: data)
    }

    func savedAuthFingerprint(for profileId: String) -> String? {
        guard let data = try? self.authVault.loadAuthBlob(profileID: profileId) else { return nil }
        return self.authFingerprint(for: data)
    }

    func liveAuthFingerprint() -> String? {
        self.authFingerprint(for: self.codexAuthPath)
    }

    func matchingProfilesForLiveAuth() -> [String] {
        guard let liveFingerprint = self.liveAuthFingerprint() else { return [] }

        let hasAnySetUp = self.statuses.values.contains {
            if case .notSetUp = $0 { return false }
            return true
        }
        guard hasAnySetUp else { return [] }

        return self.config.profiles.compactMap { profile in
            guard self.savedAuthFingerprint(for: profile.id) == liveFingerprint else {
                return nil
            }
            return profile.id
        }
    }

    private static let configEncoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()

    private func normalizedDirectoryPath(_ rawPath: String) -> String? {
        guard !rawPath.isEmpty else { return nil }
        var isDir = ObjCBool(false)
        guard self.fileManager.fileExists(atPath: rawPath, isDirectory: &isDir), isDir.boolValue else {
            return nil
        }
        return URL(fileURLWithPath: rawPath).standardizedFileURL.path
    }

    private static let cacheEncoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    private func saveConfig() {
        do {
            try self.saveConfigThrowing()
        } catch {
            AppLogger.error("Failed to save config", metadata: ["error": error.localizedDescription])
        }
    }

    private func saveConfigThrowing() throws {
        let data = try Self.configEncoder.encode(self.config)
        try data.write(to: self.configURL, options: .atomic)
    }

    private func saveCache() {
        do {
            let data = try Self.cacheEncoder.encode(self.cache)
            try data.write(to: self.cacheURL, options: .atomic)
        } catch {
            AppLogger.error("Failed to save usage cache", metadata: ["error": error.localizedDescription])
        }
    }

    private func refreshStatusesFromStoredAuth() {
        self.statuses = [:]
        for profile in self.config.profiles {
            if self.authStoreExists(for: profile.id) {
                if let cached = self.cache.snapshots[profile.id] {
                    self.statuses[profile.id] = .stale(cached)
                } else {
                    self.statuses[profile.id] = .loading
                }
            } else {
                self.statuses[profile.id] = .notSetUp
            }
        }
    }

    private func savedProfileIDs() -> [String] {
        ((try? self.authVault.listProfileIDs()) ?? [])
            .filter(Self.isValidProfileId)
            .sorted()
    }

    private func migrateLegacyProfiles() {
        let currentVersion = self.config.authStorageVersion ?? 0
        guard currentVersion < Self.keychainAuthStorageVersion else {
            self.cleanupLegacyAuthStoreIfMigrated()
            return
        }

        let legacyFiles = self.legacyAuthStoreFiles()
        guard !legacyFiles.isEmpty else {
            do {
                self.config.authStorageVersion = Self.keychainAuthStorageVersion
                try self.saveConfigThrowing()
                self.cleanupLegacyAuthStoreIfMigrated()
            } catch {
                AppLogger.error("Failed to mark empty legacy disk auth migration complete",
                                metadata: ["error": error.localizedDescription])
            }
            return
        }

        let validatedFiles: [(id: String, url: URL, data: Data)]
        do {
            validatedFiles = try legacyFiles.map { id, url in
                let data = try Data(contentsOf: url)
                guard AuthBlob.isPlausibleAuthBlob(data) else {
                    throw AuthError.decodeFailed
                }
                return (id, url, data)
            }
        } catch {
            AppLogger.error("Failed to validate legacy disk auth store before Keychain migration",
                            metadata: ["error": error.localizedDescription])
            return
        }

        var priorBlobs: [String: Data?] = [:]
        var touchedProfileIDs: [String] = []
        do {
            for (id, _, _) in validatedFiles {
                priorBlobs[id] = try self.authVault.loadAuthBlob(profileID: id)
            }

            for (id, _, data) in validatedFiles {
                try self.authVault.saveAuthBlob(data, profileID: id)
                touchedProfileIDs.append(id)
                guard let saved = try self.authVault.loadAuthBlob(profileID: id) else {
                    throw AuthError.notFound
                }
                guard saved == data || self.authFingerprint(for: saved) == self.authFingerprint(for: data) else {
                    throw AuthError.writeFailed
                }
            }

            self.config.authStorageVersion = Self.keychainAuthStorageVersion
            try self.saveConfigThrowing()
            self.cleanupLegacyAuthStoreIfMigrated()
            AppLogger.info("Migrated legacy disk auth store to Keychain",
                           metadata: ["profile_count": "\(validatedFiles.count)"])
        } catch {
            self.rollbackKeychainMigration(touchedProfileIDs: touchedProfileIDs, priorBlobs: priorBlobs)
            AppLogger.error("Failed to migrate legacy disk auth store to Keychain",
                            metadata: ["error": error.localizedDescription])
        }
    }

    private func repairKeychainAccessIfNeeded() {
        let currentVersion = self.config.authStorageVersion ?? 0
        guard currentVersion >= Self.keychainAuthStorageVersion,
              currentVersion < Self.keychainAccessRepairVersion else { return }

        do {
            let repaired = try self.authVault.repairStoredAuthAccess()
            self.config.authStorageVersion = Self.keychainAccessRepairVersion
            try self.saveConfigThrowing()
            if repaired > 0 {
                AppLogger.info("Repaired saved auth Keychain access",
                               metadata: ["profile_count": "\(repaired)"])
            }
        } catch {
            AppLogger.error("Failed to repair saved auth Keychain access",
                            metadata: ["error": error.localizedDescription])
        }
    }

    private func legacyAuthStoreFiles() -> [(String, URL)] {
        guard let urls = try? self.fileManager.contentsOfDirectory(
            at: self.authStoreDir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        return urls.compactMap { url in
            guard url.pathExtension == "json" else { return nil }
            let id = url.deletingPathExtension().lastPathComponent
            guard Self.isValidProfileId(id) else { return nil }
            return (id, url)
        }
        .sorted { $0.0 < $1.0 }
    }

    private func rollbackKeychainMigration(touchedProfileIDs: [String], priorBlobs: [String: Data?]) {
        for id in Set(touchedProfileIDs) {
            do {
                if let prior = priorBlobs[id] ?? nil {
                    try self.authVault.saveAuthBlob(prior, profileID: id)
                } else {
                    try self.authVault.deleteAuthBlob(profileID: id)
                }
            } catch {
                AppLogger.error("Failed to roll back migrated Keychain auth",
                                metadata: ["profile": id, "error": error.localizedDescription])
            }
        }
    }

    private func cleanupLegacyAuthStoreIfMigrated() {
        guard (self.config.authStorageVersion ?? 0) >= Self.keychainAuthStorageVersion else { return }
        guard self.fileManager.fileExists(atPath: self.authStoreDir.path) else { return }

        do {
            try self.fileManager.removeItem(at: self.authStoreDir)
        } catch {
            AppLogger.error("Failed to remove legacy disk auth store",
                            metadata: ["error": error.localizedDescription])
        }
    }

    private func replaceFile(at destination: URL, with data: Data) throws {
        let dir = destination.deletingLastPathComponent()
        try self.fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        try atomicWriteData(data, to: destination)
    }

    private static func isValidProfileId(_ id: String) -> Bool {
        let pattern = #"^[A-Za-z0-9][A-Za-z0-9._-]*$"#
        return id.range(of: pattern, options: .regularExpression) != nil
    }

    private static func debugStatusName(_ status: ProfileStatus) -> String {
        switch status {
        case .available: return "available"
        case .loading: return "loading"
        case .stale(let snapshot): return snapshot == nil ? "stale-no-cache" : "stale"
        case .reloginNeeded: return "relogin-needed"
        case .notSetUp: return "not-set-up"
        }
    }

    private static func stableClaims(fromIDToken idToken: String) -> [String: String]? {
        let parts = idToken.split(separator: ".")
        guard parts.count >= 2,
              let payloadData = Self.base64URLDecode(String(parts[1])),
              let payload = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any] else {
            return nil
        }

        let stableKeys = [
            "sub",
            "email",
            "https://api.openai.com/auth",
            "https://api.openai.com/account_id",
            "https://api.openai.com/user_id",
            "https://api.openai.com/organization_id",
        ]

        var claims: [String: String] = [:]
        for key in stableKeys {
            if let value = payload[key] as? String, !value.isEmpty {
                claims[key] = value
            }
        }
        return claims.isEmpty ? nil : claims
    }

    private static func authDetails(at url: URL) -> AuthIdentityDetails? {
        guard let data = try? Data(contentsOf: url) else {
            return nil
        }
        return self.authDetails(from: data)
    }

    private static func authDetails(from data: Data) -> AuthIdentityDetails? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        if let apiKey = json["OPENAI_API_KEY"] as? String,
           !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let digest = SHA256.hash(data: Data(apiKey.utf8)).map { String(format: "%02x", $0) }.joined()
            return AuthIdentityDetails(
                kind: .apiKey,
                email: nil,
                accountId: nil,
                userId: nil,
                organizationId: nil,
                subject: nil,
                lastRefresh: parseISO8601Date(json["last_refresh"]),
                keyHash: digest)
        }

        guard let tokens = json["tokens"] as? [String: Any] else { return nil }

        let accountId = dictStringValue(tokens, "account_id", "accountId")
        let idToken = dictStringValue(tokens, "id_token", "idToken")
        let claims = idToken.flatMap(Self.stableClaims(fromIDToken:)) ?? [:]

        return AuthIdentityDetails(
            kind: .oauth,
            email: claims["email"],
            accountId: accountId ?? claims["https://api.openai.com/account_id"],
            userId: claims["https://api.openai.com/user_id"],
            organizationId: claims["https://api.openai.com/organization_id"],
            subject: claims["sub"],
            lastRefresh: parseISO8601Date(json["last_refresh"]),
            keyHash: nil)
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

// MARK: - Auth Credentials (adapted from codexbar)

enum AuthCredentialLoader {
    static func load(from data: Data) throws -> AuthCredentials {
        try AuthBlob.load(from: data)
    }
}

// MARK: - Token Refresh (adapted from codexbar)

enum AuthRefresher {
    private static let endpoint = URL(string: "https://auth.openai.com/oauth/token")!
    private static let clientID = "app_EMoamEEZ73f0CkXaXp7hrann"

    static func refreshIfNeeded(
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
        AppLogger.info("Refreshing inactive OAuth token", metadata: ["profile": profileId])

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
            AppLogger.warning("Skipped OAuth token refresh save because auth changed",
                              metadata: ["profile": profileId])
            return current
        }
        try Task.checkCancellation()
        let updatedData = try AuthBlob.updatedData(from: currentData, with: refreshed)
        try saveUpdatedAuthData(updatedData)
        AppLogger.info("OAuth token refresh succeeded", metadata: ["profile": profileId])
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
    let credits: CreditInfo?

    enum CodingKeys: String, CodingKey {
        case planType = "plan_type"
        case rateLimit = "rate_limit"
        case credits
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.planType = try container.decodeIfPresent(String.self, forKey: .planType)
        self.rateLimit = try container.decodeIfPresent(RateLimitInfo.self, forKey: .rateLimit)
        self.credits = try? container.decodeIfPresent(CreditInfo.self, forKey: .credits)
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

        enum CodingKeys: String, CodingKey {
            case usedPercent = "used_percent"
            case resetAt = "reset_at"
        }
    }

    struct CreditInfo: Decodable {
        let balance: Double?

        enum CodingKeys: String, CodingKey {
            case balance
        }

        init(from decoder: Decoder) throws {
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
            AppLogger.warning("Usage API unauthorized", metadata: ["status": "\(http.statusCode)"])
            throw UsageFetchError.unauthorized
        default:
            AppLogger.warning("Usage API server error", metadata: ["status": "\(http.statusCode)"])
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

enum CodexRPCError: LocalizedError {
    case cliNotFound
    case startFailed(String)
    case requestFailed(String)
    case malformed(String)
    case timeout(method: String)

    var errorDescription: String? {
        switch self {
        case .cliNotFound:
            return "Codex CLI not found"
        case .startFailed(let message):
            return "Failed to start Codex CLI: \(message)"
        case .requestFailed(let message):
            return message
        case .malformed(let message):
            return message
        case .timeout(let method):
            return "Codex CLI timed out on \(method)"
        }
    }

    var isAuthRequired: Bool {
        guard case .requestFailed(let message) = self else { return false }
        return message.localizedCaseInsensitiveContains("authentication required")
            || message.localizedCaseInsensitiveContains("log in")
    }
}

enum CLIUsageError: LocalizedError {
    case noRateLimitsFound
    case invalidResponse(String)

    var errorDescription: String? {
        switch self {
        case .noRateLimitsFound:
            return "Codex CLI returned no usage data"
        case .invalidResponse(let message):
            return message
        }
    }
}

private struct RPCRateLimitsResponse: Decodable {
    let rateLimits: RPCRateLimitSnapshot
}

private struct RPCRateLimitSnapshot: Decodable {
    let primary: RPCRateLimitWindow?
    let secondary: RPCRateLimitWindow?
    let credits: RPCCreditsSnapshot?
    let planType: String?

    enum CodingKeys: String, CodingKey {
        case primary
        case secondary
        case credits
        case planType = "planType"
    }
}

private struct RPCRateLimitWindow: Decodable {
    let usedPercent: Double
    let windowDurationMins: Int?
    let resetsAt: Int?
}

private struct RPCCreditsSnapshot: Decodable {
    let hasCredits: Bool
    let unlimited: Bool
    let balance: String?
}

enum CodexCLIResolver {
    private static let fileManager = FileManager.default

    static func resolvePath(environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        if let override = environment["CODEX_CLI"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !override.isEmpty,
           self.fileManager.isExecutableFile(atPath: override) {
            return override
        }

        if let fromPath = self.whichCodex(environment: environment) {
            return fromPath
        }

        let bundledRoot = environment["CODEX_APP"]?.trimmingCharacters(in: .whitespacesAndNewlines)
            ?? "/Applications/Codex.app"
        let bundledCLI = URL(fileURLWithPath: bundledRoot)
            .appendingPathComponent("Contents/Resources/codex")
            .path
        if self.fileManager.isExecutableFile(atPath: bundledCLI) {
            return bundledCLI
        }

        return nil
    }

    private static func whichCodex(environment: [String: String]) -> String? {
        let proc = Process()
        let pipe = Pipe()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        proc.arguments = ["codex"]
        proc.standardOutput = pipe
        proc.standardError = Pipe()

        var env = environment
        env["PATH"] = self.effectivePATH(environment: environment)
        proc.environment = env

        do {
            try proc.run()
        } catch {
            return nil
        }

        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let path = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : path
    }

    private static func effectivePATH(environment: [String: String]) -> String {
        let home = self.fileManager.homeDirectoryForCurrentUser.path
        let defaults = [
            environment["PATH"],
            "\(home)/.local/bin",
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin",
        ]

        var seen = Set<String>()
        var parts: [String] = []
        for chunk in defaults.compactMap({ $0 }) {
            for item in chunk.split(separator: ":").map(String.init) where !item.isEmpty {
                if seen.insert(item).inserted {
                    parts.append(item)
                }
            }
        }
        return parts.joined(separator: ":")
    }
}

private final class CodexRPCLineBuffer {
    private let lock = NSLock()
    private var buffer = Data()

    func appendAndDrainLines(_ data: Data) -> [Data] {
        self.lock.lock()
        defer { self.lock.unlock() }

        self.buffer.append(data)
        var out: [Data] = []
        while let newline = self.buffer.firstIndex(of: 0x0A) {
            let line = Data(self.buffer[..<newline])
            self.buffer.removeSubrange(...newline)
            if !line.isEmpty {
                out.append(line)
            }
        }
        return out
    }
}

private final class CodexRPCClient {
    private let process = Process()
    private let stdinPipe = Pipe()
    private let stdoutPipe = Pipe()
    private let stderrPipe = Pipe()
    private let stdoutLineStream: AsyncStream<Data>
    private let stdoutLineContinuation: AsyncStream<Data>.Continuation
    private let initializeTimeoutSeconds: TimeInterval
    private let requestTimeoutSeconds: TimeInterval
    private var nextID = 1
    private var stdoutLineIterator: AsyncStream<Data>.Iterator

    init(
        executablePath: String,
        environment: [String: String],
        initializeTimeoutSeconds: TimeInterval = 8,
        requestTimeoutSeconds: TimeInterval = 3) throws
    {
        self.initializeTimeoutSeconds = initializeTimeoutSeconds
        self.requestTimeoutSeconds = requestTimeoutSeconds

        var continuation: AsyncStream<Data>.Continuation!
        self.stdoutLineStream = AsyncStream<Data> { continuation = $0 }
        self.stdoutLineContinuation = continuation
        self.stdoutLineIterator = self.stdoutLineStream.makeAsyncIterator()

        self.process.executableURL = URL(fileURLWithPath: executablePath)
        self.process.arguments = ["-s", "read-only", "-a", "untrusted", "app-server"]
        self.process.environment = environment
        self.process.standardInput = self.stdinPipe
        self.process.standardOutput = self.stdoutPipe
        self.process.standardError = self.stderrPipe

        do {
            try self.process.run()
        } catch {
            throw CodexRPCError.startFailed(error.localizedDescription)
        }

        let stdoutHandle = self.stdoutPipe.fileHandleForReading
        let stdoutBuffer = CodexRPCLineBuffer()
        let stdoutContinuation = self.stdoutLineContinuation
        stdoutHandle.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                stdoutContinuation.finish()
                return
            }

            for line in stdoutBuffer.appendAndDrainLines(data) {
                stdoutContinuation.yield(line)
            }
        }

        let stderrHandle = self.stderrPipe.fileHandleForReading
        stderrHandle.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
            }
        }
    }

    func initialize(clientName: String, clientVersion: String) async throws {
        _ = try await self.request(
            method: "initialize",
            params: ["clientInfo": ["name": clientName, "version": clientVersion]],
            timeout: self.initializeTimeoutSeconds)
        try self.sendNotification(method: "initialized")
    }

    func fetchRateLimits() async throws -> RPCRateLimitsResponse {
        let message = try await self.request(method: "account/rateLimits/read")
        return try self.decodeResult(from: message)
    }

    func shutdown() {
        self.stdoutPipe.fileHandleForReading.readabilityHandler = nil
        self.stderrPipe.fileHandleForReading.readabilityHandler = nil
        if self.process.isRunning {
            self.process.terminate()
        }
    }

    private struct SendableMessage: @unchecked Sendable {
        let value: [String: Any]
    }

    private func request(
        method: String,
        params: [String: Any]? = nil,
        timeout: TimeInterval? = nil) async throws -> [String: Any]
    {
        let id = self.nextID
        self.nextID += 1
        try self.sendRequest(id: id, method: method, params: params)

        let resolvedTimeout = timeout ?? self.requestTimeoutSeconds
        let wrapped = try await self.withTimeout(seconds: resolvedTimeout, method: method) {
            while true {
                let message = try await self.readNextMessage()

                if message["id"] == nil {
                    continue
                }

                guard let messageID = self.jsonID(message["id"]), messageID == id else { continue }

                if let error = message["error"] as? [String: Any],
                   let messageText = error["message"] as? String {
                    throw CodexRPCError.requestFailed(messageText)
                }

                return SendableMessage(value: message)
            }
        }
        return wrapped.value
    }

    private func withTimeout<T: Sendable>(
        seconds: TimeInterval,
        method: String,
        body: @escaping @Sendable () async throws -> T) async throws -> T
    {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await body()
            }
            group.addTask { [weak self] in
                try await Task.sleep(for: .seconds(seconds))
                self?.terminateForTimeout()
                throw CodexRPCError.timeout(method: method)
            }
            guard let result = try await group.next() else {
                group.cancelAll()
                throw CodexRPCError.timeout(method: method)
            }
            group.cancelAll()
            return result
        }
    }

    private func terminateForTimeout() {
        if self.process.isRunning {
            self.process.terminate()
        }
    }

    private func sendNotification(method: String, params: [String: Any]? = nil) throws {
        try self.sendPayload(["method": method, "params": params ?? [:]])
    }

    private func sendRequest(id: Int, method: String, params: [String: Any]?) throws {
        try self.sendPayload(["id": id, "method": method, "params": params ?? [:]])
    }

    private func sendPayload(_ payload: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: payload)
        self.stdinPipe.fileHandleForWriting.write(data)
        self.stdinPipe.fileHandleForWriting.write(Data([0x0A]))
    }

    private func readNextMessage() async throws -> [String: Any] {
        while let lineData = await self.stdoutLineIterator.next() {
            if let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] {
                return json
            }
        }
        throw CodexRPCError.malformed("codex app-server closed stdout")
    }

    private func decodeResult<T: Decodable>(from message: [String: Any]) throws -> T {
        guard let result = message["result"] else {
            throw CodexRPCError.malformed("missing result field")
        }
        let data = try JSONSerialization.data(withJSONObject: result)
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func jsonID(_ value: Any?) -> Int? {
        switch value {
        case let int as Int:
            return int
        case let number as NSNumber:
            return number.intValue
        default:
            return nil
        }
    }
}

enum CLIUsageFetcher {
    static func fetch(
        profileId: String,
        authData: Data,
        codexConfigURL: URL,
        environment: [String: String] = ProcessInfo.processInfo.environment) async throws -> UsageSnapshot
    {
        let executablePath = CodexCLIResolver.resolvePath(environment: environment)
        guard let executablePath else { throw CodexRPCError.cliNotFound }

        let tempHome = try self.makeTemporaryCodexHome(profileId: profileId)
        defer { try? FileManager.default.removeItem(at: tempHome) }

        try atomicWriteData(authData, to: tempHome.appendingPathComponent("auth.json"))
        if FileManager.default.fileExists(atPath: codexConfigURL.path) {
            try? self.copyFile(from: codexConfigURL, to: tempHome.appendingPathComponent("config.toml"))
        }

        var env = environment
        env["CODEX_HOME"] = tempHome.path

        let rpc = try CodexRPCClient(executablePath: executablePath, environment: env)
        defer { rpc.shutdown() }

        try await rpc.initialize(clientName: AppInfo.name, clientVersion: AppInfo.version)
        let response = try await rpc.fetchRateLimits()
        return try self.makeSnapshot(from: response.rateLimits)
    }

    private static func makeTemporaryCodexHome(profileId: String) throws -> URL {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-profile-switcher-\(profileId)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: base,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        return base
    }

    private static func copyFile(from source: URL, to destination: URL) throws {
        let data = try Data(contentsOf: source)
        try atomicWriteData(data, to: destination)
    }

    private static func makeSnapshot(from rateLimits: RPCRateLimitSnapshot) throws -> UsageSnapshot {
        let creditsRemaining = rateLimits.credits.flatMap { credits -> Double? in
            guard let balance = credits.balance else { return nil }
            return Double(balance.replacingOccurrences(of: ",", with: ""))
        }

        let primaryResetAt = rateLimits.primary?.resetsAt.map { Date(timeIntervalSince1970: TimeInterval($0)) }
        let secondaryResetAt = rateLimits.secondary?.resetsAt.map { Date(timeIntervalSince1970: TimeInterval($0)) }
        let primaryUsedPercent = rateLimits.primary.map { Int($0.usedPercent.rounded()) } ?? 0
        let secondaryUsedPercent = rateLimits.secondary.map { Int($0.usedPercent.rounded()) } ?? 0

        if rateLimits.primary == nil, rateLimits.secondary == nil, creditsRemaining == nil {
            throw CLIUsageError.noRateLimitsFound
        }

        return UsageSnapshot(
            planType: rateLimits.planType,
            creditsRemaining: creditsRemaining,
            primaryUsedPercent: primaryUsedPercent,
            primaryResetAt: primaryResetAt,
            secondaryUsedPercent: secondaryUsedPercent,
            secondaryResetAt: secondaryResetAt,
            fetchedAt: Date())
    }
}

// MARK: - UsageProvider

final class UsageProvider {
    private let store: ProfileStore
    private var refreshTask: Task<Void, Never>?
    private var lastRefreshAll: Date = .distantPast
    private(set) var isRefreshing = false
    var onRefreshComplete: (() -> Void)?

    init(store: ProfileStore) {
        self.store = store
    }

    func cancelRefreshes() {
        self.refreshTask?.cancel()
        self.refreshTask = nil
        self.isRefreshing = false
    }

    func refreshAll(force: Bool = false) {
        guard !self.isRefreshing else { return }
        guard force || Date().timeIntervalSince(self.lastRefreshAll) > 60 else { return }

        if !force,
           self.store.statuses.values.allSatisfy({ if case .notSetUp = $0 { true } else { false } }) {
            return
        }

        self.lastRefreshAll = Date()
        self.isRefreshing = true

        let profiles = self.store.config.profiles
        let liveId = self.store.liveProfileId ?? ""
        let contexts: [(String, UsageSnapshot?)] = profiles.map { p in
            (p.id, self.store.cache.snapshots[p.id])
        }

        self.refreshTask = Task {
            await withTaskGroup(of: Void.self) { group in
                for (id, cached) in contexts {
                    group.addTask {
                        await self.refreshProfile(id, activeProfileId: liveId, cached: cached)
                    }
                }
            }
            await MainActor.run {
                self.isRefreshing = false
                self.refreshTask = nil
                self.store.flushCacheIfDirty()
                self.onRefreshComplete?()
            }
        }
    }

    private func refreshProfile(
        _ id: String, activeProfileId: String, cached: UsageSnapshot?
    ) async {
        guard !self.store.isAuthMutationInProgress() else { return }

        let selectedMode: UsageRefreshSource = .auto
        var diagnostics = ProfileRefreshDiagnostics(selectedMode: selectedMode)

        func setDiagnostics() async {
            let snapshot = diagnostics
            await MainActor.run { self.store.updateRefreshDiagnostics(id, snapshot) }
        }

        func finalize(_ status: ProfileStatus, decision: String) async {
            diagnostics.lastDecision = decision
            let snapshot = diagnostics
            await MainActor.run {
                if !self.canUseAuth(for: id, activeProfileId: activeProfileId) {
                    self.store.updateRefreshDiagnostics(id, snapshot)
                    self.store.updateStatus(id, .notSetUp)
                    return
                }
                self.store.updateRefreshDiagnostics(id, snapshot)
                self.store.updateStatus(id, status)
            }
        }

        func makeSnapshot(from response: UsageResponse) -> UsageSnapshot {
            UsageSnapshot(
                planType: response.planType,
                creditsRemaining: response.credits?.balance,
                primaryUsedPercent: response.rateLimit?.primaryWindow?.usedPercent ?? 0,
                primaryResetAt: response.rateLimit?.primaryWindow.map {
                    Date(timeIntervalSince1970: TimeInterval($0.resetAt))
                },
                secondaryUsedPercent: response.rateLimit?.secondaryWindow?.usedPercent ?? 0,
                secondaryResetAt: response.rateLimit?.secondaryWindow.map {
                    Date(timeIntervalSince1970: TimeInterval($0.resetAt))
                },
                fetchedAt: Date())
        }

        func fetchOAuthSnapshot() async throws -> UsageSnapshot {
            guard let authData = try self.store.authDataForUsage(profileId: id, activeProfileId: activeProfileId) else {
                throw AuthError.notFound
            }
            let creds = try await AuthRefresher.refreshIfNeeded(
                profileId: id,
                activeProfileId: activeProfileId,
                authData: authData,
                currentAuthData: {
                    try self.store.currentSavedAuthData(for: id)
                },
                saveUpdatedAuthData: { data in
                    try self.store.saveAuthDataToVault(data, for: id)
                })

            let response = try await UsageFetcher.fetch(
                accessToken: creds.accessToken,
                accountId: creds.accountId)
            return makeSnapshot(from: response)
        }

        func attemptCLIFallback(reason: OAuthFallbackReason, sourceError: Error) async {
            diagnostics.lastFallbackReason = reason.rawValue
            diagnostics.lastError = sourceError.localizedDescription
            AppLogger.info("Usage refresh falling back to Codex CLI",
                           metadata: [
                               "profile": id,
                               "from": UsageRefreshSource.oauth.rawValue,
                               "reason": reason.rawValue,
                           ])

            diagnostics.lastAttemptedSource = .cli
            await setDiagnostics()

            do {
                guard let authData = try self.store.authDataForUsage(
                    profileId: id,
                    activeProfileId: activeProfileId) else {
                    throw AuthError.notFound
                }
                let cliSnapshot = try await CLIUsageFetcher.fetch(
                    profileId: id,
                    authData: authData,
                    codexConfigURL: self.store.codexConfigURL())

                diagnostics.lastSuccessfulSource = .cli
                diagnostics.lastError = nil
                await finalize(.available(cliSnapshot), decision: "available")
                AppLogger.info("Usage refresh succeeded",
                               metadata: [
                                   "profile": id,
                                   "mode": selectedMode.rawValue,
                                   "source": UsageRefreshSource.cli.rawValue,
                                   "reason": reason.rawValue,
                               ])
            } catch is CancellationError {
                return
            } catch let error as CodexRPCError where error.isAuthRequired {
                diagnostics.lastError = error.localizedDescription
                await finalize(.reloginNeeded(cached), decision: "relogin-needed")
                AppLogger.warning("Codex CLI fallback requires re-login",
                                  metadata: [
                                      "profile": id,
                                      "reason": reason.rawValue,
                                      "error": error.localizedDescription,
                                  ])
            } catch {
                diagnostics.lastError = error.localizedDescription
                await finalize(.stale(cached), decision: "stale")
                AppLogger.warning("Codex CLI fallback failed",
                                  metadata: [
                                      "profile": id,
                                      "reason": reason.rawValue,
                                      "error": error.localizedDescription,
                                  ])
            }
        }

        do {
            guard self.canUseAuth(for: id, activeProfileId: activeProfileId) else {
                await finalize(.notSetUp, decision: "not-set-up")
                return
            }

            diagnostics.lastAttemptedSource = .oauth
            await setDiagnostics()

            let snapshot = try await fetchOAuthSnapshot()
            diagnostics.lastSuccessfulSource = .oauth
            diagnostics.lastError = nil
            await finalize(.available(snapshot), decision: "available")
            AppLogger.info("Usage refresh succeeded",
                           metadata: [
                               "profile": id,
                               "mode": selectedMode.rawValue,
                               "source": UsageRefreshSource.oauth.rawValue,
                           ])
        } catch is CancellationError {
            return
        } catch let error as UsageFetchError where error == .unauthorized {
            AppLogger.warning("Usage refresh unauthorized",
                              metadata: ["profile": id, "error": error.localizedDescription])
            await attemptCLIFallback(reason: .usageUnauthorized, sourceError: error)
        } catch let error as AuthError {
            AppLogger.warning("Auth refresh failed",
                              metadata: ["profile": id, "error": error.localizedDescription])
            switch error {
            case .refreshExpired:
                await attemptCLIFallback(reason: .refreshExpired, sourceError: error)
            case .refreshReused:
                await attemptCLIFallback(reason: .refreshReused, sourceError: error)
            case .refreshRevoked:
                await attemptCLIFallback(reason: .refreshRevoked, sourceError: error)
            case .missingTokens:
                await attemptCLIFallback(reason: .missingTokens, sourceError: error)
            case .notFound:
                diagnostics.lastError = error.localizedDescription
                await finalize(.notSetUp, decision: "not-set-up")
            default:
                diagnostics.lastError = error.localizedDescription
                await finalize(.stale(cached), decision: "stale")
            }
        } catch {
            AppLogger.warning("Usage refresh failed",
                              metadata: ["profile": id, "error": error.localizedDescription])
            diagnostics.lastError = error.localizedDescription
            await finalize(.stale(cached), decision: "stale")
        }
    }

    private func canUseAuth(for id: String, activeProfileId: String) -> Bool {
        if id == activeProfileId {
            return self.store.liveAuthExists()
        }
        return self.store.authStoreExists(for: id)
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

private enum Palette {
    static let accent = Color(red: 0.40, green: 0.55, blue: 0.75)
    static let accentLight = Color(red: 0.45, green: 0.58, blue: 0.72)
    static let success = Color(red: 0.40, green: 0.60, blue: 0.55)
    static let warning = Color(red: 0.75, green: 0.55, blue: 0.30)
    static let danger = Color(red: 0.75, green: 0.38, blue: 0.35)
    static let mid = Color(red: 0.70, green: 0.55, blue: 0.35)
}

func progressColor(for percent: Int) -> Color {
    if percent >= 80 { return Palette.danger }
    if percent >= 50 { return Palette.mid }
    return Palette.success
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

func creditsDisplayName(_ value: Double?) -> String? {
    guard let value else { return nil }
    let clamped = max(0, value)
    let formatter = NumberFormatter()
    formatter.numberStyle = .decimal
    formatter.maximumFractionDigits = clamped >= 100 ? 0 : 1
    formatter.minimumFractionDigits = 0
    guard let formatted = formatter.string(from: NSNumber(value: clamped)) else { return nil }
    return "\(formatted) cr"
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
        case .success: Palette.success
        case .error: Palette.danger
        case .info: Palette.accent
        }
    }

    private var borderColor: Color {
        switch self.state.style {
        case .success: Palette.success.opacity(0.3)
        case .error: Palette.danger.opacity(0.3)
        case .info: Palette.accent.opacity(0.3)
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
            context.fill(trackPath, with: .color(.primary.opacity(0.10)))

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
    let isHighlighted: Bool

    var body: some View {
        HStack(spacing: 4) {
            Text(self.label)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(self.isHighlighted ? .secondary : .tertiary)
                .frame(width: 16, alignment: .leading)

            UsageBar(percent: Double(self.percent), tint: progressColor(for: self.percent))

            Text("\(self.percent)%")
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(self.isHighlighted ? .primary : .secondary)
                .frame(width: 30, alignment: .trailing)

            Text(resetCountdown(from: self.resetAt))
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(self.isHighlighted ? .secondary : .tertiary)
                .frame(width: 42, alignment: .trailing)
        }
    }
}

struct ProfileCardView: View {
    let profile: ProfileConfig
    let status: ProfileStatus
    let isActive: Bool
    let duplicateLine: String?
    let onSwitch: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @State private var isHovered = false

    var body: some View {
        Button(action: self.onSwitch) {
            VStack(alignment: .leading, spacing: 4) {
                self.headerRow
                if let duplicateLine, !duplicateLine.isEmpty {
                    Label(duplicateLine, systemImage: "square.stack.3d.up.trianglebadge.exclamationmark")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(Palette.warning)
                        .lineLimit(1)
                }
                self.statusContent
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(width: 290, alignment: .leading)
            .contentShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        }
        .buttonStyle(ProfileCardButtonStyle(
            isActive: self.isActive,
            isHovered: self.isHovered,
            colorScheme: self.colorScheme))
        .onHover { hovering in
            self.isHovered = hovering
        }
        .animation(self.reduceMotion ? nil : .easeOut(duration: 0.16), value: self.isHovered)
    }

    private var headerRow: some View {
        HStack(spacing: 6) {
            Text(self.profile.label)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(self.titleColor)
                .lineLimit(1)

            Spacer()

            HStack(spacing: 5) {
                if let credits = self.credits {
                    Text(credits)
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(self.metadataColor)
                }

                if let planName = self.planType {
                    Text(planName)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(self.metadataColor)
                }
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
                .foregroundStyle(self.metadataColor)
        case .stale(let snap):
            if let snap {
                self.usageBars(snap)
            } else {
                Text("No data yet")
                    .font(.system(size: 10))
                    .foregroundStyle(self.metadataColor)
            }
        case .reloginNeeded(let snap):
            if let snap { self.usageBars(snap) }
            HStack(spacing: 4) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 9))
                Text("Re-login needed")
                    .font(.system(size: 10))
            }
            .foregroundStyle(Palette.warning)
        case .notSetUp:
            Text("Click to set up")
                .font(.system(size: 10))
                .foregroundStyle(Palette.accentLight)
        }
    }

    private func usageBars(_ snap: UsageSnapshot) -> some View {
        VStack(spacing: 2) {
            UsageRow(
                label: "5h",
                percent: snap.primaryUsedPercent,
                resetAt: snap.primaryResetAt,
                isHighlighted: self.isActive || self.isHovered)
            UsageRow(
                label: "Wk",
                percent: snap.secondaryUsedPercent,
                resetAt: snap.secondaryResetAt,
                isHighlighted: self.isActive || self.isHovered)
        }
    }

    private var planType: String? {
        guard let snap = self.status.snapshot else { return nil }
        return planDisplayName(snap.planType)
    }

    private var credits: String? {
        guard let snap = self.status.snapshot else { return nil }
        return creditsDisplayName(snap.creditsRemaining)
    }

    private var titleColor: Color {
        let base = Color(nsColor: .labelColor)
        return self.isActive || self.isHovered ? base : base.opacity(0.94)
    }

    private var metadataColor: Color {
        let base = Color(nsColor: .secondaryLabelColor)
        return self.isActive || self.isHovered ? base : base.opacity(0.82)
    }
}

private struct ProfileCardButtonStyle: ButtonStyle {
    let isActive: Bool
    let isHovered: Bool
    let colorScheme: ColorScheme

    func makeBody(configuration: Configuration) -> some View {
        let visualState = ProfileCardVisualState(
            isActive: self.isActive,
            isHovered: self.isHovered,
            isPressed: configuration.isPressed,
            colorScheme: self.colorScheme)

        return configuration.label
            .background {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(visualState.fillColor)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .strokeBorder(visualState.borderColor, lineWidth: visualState.borderWidth)
            }
    }
}

private struct ProfileCardVisualState {
    let isActive: Bool
    let isHovered: Bool
    let isPressed: Bool
    let colorScheme: ColorScheme

    var fillColor: Color {
        if self.isPressed {
            return self.neutralWash(dark: 0.14, light: 0.10)
        }
        if self.isActive && self.isHovered {
            return self.neutralWash(dark: 0.13, light: 0.085)
        }
        if self.isActive {
            return self.accentedWash(dark: 0.085, light: 0.055)
        }
        if self.isHovered {
            return self.neutralWash(dark: 0.085, light: 0.055)
        }
        return .clear
    }

    var borderColor: Color {
        if self.isPressed {
            return Palette.accent.opacity(self.colorScheme == .dark ? 0.26 : 0.22)
        }
        if self.isActive {
            return Palette.accent.opacity(self.colorScheme == .dark ? 0.22 : 0.18)
        }
        if self.isHovered {
            return Color.primary.opacity(self.colorScheme == .dark ? 0.12 : 0.08)
        }
        return .clear
    }

    var borderWidth: CGFloat {
        (self.isActive || self.isHovered || self.isPressed) ? 1 : 0
    }

    private func neutralWash(dark: Double, light: Double) -> Color {
        Color.primary.opacity(self.colorScheme == .dark ? dark : light)
    }

    private func accentedWash(dark: Double, light: Double) -> Color {
        Palette.accent.opacity(self.colorScheme == .dark ? dark : light)
    }
}

// MARK: - Menu Bar Icon

enum IconRenderer {
    static let iconSize = CGSize(width: 18, height: 18)
    private static let scale: CGFloat = 2
    private static let filledIconName = "codex-profile-switcher-menu-icon.png"
    private static let emptyIconName = "codex-profile-switcher-menu-icon-empty.png"

    static func render(primaryPercent: Int, secondaryPercent: Int) -> NSImage {
        Self.loadIcon(named: Self.filledIconName)
            ?? Self.renderStackedProfiles(showRearCard: true)
    }

    static func renderEmpty() -> NSImage {
        Self.loadIcon(named: Self.emptyIconName)
            ?? Self.renderStackedProfiles(showRearCard: false)
    }

    private static func loadIcon(named name: String) -> NSImage? {
        let candidates = [
            Bundle.main.resourceURL?.appendingPathComponent(name),
            Bundle.main.executableURL?
                .deletingLastPathComponent()
                .appendingPathComponent(name)
        ].compactMap { $0 }

        for url in candidates {
            guard let image = NSImage(contentsOf: url) else { continue }
            image.size = Self.iconSize
            image.isTemplate = true
            return image
        }

        return nil
    }

    private static func renderStackedProfiles(showRearCard: Bool) -> NSImage {
        let size = Self.iconSize

        let image = NSImage(size: size, flipped: false) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            ctx.scaleBy(x: Self.scale, y: Self.scale)
            if showRearCard {
                Self.drawRearCard(ctx: ctx)
            }
            Self.drawFrontCard(ctx: ctx)

            return true
        }

        image.isTemplate = true
        return image
    }

    private static func drawRearCard(ctx: CGContext) {
        let rearRect = CGRect(x: 5.2, y: 3.2, width: 8.8, height: 7.4)
        let rearPath = CGPath(roundedRect: rearRect, cornerWidth: 2.2, cornerHeight: 2.2, transform: nil)
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.18).cgColor)
        ctx.addPath(rearPath)
        ctx.fillPath()

        ctx.setStrokeColor(NSColor.black.withAlphaComponent(0.28).cgColor)
        ctx.setLineWidth(1.1)
        ctx.addPath(rearPath)
        ctx.strokePath()

        ctx.setStrokeColor(NSColor.black.withAlphaComponent(0.28).cgColor)
        ctx.setLineWidth(1.1)
        ctx.setLineCap(.round)
        ctx.move(to: CGPoint(x: 7.3, y: 6.2))
        ctx.addLine(to: CGPoint(x: 11.7, y: 6.2))
        ctx.strokePath()
    }

    private static func drawFrontCard(ctx: CGContext) {
        let frontRect = CGRect(x: 3.0, y: 6.4, width: 9.8, height: 8.4)
        let frontPath = CGPath(roundedRect: frontRect, cornerWidth: 2.4, cornerHeight: 2.4, transform: nil)
        ctx.setFillColor(NSColor.black.cgColor)
        ctx.addPath(frontPath)
        ctx.fillPath()

        ctx.setStrokeColor(NSColor.white.cgColor)
        ctx.setLineWidth(1.5)
        ctx.setLineCap(.round)
        ctx.move(to: CGPoint(x: 5.8, y: 10.6))
        ctx.addLine(to: CGPoint(x: 10.1, y: 10.6))
        ctx.strokePath()

        let markerRect = CGRect(x: 4.45, y: 9.65, width: 1.9, height: 1.9)
        let markerPath = CGPath(ellipseIn: markerRect, transform: nil)
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.addPath(markerPath)
        ctx.fillPath()
    }
}

// MARK: - CodexBridge (shells out to codex-profile wrapper)

enum CodexBridgeError: LocalizedError {
    case cliNotFound
    case loginAlreadyRunning
    case loginCancelled
    case loginTimedOut
    case launchFailed(String)
    case commandFailed(Int32, String)
    case stateUpdateFailed(String)

    var errorDescription: String? {
        switch self {
        case .cliNotFound:
            return "codex-profile helper not found"
        case .loginAlreadyRunning:
            return "Login is already running for this profile"
        case .loginCancelled:
            return "Login was cancelled"
        case .loginTimedOut:
            return "Login timed out. Start setup again to retry."
        case .launchFailed(let message):
            return message
        case .commandFailed(_, let output):
            return output.isEmpty ? "codex-profile command failed" : output
        case .stateUpdateFailed(let message):
            return message
        }
    }

    var isUserCancelled: Bool {
        if case .loginCancelled = self { return true }
        return false
    }
}

enum CodexBridge {
    private final class ActiveLogin {
        let process: Process
        let startedAt = Date()
        var cancelRequested = false
        var timedOut = false
        var timeoutWorkItem: DispatchWorkItem?

        init(process: Process) {
            self.process = process
        }
    }

    private static var activeLogins: [String: ActiveLogin] = [:]
    private static let staleLoginRetryInterval: TimeInterval = 5

    private static func pipeDrain(for pipe: Pipe) -> (start: @Sendable () -> Void, awaitOutput: @Sendable () -> String) {
        let group = DispatchGroup()
        nonisolated(unsafe) var captured = ""
        let start: @Sendable () -> Void = {
            group.enter()
            DispatchQueue.global(qos: .utility).async {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                captured = String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                group.leave()
            }
        }
        let awaitOutput: @Sendable () -> String = {
            group.wait()
            return captured
        }
        return (start, awaitOutput)
    }

    private static func codexProfilePath() -> String? {
        let candidates: [String?] = [
            Bundle.main.bundleURL.pathExtension == "app"
                ? Bundle.main.bundleURL
                    .appendingPathComponent("Contents/Helpers/codex-profile").path
                : nil,
            Bundle.main.executableURL?
                .deletingLastPathComponent()
                .appendingPathComponent("codex-profile").path,
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

    static func helperPathForDebug() -> String {
        self.codexProfilePath() ?? "<not found>"
    }

    static func isLoginRunning(profileId: String) -> Bool {
        dispatchPrecondition(condition: .onQueue(.main))
        return Self.activeLogins[profileId] != nil
    }

    @discardableResult
    static func cancelLogin(profileId: String) -> Bool {
        dispatchPrecondition(condition: .onQueue(.main))
        guard let active = Self.activeLogins[profileId] else { return false }
        active.cancelRequested = true
        active.timeoutWorkItem?.cancel()
        AppLogger.warning("Cancelling login", metadata: ["profile": profileId])
        active.process.terminate()
        return true
    }

    private static func runCommand(
        path: String,
        arguments: [String],
        completion: @escaping (Result<Void, CodexBridgeError>) -> Void
    ) {
        AppLogger.info("Running helper command",
                       metadata: ["path": path, "arguments": arguments.joined(separator: " ")])
        let proc = Process()
        let pipe = Pipe()
        proc.executableURL = URL(fileURLWithPath: path)
        proc.arguments = arguments
        proc.standardOutput = pipe
        proc.standardError = pipe

        let drain = pipeDrain(for: pipe)

        proc.terminationHandler = { p in
            let output = drain.awaitOutput()

            if p.terminationStatus == 0 {
                AppLogger.info("Helper command succeeded",
                               metadata: ["arguments": arguments.joined(separator: " ")])
                completion(.success(()))
            } else {
                AppLogger.error("Helper command failed",
                                metadata: [
                                    "arguments": arguments.joined(separator: " "),
                                    "status": "\(p.terminationStatus)",
                                    "output": output,
                                ])
                completion(.failure(.commandFailed(p.terminationStatus, output)))
            }
        }

        do {
            try proc.run()
            drain.start()
        } catch {
            AppLogger.error("Failed to launch helper command",
                            metadata: [
                                "path": path,
                                "arguments": arguments.joined(separator: " "),
                                "error": error.localizedDescription,
                            ])
            completion(.failure(.launchFailed(error.localizedDescription)))
        }
    }

    static func switchToProfile(_ profileId: String, workspacePath: String?) async -> Result<Void, CodexBridgeError> {
        await withCheckedContinuation { continuation in
            guard let path = Self.codexProfilePath() else {
                AppLogger.error("codex-profile helper not found")
                continuation.resume(returning: .failure(.cliNotFound))
                return
            }
            var arguments = ["app", profileId]
            if let workspacePath, !workspacePath.isEmpty {
                arguments.append(workspacePath)
            }
            Self.runCommand(path: path, arguments: arguments) { result in
                continuation.resume(returning: result)
            }
        }
    }

    static func startLogin(
        profileId: String,
        completion: @escaping (Result<Void, CodexBridgeError>) -> Void
    ) {
        dispatchPrecondition(condition: .onQueue(.main))
        if let active = Self.activeLogins[profileId] {
            let age = Date().timeIntervalSince(active.startedAt)
            guard age >= Self.staleLoginRetryInterval else {
                AppLogger.warning("Login already running", metadata: ["profile": profileId])
                completion(.failure(.loginAlreadyRunning))
                return
            }

            AppLogger.warning("Replacing stale login",
                              metadata: ["profile": profileId, "ageSeconds": "\(Int(age))"])
            active.cancelRequested = true
            active.timeoutWorkItem?.cancel()
            active.process.terminate()
            Self.activeLogins.removeValue(forKey: profileId)
        }
        guard let path = Self.codexProfilePath() else {
            AppLogger.error("codex-profile helper not found")
            completion(.failure(.cliNotFound))
            return
        }

        Self.runLoginCommand(path: path, profileId: profileId, completion: completion)
    }

    private static func runLoginCommand(
        path: String,
        profileId: String,
        completion: @escaping (Result<Void, CodexBridgeError>) -> Void
    ) {
        dispatchPrecondition(condition: .onQueue(.main))
        let arguments = ["login", profileId]
        AppLogger.info("Running helper command",
                       metadata: ["path": path, "arguments": arguments.joined(separator: " ")])

        let proc = Process()
        let pipe = Pipe()
        proc.executableURL = URL(fileURLWithPath: path)
        proc.arguments = arguments
        proc.standardOutput = pipe
        proc.standardError = pipe

        let active = ActiveLogin(process: proc)
        Self.activeLogins[profileId] = active

        let drain = pipeDrain(for: pipe)

        proc.terminationHandler = { p in
            let output = drain.awaitOutput()

            DispatchQueue.main.async {
                active.timeoutWorkItem?.cancel()
                if Self.activeLogins[profileId] === active {
                    Self.activeLogins.removeValue(forKey: profileId)
                }

                if active.timedOut {
                    AppLogger.error("Helper login timed out",
                                    metadata: ["arguments": arguments.joined(separator: " ")])
                    completion(.failure(.loginTimedOut))
                    return
                }

                if active.cancelRequested {
                    AppLogger.warning("Helper login cancelled",
                                      metadata: ["arguments": arguments.joined(separator: " ")])
                    completion(.failure(.loginCancelled))
                    return
                }

                if p.terminationStatus == 0 {
                    AppLogger.info("Helper command succeeded",
                                   metadata: ["arguments": arguments.joined(separator: " ")])
                    completion(.success(()))
                } else {
                    AppLogger.error("Helper command failed",
                                    metadata: [
                                        "arguments": arguments.joined(separator: " "),
                                        "status": "\(p.terminationStatus)",
                                        "output": output,
                                    ])
                    completion(.failure(.commandFailed(p.terminationStatus, output)))
                }
            }
        }

        do {
            try proc.run()
            drain.start()
            let timeout = Self.loginTimeoutSeconds()
            let timeoutWorkItem = DispatchWorkItem {
                DispatchQueue.main.async {
                    guard Self.activeLogins[profileId] === active else { return }
                    active.timedOut = true
                    AppLogger.warning("Terminating timed-out login",
                                      metadata: ["profile": profileId, "timeoutSeconds": "\(Int(timeout))"])
                    active.process.terminate()
                }
            }
            active.timeoutWorkItem = timeoutWorkItem
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout, execute: timeoutWorkItem)
        } catch {
            Self.activeLogins.removeValue(forKey: profileId)
            AppLogger.error("Failed to launch helper command",
                            metadata: [
                                "path": path,
                                "arguments": arguments.joined(separator: " "),
                                "error": error.localizedDescription,
                            ])
            completion(.failure(.launchFailed(error.localizedDescription)))
        }
    }

    private static func loginTimeoutSeconds() -> TimeInterval {
        let raw = ProcessInfo.processInfo.environment["CODEX_PROFILE_LOGIN_TIMEOUT_SECONDS"] ?? ""
        guard let value = Double(raw), value > 0 else { return 15 * 60 }
        return value
    }
}

// MARK: - Debug Info

enum DebugInfoBuilder {
    static func build(store: ProfileStore) -> String {
        var lines: [String] = [
            "\(AppInfo.name) Debug Info",
            "generated_at: \(ISO8601DateFormatter().string(from: Date()))",
            "app_version: \(AppInfo.version)",
            "macos: \(ProcessInfo.processInfo.operatingSystemVersionString)",
            "executable: \(ProcessInfo.processInfo.arguments.first ?? "<unknown>")",
            "helper: \(CodexBridge.helperPathForDebug())",
            "log_file: \(AppLogger.logURL.path)",
            "",
            "State:",
        ]

        lines.append(contentsOf: store.debugSummaryLines().map { "  \($0)" })
        lines.append("")
        lines.append("Recent Logs:")
        lines.append(AppLogger.recentLines(limit: 200))
        return LogRedactor.redact(lines.joined(separator: "\n"))
    }

    static func copyToPasteboard(store: ProfileStore) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(Self.build(store: store), forType: .string)
        AppLogger.info("Copied debug info to pasteboard")
    }

    static func openLogFile() {
        AppLogger.info("Opening log file", metadata: ["path": AppLogger.logURL.path])
        if !FileManager.default.fileExists(atPath: AppLogger.logURL.path) {
            try? FileManager.default.createDirectory(
                at: AppLogger.logURL.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            FileManager.default.createFile(atPath: AppLogger.logURL.path, contents: nil,
                                           attributes: [.posixPermissions: 0o600])
        }
        NSWorkspace.shared.open(AppLogger.logURL)
    }

    static func reportBug() {
        AppLogger.info("Opening bug report URL")
        var components = URLComponents(url: AppInfo.issueURL, resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "title", value: "Bug: "),
            URLQueryItem(name: "body", value: """
            ## What happened


            ## Debug info
            Paste the output from Settings > General > Copy Debug Info here.
            """),
        ]
        NSWorkspace.shared.open(components?.url ?? AppInfo.issueURL)
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var store: ProfileStore!
    private var usageProvider: UsageProvider!
    private var periodicRefreshTimer: Timer?
    private var menu: NSMenu!
    private var liveAuthWarning: LiveAuthWarning?
    private var lastLiveAuthMtime: Date?
    private var isMenuOpen = false
    private var menuRefreshRetryTask: Task<Void, Never>?

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppLogger.info("App launched", metadata: ["version": AppInfo.version])
        self.store = ProfileStore()
        self.usageProvider = UsageProvider(store: self.store)
        self.syncActiveProfile(force: true)

        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.statusItem.button?.image = IconRenderer.renderEmpty()
        self.statusItem.button?.imageScaling = .scaleNone

        self.menu = NSMenu()
        self.menu.delegate = self
        self.statusItem.menu = self.menu

        self.registerWorkspaceObservers()
        self.usageProvider.onRefreshComplete = { [weak self] in
            self?.handleRefreshComplete()
        }
        self.usageProvider.refreshAll()
        self.startPeriodicRefreshTimer()
    }

    deinit {
        self.periodicRefreshTimer?.invalidate()
        self.menuRefreshRetryTask?.cancel()
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    // MARK: - NSMenuDelegate

    func menuWillOpen(_ menu: NSMenu) {
        self.isMenuOpen = true
        self.syncActiveProfile()
        self.rebuildMenu()
        self.usageProvider.refreshAll()
        self.scheduleOpenMenuRefreshRetry()
    }

    func menuDidClose(_ menu: NSMenu) {
        self.isMenuOpen = false
        self.menuRefreshRetryTask?.cancel()
        self.menuRefreshRetryTask = nil
    }

    // MARK: - Timer

    private func startPeriodicRefreshTimer() {
        self.periodicRefreshTimer?.invalidate()
        self.periodicRefreshTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            self?.syncActiveProfile()
            self?.usageProvider.refreshAll()
        }
    }

    private func registerWorkspaceObservers() {
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(self.handleSystemWake),
            name: NSWorkspace.didWakeNotification,
            object: nil)
    }

    @objc private func handleSystemWake() {
        AppLogger.info("System woke; forcing usage refresh")
        self.syncActiveProfile(force: true)
        self.updateIcon()
        self.usageProvider.refreshAll(force: true)
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        self.syncActiveProfile()
        self.usageProvider.refreshAll()
    }

    private func handleRefreshComplete() {
        self.updateIcon()
        guard self.isMenuOpen else { return }
        self.rebuildMenu()
    }

    private func scheduleOpenMenuRefreshRetry() {
        self.menuRefreshRetryTask?.cancel()
        self.menuRefreshRetryTask = Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: .seconds(1.2))
            guard !Task.isCancelled else { return }
            guard self.isMenuOpen else { return }
            guard !self.usageProvider.isRefreshing else { return }
            guard self.hasDisplayedStaleOrLoadingProfiles() else { return }
            AppLogger.info("Retrying menu-open usage refresh because stale data is still visible")
            self.usageProvider.refreshAll(force: true)
        }
    }

    private func hasDisplayedStaleOrLoadingProfiles() -> Bool {
        self.store.config.profiles.contains { profile in
            switch self.store.statuses[profile.id] ?? .notSetUp {
            case .loading, .stale:
                return true
            default:
                return false
            }
        }
    }

    // MARK: - Icon

    func updateIcon() {
        guard let activeId = self.store.liveProfileId else {
            self.statusItem.button?.image = IconRenderer.renderEmpty()
            return
        }

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

        if let warning = self.liveAuthWarning {
            let warningItem = NSMenuItem(title: warning.message, action: nil, keyEquivalent: "")
            warningItem.isEnabled = false
            warningItem.image = NSImage(
                systemSymbolName: "exclamationmark.triangle.fill",
                accessibilityDescription: nil)
            self.menu.addItem(warningItem)
            self.menu.addItem(.separator())
        }

        for profile in self.store.config.profiles {
            let isActive = profile.id == self.store.liveProfileId
            let status = self.store.statuses[profile.id] ?? .notSetUp
            let duplicateLine = self.duplicateSummary(for: profile.id)

            let cardView = ProfileCardView(
                profile: profile,
                status: status,
                isActive: isActive,
                duplicateLine: duplicateLine,
                onSwitch: { [weak self] in self?.switchToProfile(profile.id) })

            let hostView = NSHostingView(rootView: cardView)
            hostView.frame = NSRect(
                x: 0,
                y: 0,
                width: 290,
                height: self.cardHeight(for: status, hasDuplicate: duplicateLine != nil))

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

        let quitItem = NSMenuItem()
        quitItem.title = "Quit"
        quitItem.action = #selector(NSApplication.terminate(_:))
        quitItem.keyEquivalent = "q"
        quitItem.target = NSApp
        quitItem.image = NSImage(systemSymbolName: "xmark.circle", accessibilityDescription: nil)
        quitItem.image?.size = NSSize(width: 13, height: 13)
        self.menu.addItem(quitItem)
    }

    private func cardHeight(for status: ProfileStatus, hasDuplicate: Bool) -> CGFloat {
        var height: CGFloat
        switch status {
        case .available: height = 58
        case .stale(let s) where s != nil: height = 68
        case .reloginNeeded(let s) where s != nil: height = 68
        default: height = 42
        }

        if hasDuplicate { height += 14 }
        return height
    }

    private func duplicateSummary(for profileId: String) -> String? {
        let duplicates = self.store.duplicateProfileIDs(for: profileId)
        guard !duplicates.isEmpty else { return nil }
        let names = duplicates.map { duplicateId in
            self.store.config.profiles.first(where: { $0.id == duplicateId })?.label ?? "Profile \(duplicateId)"
        }
        if names.count == 1, let name = names.first {
            return "Same account as \(name)"
        }
        return "Same account as \(names.joined(separator: ", "))"
    }

    // MARK: - Profile Sync

    private func syncActiveProfile(force: Bool = false) {
        guard !self.store.isAuthMutationInProgress() else { return }

        if !force {
            let mtime = self.store.liveAuthModificationDate()
            if mtime == self.lastLiveAuthMtime { return }
            self.lastLiveAuthMtime = mtime
        } else {
            self.lastLiveAuthMtime = nil
        }

        let matches = self.store.matchingProfilesForLiveAuth()
        if matches.count == 1, let match = matches.first {
            self.store.setLiveProfileId(match)
            self.liveAuthWarning = nil
            if self.store.config.activeProfile != match {
                self.store.setActiveProfile(match)
            }
            return
        }

        if matches.count > 1 {
            let preferred = self.store.liveProfileId ?? self.store.config.activeProfile
            if !preferred.isEmpty, matches.contains(preferred) {
                self.store.setLiveProfileId(preferred)
                self.liveAuthWarning = nil
            } else {
                self.store.setLiveProfileId(nil)
                self.liveAuthWarning = .ambiguous
                AppLogger.warning("Live auth matched multiple saved profiles",
                                  metadata: ["matches": matches.joined(separator: ",")])
            }
            return
        }

        self.store.setLiveProfileId(nil)
        let allNotSetUp = self.store.statuses.values.allSatisfy {
            if case .notSetUp = $0 { return true }
            return false
        }
        self.liveAuthWarning = self.store.liveAuthExists() && !allNotSetUp ? .unmanaged : nil
        if self.liveAuthWarning == .unmanaged {
            AppLogger.warning("Live auth does not match any saved profile")
        }
    }

    // MARK: - Actions

    private func switchToProfile(_ id: String) {
        self.menu.cancelTracking()
        AppLogger.info("Profile selected", metadata: ["profile": id])

        let isActive = id == self.store.liveProfileId
        let status = self.store.statuses[id]

        func startLogin() {
            self.startLogin(for: id, presentFailureAlert: true) { _ in
            }
        }

        switch status {
        case .notSetUp:
            startLogin()
            return
        case .reloginNeeded:
            if !self.store.authStoreExists(for: id) {
                AppLogger.warning("Profile requires login and has no saved auth; starting login",
                                  metadata: ["profile": id])
                startLogin()
                return
            }
        default:
            if isActive { return }
            if !self.store.authStoreExists(for: id) {
                AppLogger.warning("Profile has cached usage but no saved auth; starting login",
                                  metadata: ["profile": id])
                startLogin()
                return
            }
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

        let storeRef = self.store!
        let workspacePath = self.store.relaunchWorkspacePath()
        storeRef.beginAuthMutation()
        Task { [weak self] in
            let result = await CodexBridge.switchToProfile(id, workspacePath: workspacePath)
            storeRef.endAuthMutation()
            guard let self else { return }
            switch result {
            case .success:
                AppLogger.info("Profile switch succeeded", metadata: ["profile": id])
                self.store.setActiveProfile(id)
                self.store.setLiveProfileId(id)
                self.liveAuthWarning = nil
                self.usageProvider.refreshAll(force: true)
                self.updateIcon()
            case .failure(let error):
                self.syncActiveProfile(force: true)
                self.updateIcon()
                self.presentBridgeError(title: "Switch failed", message: error.localizedDescription)
            }
        }
    }

    @objc private func refreshAll() {
        self.syncActiveProfile(force: true)
        self.usageProvider.refreshAll(force: true)
    }

    @objc private func openSettings() {
        self.menu.cancelTracking()
        SettingsWindow.show(
            store: self.store,
            actions: SettingsActions(
                reauthenticateProfile: { [weak self] (id: String, completion: @escaping (Result<Void, SettingsActionError>) -> Void) in
                    self?.startLogin(for: id, presentFailureAlert: false) { result in
                        completion(result.mapError { SettingsActionError(message: $0.localizedDescription) })
                    }
                },
                cancelLogin: { id in
                    CodexBridge.cancelLogin(profileId: id)
                },
                clearSavedAuth: { [weak self] (id: String) in
                    guard let self else {
                        return .failure(SettingsActionError(message: "Settings window is unavailable."))
                    }
                    return self.clearSavedAuth(for: id)
                }))
    }

    private func presentBridgeError(title: String, message: String?) {
        AppLogger.error(title, metadata: ["message": message ?? "Unknown error"])
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message ?? "Unknown error"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    private func startLogin(
        for profileId: String,
        presentFailureAlert: Bool,
        completion: ((Result<Void, CodexBridgeError>) -> Void)? = nil
    ) {
        let store = self.store!
        store.beginAuthMutation()
        CodexBridge.startLogin(profileId: profileId) { [weak self] result in
            guard let self else {
                store.endAuthMutation()
                return
            }

            let finalResult: Result<Void, CodexBridgeError>

            switch result {
            case .success:
                AppLogger.info("Login succeeded", metadata: ["profile": profileId])
                if self.store.liveProfileId == profileId {
                    do {
                        try self.store.syncSavedAuthToLive(for: profileId)
                    } catch {
                        AppLogger.error("Failed to update live auth after login",
                                        metadata: ["profile": profileId, "error": error.localizedDescription])
                        store.endAuthMutation()
                        let failure = CodexBridgeError.stateUpdateFailed(
                            "Login succeeded but the active profile could not update live auth: \(error.localizedDescription)")
                        if presentFailureAlert {
                            self.presentBridgeError(title: "Login failed", message: failure.localizedDescription)
                        }
                        completion?(.failure(failure))
                        return
                    }
                }
                store.endAuthMutation()
                self.syncActiveProfile(force: true)
                self.usageProvider.refreshAll(force: true)
                self.updateIcon()
                finalResult = .success(())
            case .failure(let error):
                store.endAuthMutation()
                if presentFailureAlert && !error.isUserCancelled {
                    self.presentBridgeError(title: "Login failed", message: error.localizedDescription)
                }
                finalResult = .failure(error)
            }

            completion?(finalResult)
        }
    }

    private func clearSavedAuth(for profileId: String) -> Result<Void, SettingsActionError> {
        do {
            self.usageProvider.cancelRefreshes()
            try self.store.clearSavedAuth(for: profileId)
            self.syncActiveProfile(force: true)
            self.usageProvider.refreshAll(force: true)
            self.updateIcon()
            return .success(())
        } catch {
            return .failure(SettingsActionError(message: error.localizedDescription))
        }
    }
}

// MARK: - Settings Window

struct SettingsActions {
    let reauthenticateProfile: (String, @escaping (Result<Void, SettingsActionError>) -> Void) -> Void
    let cancelLogin: (String) -> Bool
    let clearSavedAuth: (String) -> Result<Void, SettingsActionError>
}

enum SettingsWindow {
    private static var windowController: NSWindowController?

    static func show(store: ProfileStore, actions: SettingsActions) {
        if let wc = Self.windowController {
            wc.window?.contentView = NSHostingView(rootView: SettingsView(store: store, actions: actions))
            wc.showWindow(nil)
            wc.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 620),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false)
        window.title = "Settings"
        window.center()
        window.isReleasedWhenClosed = false

        let view = SettingsView(store: store, actions: actions)
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
    let actions: SettingsActions
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
                case 0: ProfilesTab(store: self.store, actions: self.actions, toast: self.toast)
                case 1: GeneralTab(store: self.store, toast: self.toast)
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
    let actions: SettingsActions
    @ObservedObject var toast: ToastState
    @State private var selectedId: String?
    @State private var editingLabel: String = ""
    @State private var profiles: [ProfileConfig] = []
    @State private var pendingDeleteId: String?
    @State private var pendingClearAuthId: String?
    @State private var actionInFlight: Set<String> = []
    @State private var refreshTick = 0
    @FocusState private var labelFieldFocused: Bool

    var body: some View {
        HStack(spacing: 0) {
            self.sidebar
            Divider()
            self.detailPanel
        }
        .onAppear {
            self.profiles = self.store.config.profiles
            self.selectedId = self.store.liveProfileId ?? self.profiles.first?.id
            self.syncEditingLabel()
        }
        .onDisappear { self.commitLabel() }
        .alert("Delete Profile", isPresented: Binding(
            get: { self.pendingDeleteId != nil },
            set: { if !$0 { self.pendingDeleteId = nil } }
        )) {
            Button("Cancel", role: .cancel) { self.pendingDeleteId = nil }
            Button("Delete", role: .destructive) {
                if let id = self.pendingDeleteId {
                    let label = self.profileLabel(id)
                    if self.removeProfile(id) {
                        self.toast.show("Deleted \(label)", style: .info)
                    }
                }
                self.pendingDeleteId = nil
            }
        } message: {
            if let id = self.pendingDeleteId {
                Text("Are you sure you want to delete \"\(self.profileLabel(id))\"? This cannot be undone.")
            }
        }
        .confirmationDialog("Clear Saved Auth", isPresented: Binding(
            get: { self.pendingClearAuthId != nil },
            set: { if !$0 { self.pendingClearAuthId = nil } }
        )) {
            Button("Cancel", role: .cancel) { self.pendingClearAuthId = nil }
            Button("Clear", role: .destructive) {
                if let id = self.pendingClearAuthId {
                    self.clearSavedAuth(id)
                }
                self.pendingClearAuthId = nil
            }
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(spacing: 0) {
            List(selection: self.$selectedId) {
                Section("Profiles") {
                    ForEach(self.profiles) { profile in
                        self.sidebarRow(profile)
                            .tag(profile.id)
                    }
                }
            }
            .listStyle(.sidebar)
            .onChange(of: self.selectedId) { _, _ in
                self.commitLabel()
                self.syncEditingLabel()
            }

            Divider()

            HStack(spacing: 0) {
                Button(action: self.addProfile) {
                    Image(systemName: "plus")
                        .frame(width: 24, height: 20)
                }
                .buttonStyle(.borderless)

                Divider().frame(height: 14)

                Button {
                    if let id = self.selectedId { self.pendingDeleteId = id }
                } label: {
                    Image(systemName: "minus")
                        .frame(width: 24, height: 20)
                }
                .buttonStyle(.borderless)
                .disabled(self.selectedId == nil)

                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
        }
        .frame(width: 200)
    }

    @ViewBuilder
    private func sidebarRow(_ profile: ProfileConfig) -> some View {
        let details = self.store.authDetails(for: profile.id)
        let isActive = self.store.liveProfileId == profile.id
        let hasSavedAuth = self.store.authStoreExists(for: profile.id)

        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 5) {
                Text(profile.label)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                if isActive {
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: 7, height: 7)
                }
            }
            Text(hasSavedAuth ? (details?.menuSummary ?? "Authenticated") : "Not set up")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.vertical, 2)
        .id("\(profile.id)-\(self.refreshTick)")
    }

    // MARK: - Detail Panel

    @ViewBuilder
    private var detailPanel: some View {
        if let id = self.selectedId,
           let profile = self.profiles.first(where: { $0.id == id }) {
            self.profileDetail(profile)
        } else {
            Text("No profile selected")
                .font(.system(size: 13))
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private func profileDetail(_ profile: ProfileConfig) -> some View {
        let details = self.store.authDetails(for: profile.id)
        let hasSavedAuth = self.store.authStoreExists(for: profile.id)
        let isActive = self.store.liveProfileId == profile.id
        let status = self.store.statuses[profile.id] ?? .notSetUp
        let loginRunning = CodexBridge.isLoginRunning(profileId: profile.id)
        let inFlight = self.actionInFlight.contains(profile.id) || loginRunning
        let duplicates = self.store.duplicateProfileIDs(for: profile.id)

        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if !duplicates.isEmpty {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(Palette.warning)
                            .font(.system(size: 12))
                        Text("Same account as \(self.duplicateNames(for: duplicates))")
                            .font(.system(size: 12))
                            .foregroundStyle(Palette.warning)
                    }
                }

                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("Label:")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .frame(width: 60, alignment: .trailing)
                    TextField("", text: self.$editingLabel)
                        .textFieldStyle(.roundedBorder)
                        .focused(self.$labelFieldFocused)
                        .onSubmit { self.commitLabel() }
                        .onExitCommand { self.syncEditingLabel() }
                        .onChange(of: self.labelFieldFocused) { _, focused in
                            if !focused { self.commitLabel() }
                        }
                        .disabled(inFlight)
                }

                if hasSavedAuth {
                    if let details {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text("Account:")
                                .font(.system(size: 13))
                                .foregroundStyle(.secondary)
                                .frame(width: 60, alignment: .trailing)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(details.settingsTitle)
                                    .font(.system(size: 13))
                                    .textSelection(.enabled)

                                if !details.settingsDetails.isEmpty,
                                   details.settingsDetails != "No additional identity details" {
                                    Text(details.settingsDetails)
                                        .font(.system(size: 12))
                                        .foregroundStyle(.secondary)
                                        .textSelection(.enabled)
                                }
                            }
                        }
                    }

                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("Status:")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                            .frame(width: 60, alignment: .trailing)
                        HStack(spacing: 6) {
                            Circle()
                                .fill(self.statusColor(for: status))
                                .frame(width: 7, height: 7)
                            Text(self.statusLabel(for: status))
                                .font(.system(size: 13))
                            if isActive {
                                Text("(active)")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        if loginRunning {
                            Button("Cancel Login") { self.cancelLogin(profile.id) }
                        } else {
                            Button("Set Up") { self.reauthenticate(profile.id) }
                                .disabled(inFlight)
                        }
                        Text("Link your OpenAI account to start tracking usage.")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.leading, 68)
                }

                if hasSavedAuth {
                    HStack(spacing: 8) {
                        if loginRunning {
                            Button("Cancel Login") { self.cancelLogin(profile.id) }
                        } else {
                            Button("Re-authenticate\u{2026}") {
                                self.reauthenticate(profile.id)
                            }
                            .disabled(inFlight)
                        }

                        Button("Clear Auth\u{2026}") { self.pendingClearAuthId = profile.id }
                            .disabled(inFlight || isActive)
                    }
                    .padding(.leading, 68)
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Actions

    private func syncEditingLabel() {
        guard let id = self.selectedId,
              let profile = self.profiles.first(where: { $0.id == id }) else {
            self.editingLabel = ""
            return
        }
        self.editingLabel = profile.label
    }

    private func commitLabel() {
        guard let id = self.selectedId else { return }
        let trimmed = self.editingLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        self.store.updateLabel(for: id, label: trimmed)
        self.profiles = self.store.config.profiles
    }

    private func addProfile() {
        self.commitLabel()
        let profile = self.store.addProfile()
        self.profiles = self.store.config.profiles
        self.selectedId = profile.id
        self.toast.show("Added \(profile.label)", style: .success)
    }

    private func removeProfile(_ id: String) -> Bool {
        do {
            try self.store.removeProfile(id)
            self.profiles = self.store.config.profiles
            if self.selectedId == id {
                self.selectedId = self.profiles.first?.id
                self.syncEditingLabel()
            }
            return true
        } catch {
            self.toast.show(error.localizedDescription, style: .error)
            return false
        }
    }

    private func reauthenticate(_ profileId: String) {
        self.commitLabel()
        self.actionInFlight.insert(profileId)
        self.actions.reauthenticateProfile(profileId) { result in
            DispatchQueue.main.async(execute: {
                self.actionInFlight.remove(profileId)
                self.refreshTick += 1
                self.profiles = self.store.config.profiles
                self.syncEditingLabel()
                switch result {
                case .success:
                    self.toast.show("Updated auth for \(self.profileLabel(profileId))", style: .success)
                case .failure(let error):
                    self.toast.show(error.localizedDescription, style: .error)
                }
            })
        }
    }

    private func cancelLogin(_ profileId: String) {
        if self.actions.cancelLogin(profileId) {
            self.actionInFlight.remove(profileId)
            self.refreshTick += 1
            self.toast.show("Cancelled login for \(self.profileLabel(profileId))", style: .info)
        }
    }

    private func clearSavedAuth(_ profileId: String) {
        switch self.actions.clearSavedAuth(profileId) {
        case .success:
            self.refreshTick += 1
            self.profiles = self.store.config.profiles
            self.syncEditingLabel()
            self.toast.show("Cleared auth for \(self.profileLabel(profileId))", style: .info)
        case .failure(let error):
            self.toast.show(error.localizedDescription, style: .error)
        }
    }

    private func profileLabel(_ id: String) -> String {
        self.profiles.first(where: { $0.id == id })?.label ?? "Profile \(id)"
    }

    private func duplicateNames(for duplicates: [String]) -> String {
        let names = duplicates.map { self.profileLabel($0) }
        return names.count == 1 ? (names.first ?? "") : names.joined(separator: ", ")
    }

    private func statusLabel(for status: ProfileStatus) -> String {
        switch status {
        case .available: return "Ready"
        case .loading: return "Refreshing"
        case .stale: return "Cached"
        case .reloginNeeded: return "Re-login needed"
        case .notSetUp: return "Not set up"
        }
    }

    private func statusColor(for status: ProfileStatus) -> Color {
        switch status {
        case .available: return Palette.success
        case .loading: return Palette.accent
        case .stale: return .secondary
        case .reloginNeeded: return Palette.warning
        case .notSetUp: return .secondary.opacity(0.5)
        }
    }
}

struct GeneralTab: View {
    let store: ProfileStore
    @ObservedObject var toast: ToastState
    @State private var launchAtLogin = LaunchAtLogin.isEnabled

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 10) {
                Text("STARTUP")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)

                Toggle("Launch at Login", isOn: self.$launchAtLogin)
                    .onChange(of: self.launchAtLogin) { _, _ in LaunchAtLogin.toggle() }

                Text("Opens automatically when your Mac starts.")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                Text("SUPPORT")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)

                HStack(spacing: 8) {
                    Button {
                        DebugInfoBuilder.copyToPasteboard(store: self.store)
                        self.toast.show("Copied debug info", style: .success)
                    } label: {
                        Label("Copy Debug Info", systemImage: "doc.on.doc")
                    }

                    Button {
                        DebugInfoBuilder.openLogFile()
                    } label: {
                        Label("Open Log", systemImage: "doc.text.magnifyingglass")
                    }
                }

                Button {
                    DebugInfoBuilder.reportBug()
                } label: {
                    Label("Report Bug", systemImage: "exclamationmark.bubble")
                }

                Text(AppLogger.logURL.path)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
                    .textSelection(.enabled)
            }

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

            Text(AppInfo.name)
                .font(.system(size: 16, weight: .bold))

            Text("Version \(AppInfo.version)")
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
            do {
                try FileManager.default.removeItem(at: Self.plistURL)
                AppLogger.info("Disabled Launch at Login")
            } catch {
                AppLogger.error("Failed to disable Launch at Login", metadata: ["error": error.localizedDescription])
            }
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
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let data = try PropertyListSerialization.data(fromPropertyList: plistDict, format: .xml, options: 0)
            try data.write(to: Self.plistURL, options: .atomic)
            AppLogger.info("Enabled Launch at Login")
        } catch {
            AppLogger.error("Failed to enable Launch at Login", metadata: ["error": error.localizedDescription])
        }
    }
}

// MARK: - Entry Point

#if !TESTING
@main
#endif
enum Main {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        let appMenu = NSMenu()
        appMenu.addItem(
            withTitle: "Hide Codex Profile Switcher",
            action: #selector(NSApplication.hide(_:)),
            keyEquivalent: "h")
        let hideOthers = appMenu.addItem(
            withTitle: "Hide Others",
            action: #selector(NSApplication.hideOtherApplications(_:)),
            keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(
            withTitle: "Show All",
            action: #selector(NSApplication.unhideAllApplications(_:)),
            keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(
            withTitle: "Quit Codex Profile Switcher",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q")
        let appMenuItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        appMenuItem.submenu = appMenu

        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(
            withTitle: "Close Window",
            action: #selector(NSWindow.performClose(_:)),
            keyEquivalent: "w")
        let fileMenuItem = NSMenuItem(title: "File", action: nil, keyEquivalent: "")
        fileMenuItem.submenu = fileMenu

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

        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(
            withTitle: "Minimize",
            action: #selector(NSWindow.performMiniaturize(_:)),
            keyEquivalent: "m")
        let windowMenuItem = NSMenuItem(title: "Window", action: nil, keyEquivalent: "")
        windowMenuItem.submenu = windowMenu

        let mainMenu = NSMenu()
        mainMenu.addItem(appMenuItem)
        mainMenu.addItem(fileMenuItem)
        mainMenu.addItem(editMenuItem)
        mainMenu.addItem(windowMenuItem)
        app.mainMenu = mainMenu

        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}
