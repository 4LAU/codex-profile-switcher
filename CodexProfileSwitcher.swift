import Cocoa
import CryptoKit
import SwiftUI

// MARK: - App Info

enum AppInfo {
    static let name = "CodexProfileSwitcher"
    static let version = "0.1.0"
    static let issueURL = URL(string: "https://github.com/aaronlau/codex-profile-switcher/issues/new")!
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

    private static func timestamp() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date())
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

private func dictStringValue(_ dict: [String: Any], _ keys: String...) -> String? {
    for key in keys {
        if let value = dict[key] as? String, !value.isEmpty { return value }
    }
    return nil
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

// MARK: - ProfileStore

final class ProfileStore {
    private let configDir: URL
    private let configURL: URL
    private let cacheURL: URL
    private let authStoreDir: URL
    private let codexHome: URL
    private let codexAuthPath: URL
    private let fileManager = FileManager.default
    private let authMutationLock = NSLock()
    private var authMutationInProgress = false
    private var cacheDirty = false

    private(set) var config: AppConfig
    private(set) var cache: UsageCache
    private(set) var statuses: [String: ProfileStatus] = [:]
    private(set) var liveProfileId: String?

    init() {
        let home = self.fileManager.homeDirectoryForCurrentUser
        self.configDir = home.appendingPathComponent(".codex-switcher")
        self.configURL = self.configDir.appendingPathComponent("config.json")
        self.cacheURL = self.configDir.appendingPathComponent("cache.json")
        self.authStoreDir = self.configDir.appendingPathComponent("auth", isDirectory: true)
        self.codexHome = home.appendingPathComponent(".codex", isDirectory: true)
        self.codexAuthPath = self.codexHome.appendingPathComponent("auth.json")

        do {
            try self.fileManager.createDirectory(at: self.configDir, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
            try self.fileManager.createDirectory(at: self.authStoreDir, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        } catch {
            AppLogger.error("Failed to create app directories", metadata: ["error": error.localizedDescription])
        }

        if let data = try? Data(contentsOf: self.configURL),
           let loaded = try? JSONDecoder().decode(AppConfig.self, from: data) {
            self.config = loaded
        } else {
            if self.fileManager.fileExists(atPath: self.configURL.path) {
                AppLogger.warning("Config exists but could not be decoded",
                                  metadata: ["path": self.configURL.path])
            }
            self.config = AppConfig(profiles: [], activeProfile: "1")
        }

        let cacheDecoder = JSONDecoder()
        cacheDecoder.dateDecodingStrategy = .iso8601
        let cacheData = try? Data(contentsOf: self.cacheURL)
        self.cache = cacheData.flatMap { try? cacheDecoder.decode(UsageCache.self, from: $0) }
            ?? UsageCache(snapshots: [:])
        if cacheData != nil, self.cache.snapshots.isEmpty {
            AppLogger.warning("Cache exists but could not be decoded", metadata: ["path": self.cacheURL.path])
        }

        self.migrateLegacyProfiles()
        self.discoverProfiles()
        self.liveProfileId = self.config.activeProfile.isEmpty ? nil : self.config.activeProfile
        self.refreshStatusesFromStoredAuth()
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

    func removeProfile(_ id: String) {
        self.config.profiles.removeAll { $0.id == id }
        self.statuses.removeValue(forKey: id)
        self.cache.snapshots.removeValue(forKey: id)
        do {
            try self.fileManager.removeItem(at: self.authStorePath(for: id))
        } catch let error as CocoaError where error.code == .fileNoSuchFile {
        } catch {
            AppLogger.warning("Failed to remove saved profile auth",
                              metadata: ["profile": id, "error": error.localizedDescription])
        }
        if self.config.activeProfile == id {
            self.config.activeProfile = self.config.profiles.first?.id ?? ""
        }
        if self.liveProfileId == id {
            self.liveProfileId = nil
        }
        self.saveConfig()
        self.saveCache()
    }

    func authStorePath(for profileId: String) -> URL {
        self.authStoreDir.appendingPathComponent("\(profileId).json")
    }

    func authStoreExists(for profileId: String) -> Bool {
        self.fileManager.fileExists(atPath: self.authStorePath(for: profileId).path)
    }

    func authURL(for profileId: String) -> URL {
        self.liveProfileId == profileId ? self.codexAuthPath : self.authStorePath(for: profileId)
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

    func debugSummaryLines() -> [String] {
        var lines: [String] = [
            "config: \(self.configURL.path)",
            "cache: \(self.cacheURL.path)",
            "auth_store: \(self.authStoreDir.path)",
            "codex_home: \(self.codexHome.path)",
            "codex_auth_exists: \(self.liveAuthExists())",
            "config_active_profile: \(self.config.activeProfile)",
            "live_profile_id: \(self.liveProfileId ?? "<none>")",
            "profile_count: \(self.config.profiles.count)",
        ]

        for profile in self.config.profiles {
            let status = self.statuses[profile.id] ?? .notSetUp
            let cacheAge = self.cache.snapshots[profile.id].map { Int(Date().timeIntervalSince($0.fetchedAt)) }
            let cacheText = cacheAge.map { "\($0)s" } ?? "<none>"
            lines.append(
                "profile[\(profile.id)]: label=\"\(profile.label)\" status=\(Self.debugStatusName(status)) " +
                    "auth_saved=\(self.authStoreExists(for: profile.id)) cache_age=\(cacheText)")
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
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let identity = Self.authIdentity(from: json),
              JSONSerialization.isValidJSONObject(identity),
              let normalized = try? JSONSerialization.data(withJSONObject: identity, options: [.sortedKeys]) else {
            return nil
        }

        let digest = SHA256.hash(data: normalized)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    func liveAuthFingerprint() -> String? {
        self.authFingerprint(for: self.codexAuthPath)
    }

    func matchingProfilesForLiveAuth() -> [String] {
        guard let liveFingerprint = self.liveAuthFingerprint() else { return [] }

        return self.config.profiles.compactMap { profile in
            guard self.authFingerprint(for: self.authStorePath(for: profile.id)) == liveFingerprint else {
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

    private static let cacheEncoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    private func saveConfig() {
        do {
            let data = try Self.configEncoder.encode(self.config)
            try data.write(to: self.configURL, options: .atomic)
        } catch {
            AppLogger.error("Failed to save config", metadata: ["error": error.localizedDescription])
        }
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
            return Self.isValidProfileId(id) ? id : nil
        }
        .sorted()
    }

    private func migrateLegacyProfiles() {
        for id in self.legacyProfileIDs() where !self.authStoreExists(for: id) {
            let legacyPath = self.legacyAuthPath(for: id)
            do {
                try self.copyAuthFile(from: legacyPath, to: self.authStorePath(for: id))
                AppLogger.info("Migrated legacy profile auth", metadata: ["profile": id])
            } catch {
                AppLogger.warning("Failed to migrate legacy profile auth",
                                  metadata: ["profile": id, "error": error.localizedDescription])
            }
        }
    }

    private func legacyProfileIDs() -> [String] {
        guard let contents = try? self.fileManager.contentsOfDirectory(
            atPath: self.fileManager.homeDirectoryForCurrentUser.path
        ) else {
            return []
        }

        return contents.compactMap { name in
            guard name.hasPrefix(".codex-"), name != ".codex-switcher" else { return nil }
            let id = String(name.dropFirst(7))
            guard Self.isValidProfileId(id) else { return nil }
            let authPath = self.legacyAuthPath(for: id).path
            return self.fileManager.fileExists(atPath: authPath) ? id : nil
        }
        .sorted()
    }

    private func legacyAuthPath(for profileId: String) -> URL {
        self.fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex-\(profileId)", isDirectory: true)
            .appendingPathComponent("auth.json")
    }

    private func copyAuthFile(from source: URL, to destination: URL) throws {
        let data: Data
        do {
            data = try Data(contentsOf: source)
        } catch {
            throw AuthError.notFound
        }
        try self.replaceFile(at: destination, with: data)
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

    // SYNC: bin/codex-profile find_matching_profiles() must produce identical fingerprints
    private static func authIdentity(from json: [String: Any]) -> [String: Any]? {
        if let apiKey = json["OPENAI_API_KEY"] as? String,
           !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let digest = SHA256.hash(data: Data(apiKey.utf8))
            return [
                "kind": "api-key",
                "keyHash": digest.map { String(format: "%02x", $0) }.joined(),
            ]
        }

        guard let tokens = json["tokens"] as? [String: Any] else { return nil }

        let accountId = dictStringValue(tokens, "account_id", "accountId")
        let idToken = dictStringValue(tokens, "id_token", "idToken")
        let claims = idToken.flatMap(Self.stableClaims(fromIDToken:)) ?? [:]

        guard !claims.isEmpty else {
            return nil
        }

        var identity: [String: Any] = [
            "kind": "oauth",
            "idTokenClaims": claims,
        ]
        if let accountId {
            identity["accountId"] = accountId
        }
        return identity
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

        guard let accessToken = dictStringValue(tokens, "access_token", "accessToken"),
              let refreshToken = dictStringValue(tokens, "refresh_token", "refreshToken"),
              !accessToken.isEmpty else {
            throw AuthError.missingTokens
        }

        let idToken = dictStringValue(tokens, "id_token", "idToken")
        let accountId = dictStringValue(tokens, "account_id", "accountId")
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
        try atomicWriteData(data, to: url)
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

        let profiles = self.store.config.profiles
        let liveId = self.store.liveProfileId ?? ""
        let contexts: [(String, URL, UsageSnapshot?)] = profiles.map { p in
            (p.id, self.store.authURL(for: p.id), self.store.cache.snapshots[p.id])
        }

        self.activeRefreshTask = Task {
            await withTaskGroup(of: Void.self) { group in
                for (id, authURL, cached) in contexts {
                    group.addTask {
                        await self.refreshProfile(id, authURL: authURL, activeProfileId: liveId, cached: cached)
                    }
                }
            }
            await MainActor.run {
                self.store.flushCacheIfDirty()
                self.onRefreshComplete?()
            }
        }
    }

    func refreshActive() {
        guard let id = self.store.liveProfileId else { return }
        let authURL = self.store.authURL(for: id)
        let cached = self.store.cache.snapshots[id]
        let liveId = id

        Task {
            await self.refreshProfile(id, authURL: authURL, activeProfileId: liveId, cached: cached)
            await MainActor.run {
                self.store.flushCacheIfDirty()
                self.onRefreshComplete?()
            }
        }
    }

    private func refreshProfile(
        _ id: String, authURL: URL, activeProfileId: String, cached: UsageSnapshot?
    ) async {
        guard !self.store.isAuthMutationInProgress() else { return }

        func setStatus(_ status: ProfileStatus) async {
            await MainActor.run { self.store.updateStatus(id, status) }
        }

        do {
            let creds = try await AuthRefresher.refreshIfNeeded(
                profileId: id,
                activeProfileId: activeProfileId,
                authFileURL: authURL)

            let response = try await UsageFetcher.fetch(
                accessToken: creds.accessToken,
                accountId: creds.accountId)

            let snapshot = UsageSnapshot(
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

            await setStatus(.available(snapshot))
            AppLogger.info("Usage refresh succeeded", metadata: ["profile": id])
        } catch is CancellationError {
            return
        } catch let error as UsageFetchError where error == .unauthorized {
            AppLogger.warning("Usage refresh unauthorized",
                              metadata: ["profile": id, "error": error.localizedDescription])
            await setStatus(.reloginNeeded(cached))
        } catch let error as AuthError {
            AppLogger.warning("Auth refresh failed",
                              metadata: ["profile": id, "error": error.localizedDescription])
            switch error {
            case .refreshExpired, .refreshReused, .refreshRevoked:
                await setStatus(.reloginNeeded(cached))
            case .notFound:
                await setStatus(.notSetUp)
            default:
                await setStatus(.stale(cached))
            }
        } catch {
            AppLogger.warning("Usage refresh failed",
                              metadata: ["profile": id, "error": error.localizedDescription])
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

            HStack(spacing: 5) {
                if let credits = self.credits {
                    Text(credits)
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(.secondary)
                }

                if let planName = self.planType {
                    Text(planName)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
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

    private var credits: String? {
        guard let snap = self.status.snapshot else { return nil }
        return creditsDisplayName(snap.creditsRemaining)
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

enum CodexBridgeError: LocalizedError {
    case cliNotFound
    case loginAlreadyRunning
    case launchFailed(String)
    case commandFailed(Int32, String)

    var errorDescription: String? {
        switch self {
        case .cliNotFound:
            return "codex-profile helper not found"
        case .loginAlreadyRunning:
            return "Login is already running for this profile"
        case .launchFailed(let message):
            return message
        case .commandFailed(_, let output):
            return output.isEmpty ? "codex-profile command failed" : output
        }
    }
}

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

    static func helperPathForDebug() -> String {
        self.codexProfilePath() ?? "<not found>"
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
        proc.terminationHandler = { p in
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

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

    static func switchToProfile(_ profileId: String) async -> Result<Void, CodexBridgeError> {
        await withCheckedContinuation { continuation in
            guard let path = Self.codexProfilePath() else {
                AppLogger.error("codex-profile helper not found")
                continuation.resume(returning: .failure(.cliNotFound))
                return
            }
            Self.runCommand(path: path, arguments: ["app", profileId]) { result in
                continuation.resume(returning: result)
            }
        }
    }

    static func startLogin(
        profileId: String,
        completion: @escaping (Result<Void, CodexBridgeError>) -> Void
    ) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard !Self.activeLogins.contains(profileId) else {
            AppLogger.warning("Login already running", metadata: ["profile": profileId])
            completion(.failure(.loginAlreadyRunning))
            return
        }
        guard let path = Self.codexProfilePath() else {
            AppLogger.error("codex-profile helper not found")
            completion(.failure(.cliNotFound))
            return
        }

        Self.activeLogins.insert(profileId)
        Self.runCommand(path: path, arguments: ["login", profileId]) { result in
            DispatchQueue.main.async {
                Self.activeLogins.remove(profileId)
                completion(result)
            }
        }
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
    private var activeRefreshTimer: Timer?
    private var menu: NSMenu!
    private var liveAuthWarning: LiveAuthWarning?
    private var lastLiveAuthMtime: Date?

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
            self?.syncActiveProfile()
            self?.usageProvider.refreshActive()
            self?.updateIcon()
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
        self.liveAuthWarning = self.store.liveAuthExists() ? .unmanaged : nil
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
            let store = self.store!
            store.beginAuthMutation()
            CodexBridge.startLogin(profileId: id) { [weak self] result in
                store.endAuthMutation()
                guard let self else { return }
                switch result {
                case .success:
                    AppLogger.info("Login succeeded", metadata: ["profile": id])
                    self.syncActiveProfile(force: true)
                    self.usageProvider.refreshAll(force: true)
                    self.updateIcon()
                case .failure(let error):
                    self.presentBridgeError(title: "Login failed", message: error.localizedDescription)
                }
            }
        }

        switch status {
        case .notSetUp, .reloginNeeded:
            startLogin()
            return
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
        storeRef.beginAuthMutation()
        Task { [weak self] in
            let result = await CodexBridge.switchToProfile(id)
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
        self.usageProvider.refreshAll(force: true)
    }

    @objc private func openSettings() {
        self.menu.cancelTracking()
        SettingsWindow.show(store: self.store)
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
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 520),
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
    @ObservedObject var toast: ToastState
    @State private var labels: [String: String] = [:]
    @State private var profiles: [ProfileConfig] = []
    @State private var pendingDeleteId: String?

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 0) {
                    HStack(spacing: 8) {
                        Text("Name")
                            .frame(maxWidth: .infinity, alignment: .leading)
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
        for profile in self.profiles {
            self.labels[profile.id] = profile.label
        }
    }

    private func saveAll() {
        for (id, label) in self.labels {
            self.store.updateLabel(for: id, label: label)
        }
        self.profiles = self.store.config.profiles
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
        self.profiles = self.store.config.profiles
    }

    private func labelBinding(for id: String, default defaultValue: String) -> Binding<String> {
        Binding(
            get: { self.labels[id] ?? defaultValue },
            set: { self.labels[id] = $0 })
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

                Text("Automatically opens CodexProfileSwitcher when you start your Mac.")
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
