import Cocoa
import CodexProfileCore
import CryptoKit
import SwiftUI

// MARK: - App Info

enum AppInfo {
    static let name = "CodexProfileSwitcher"
    static let version = "0.1.6"
    static let issueURL = URL(string: "https://github.com/4LAU/codex-profile-switcher/issues/new")!
}

// MARK: - Logging (adapted from CodexBar)

enum LogLevel: String {
    case info = "INFO"
    case warning = "WARN"
    case error = "ERROR"
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
    case needsMigration
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
    try AtomicFileWriter.write(data, to: destination)
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
    case cannotRemoveActiveProfile

    var errorDescription: String? {
        switch self {
        case .cannotClearActiveProfile:
            return "Switch away from the active profile before clearing its saved auth."
        case .cannotRemoveActiveProfile:
            return "Switch away from the active profile before deleting it."
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

    private let paths: AppPaths
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
        let paths = AppPaths(environment: environment)
        self.paths = paths
        self.configDir = paths.switcherHome
        self.configURL = paths.configURL
        self.cacheURL = paths.cacheURL
        self.authStoreDir = paths.legacyAuthDirectory
        self.codexHome = paths.liveCodexHome
        self.codexAuthPath = paths.liveAuthURL
        self.codexGlobalStateURL = paths.globalStateURL

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
            self.config = AppConfig(
                profiles: [],
                activeProfile: "1",
                authStorageVersion: nil,
                migrationComplete: true)
            isFirstLaunch = true
        }

        let keychainService = Self.keychainService(environment: environment)
        if let authVault {
            self.authVault = authVault
            self.authStorageDescription = "custom auth vault"
        } else {
            let accessGroup = KeychainAccessGroupResolver.configuredAccessGroup(environment: environment)
            let vault = MigratingAuthVault(
                service: keychainService,
                accessGroup: accessGroup,
                migrationComplete: self.config.migrationComplete == true
            )
            self.authVault = vault
            self.authStorageDescription = Self.authStorageDescription(
                service: keychainService,
                diagnostics: vault.diagnostics()
            )
            AppLogger.info("Auth vault selected",
                           metadata: [
                               "backend": vault.diagnostics().activeBackend.rawValue,
                               "access_group": vault.diagnostics().accessGroup ?? "<none>",
                               "probe": vault.diagnostics().dataProtectionProbe ?? "<none>",
                           ])
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

    private static func authStorageDescription(
        service: String,
        diagnostics: AuthVaultDiagnostics
    ) -> String {
        switch diagnostics.activeBackend {
        case .dataProtectionShared:
            return "macOS data protection Keychain (\(service))"
        case .legacyACL:
            return "macOS legacy ACL Keychain (\(service))"
        case .file:
            return "file auth vault"
        case .custom:
            return "custom auth vault"
        }
    }

    static func userHome(environment: [String: String]) -> URL {
        AppPaths(environment: environment).userHome
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
        let profile = ProfileConfig(
            id: "\(nextId)",
            label: Self.nextDefaultProfileLabel(after: self.config.profiles))
        self.config.profiles.append(profile)
        if self.authVault.diagnostics().activeBackend == .legacyACL {
            self.config.migrationComplete = false
        }
        self.statuses[profile.id] = .notSetUp
        self.saveConfig()
        return profile
    }

    static func nextDefaultProfileLabel(after profiles: [ProfileConfig]) -> String {
        let highestDefaultNumber = profiles
            .compactMap { Self.defaultProfileLabelNumber($0.label) }
            .max() ?? 0
        return "Profile \(highestDefaultNumber + 1)"
    }

    private static func defaultProfileLabelNumber(_ label: String) -> Int? {
        let prefix = "Profile "
        guard label.hasPrefix(prefix) else { return nil }
        let suffix = label.dropFirst(prefix.count)
        guard let number = Int(suffix), number > 0 else { return nil }
        return String(number) == String(suffix) ? number : nil
    }

    func removeProfile(_ id: String) throws {
        if self.liveProfileId == id || self.config.activeProfile == id {
            throw ProfileMutationError.cannotRemoveActiveProfile
        }

        try self.authVault.deleteAuthBlob(profileID: id)

        self.config.profiles.removeAll { $0.id == id }
        self.statuses.removeValue(forKey: id)
        self.refreshDiagnostics.removeValue(forKey: id)
        self.cache.snapshots.removeValue(forKey: id)
        self.saveConfig()
        self.saveCache()
    }

    func authStoreExists(for profileId: String) -> Bool {
        self.authStoreAvailability(for: profileId) == .present
    }

    func authStoreAvailability(for profileId: String) -> AuthBlobAvailability {
        (try? self.authVault.authBlobAvailability(profileID: profileId)) ?? .missing
    }

    func authCanBeActivated(for profileId: String) -> Bool {
        self.authStoreExists(for: profileId)
    }

    func syncSavedAuthToLive(for profileId: String) throws {
        guard let data = try self.authVault.loadAuthBlobForActivation(profileID: profileId) else {
            throw AuthError.notFound
        }
        try self.replaceFile(at: self.codexAuthPath, with: data)
    }

    func prepareProfileSwitch(
        to profileId: String,
        isCodexDesktopRunning: @escaping () -> Bool
    ) throws -> PreparedProfileSwitch {
        try ProfileTransactionService(
            vault: self.authVault,
            paths: self.paths,
            fileManager: self.fileManager,
            isCodexDesktopRunning: isCodexDesktopRunning
        ).prepareSwitch(to: profileId)
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
        try DuplicateAwareAuthSaver.save(
            data,
            profileID: profileId,
            profiles: self.config.profiles,
            vault: self.authVault)
        if self.authVault.diagnostics().activeBackend == .legacyACL {
            self.config.migrationComplete = false
            self.saveConfig()
        }
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
        let diagnostics = self.authVault.diagnostics()
        var lines: [String] = [
            "config: \(self.configURL.path)",
            "cache: \(self.cacheURL.path)",
            "auth_storage: \(self.authStorageDescription)",
            "auth_storage_backend: \(diagnostics.activeBackend.rawValue)",
            "keychain_access_group: \(diagnostics.accessGroup ?? "<none>")",
            "data_protection_probe: \(diagnostics.dataProtectionProbe ?? "<none>")",
            "legacy_auth_store: \(self.authStoreDir.path)",
            "codex_home: \(self.codexHome.path)",
            "codex_auth_exists: \(self.liveAuthExists())",
            "config_active_profile: \(self.config.activeProfile)",
            "auth_storage_version: \(self.config.authStorageVersion.map(String.init) ?? "<none>")",
            "migration_complete: \(self.config.migrationComplete == true)",
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
            let availability = self.authStoreAvailability(for: profile.id)
            lines.append(
                "profile[\(profile.id)]: label=\"\(profile.label)\" status=\(Self.debugStatusName(status)) " +
                    "auth_saved=\(availability == .present) auth_availability=\(Self.debugAvailabilityName(availability)) " +
                    "cache_age=\(cacheText) " +
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
            switch self.authStoreAvailability(for: profile.id) {
            case .present:
                if let cached = self.cache.snapshots[profile.id] {
                    self.statuses[profile.id] = .stale(cached)
                } else {
                    self.statuses[profile.id] = .loading
                }
            case .needsMigration:
                self.statuses[profile.id] = .needsMigration
            case .missing:
                self.statuses[profile.id] = self.missingAuthStatus(cached: self.cache.snapshots[profile.id])
            }
        }
    }

    private func missingAuthStatus(cached: UsageSnapshot?) -> ProfileStatus {
        cached.map { .reloginNeeded($0) } ?? .notSetUp
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
        ProfileValidator.isValid(id)
    }

    private static func debugStatusName(_ status: ProfileStatus) -> String {
        switch status {
        case .available: return "available"
        case .loading: return "loading"
        case .stale(let snapshot): return snapshot == nil ? "stale-no-cache" : "stale"
        case .reloginNeeded: return "relogin-needed"
        case .needsMigration: return "needs-migration"
        case .notSetUp: return "not-set-up"
        }
    }

    private static func debugAvailabilityName(_ availability: AuthBlobAvailability) -> String {
        switch availability {
        case .present: return "present"
        case .missing: return "missing"
        case .needsMigration: return "needs-migration"
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
           self.store.statuses.values.allSatisfy({
               switch $0 {
               case .notSetUp, .needsMigration: return true
               default: return false
               }
           }) {
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
                    self.store.updateStatus(id, cached.map { .reloginNeeded($0) } ?? .notSetUp)
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
            if id != activeProfileId, self.store.authStoreAvailability(for: id) == .needsMigration {
                diagnostics.lastDecision = "needs-migration"
                diagnostics.lastError = nil
                let updatedDiagnostics = diagnostics
                await MainActor.run {
                    self.store.updateRefreshDiagnostics(id, updatedDiagnostics)
                    self.store.updateStatus(id, .needsMigration)
                }
                return
            }
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



enum CodexBridgeError: LocalizedError {
    case cliNotFound
    case loginAlreadyRunning
    case loginCancelled
    case loginTimedOut
    case launchFailed(String)
    case commandFailed(Int32, String)
    case switchRolledBack(String)
    case switchCommittedButLaunchFailed(String)
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
            return Self.helperFailureMessage(from: output)
        case .switchRolledBack(let message):
            return message
        case .switchCommittedButLaunchFailed(let message):
            return message
        case .stateUpdateFailed(let message):
            return message
        }
    }

    private static func helperFailureMessage(from output: String) -> String {
        guard !output.isEmpty else { return "codex-profile command failed" }

        let boilerplatePrefixes = [
            "Starting local login server",
            "If your browser did not open",
            "https://auth.openai.com/oauth/authorize",
            "On a remote or headless machine?",
            "Starting isolated login for profile ",
        ]
        let lines = output
            .split(whereSeparator: \.isNewline)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        if let meaningful = lines.reversed().first(where: { line in
            line != "Successfully logged in" &&
                !boilerplatePrefixes.contains(where: line.hasPrefix)
        }) {
            if meaningful.hasPrefix("Error: ") {
                return String(meaningful.dropFirst("Error: ".count))
            }
            return meaningful
        }

        return LogRedactor.excerpt(output)
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

    static func switchToProfile(
        _ profileId: String,
        workspacePath: String?,
        prepareTransaction: @escaping () throws -> PreparedProfileSwitch
    ) async -> Result<Void, CodexBridgeError> {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let transaction = try prepareTransaction()
                    if transaction.alreadyActive {
                        AppLogger.info("Profile switch skipped; profile is already active",
                                       metadata: ["profile": profileId])
                        continuation.resume(returning: .success(()))
                        return
                    }

                    try Self.quitCodexApp()
                    _ = try transaction.commit()
                    do {
                        try Self.launchCodexApp(workspacePath: workspacePath)
                    } catch let error as CodexBridgeError {
                        throw Self.committedLaunchFailure(error)
                    } catch {
                        throw Self.committedLaunchFailure(error)
                    }
                    AppLogger.info("Direct profile switch succeeded", metadata: ["profile": profileId])
                    continuation.resume(returning: .success(()))
                } catch let error as ProfileSwitchCommitError {
                    continuation.resume(returning: .failure(Self.bridgeError(from: error)))
                } catch let error as CodexBridgeError {
                    continuation.resume(returning: .failure(error))
                } catch {
                    AppLogger.error("Direct profile switch failed",
                                    metadata: ["profile": profileId, "error": error.localizedDescription])
                    continuation.resume(returning: .failure(.stateUpdateFailed(error.localizedDescription)))
                }
            }
        }
    }

    private static func bridgeError(from error: ProfileSwitchCommitError) -> CodexBridgeError {
        switch error.outcome {
        case .rolledBackAfterWriteFailure:
            return .switchRolledBack("Switch failed. Restored previous profile.")
        case .committedButLaunchFailed:
            return .switchCommittedButLaunchFailed(
                "Profile switched. Codex Desktop may need a manual restart.")
        case .committed:
            return .stateUpdateFailed(error.localizedDescription)
        }
    }

    private static func committedLaunchFailure(_ error: Error) -> CodexBridgeError {
        Self.bridgeError(from: ProfileSwitchCommitError(outcome: .committedButLaunchFailed(error)))
    }

    static func isCodexDesktopRunning() -> Bool {
        Self.runAndWait("/usr/bin/pgrep", arguments: ["-x", "Codex"], quiet: true) == 0
            || Self.runAndWait(
                "/usr/bin/pgrep",
                arguments: ["-f", "\(Self.codexBundledCLI()) app-server"],
                quiet: true
            ) == 0
    }

    private static func quitCodexApp() throws {
        guard Self.isCodexDesktopRunning() else { return }
        AppLogger.info("Quitting Codex before profile switch")
        _ = Self.runAndWait("/usr/bin/osascript", arguments: ["-e", "tell application \"Codex\" to quit"])

        let attempts = Int(Self.environment("CODEX_PROFILE_QUIT_ATTEMPTS") ?? "") ?? 30
        let sleepSeconds = Double(Self.environment("CODEX_PROFILE_QUIT_SLEEP") ?? "") ?? 0.5
        for _ in 0..<attempts {
            if !Self.isCodexDesktopRunning() { return }
            Thread.sleep(forTimeInterval: sleepSeconds)
        }
        throw CodexBridgeError.stateUpdateFailed(
            "Codex or its app-server is still running. Quit Codex with Cmd+Q, then retry.")
    }

    private static func launchCodexApp(workspacePath: String?) throws {
        let binary = try Self.codexAppBinary()
        let logDir = AppPaths().liveCodexHome.appendingPathComponent("logs", isDirectory: true)
        try FileManager.default.createDirectory(
            at: logDir,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let logFile = logDir.appendingPathComponent("desktop.log")
        FileManager.default.createFile(
            atPath: logFile.path,
            contents: nil,
            attributes: [.posixPermissions: 0o600])

        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = workspacePath.map { [$0] } ?? []
        let handle = try FileHandle(forWritingTo: logFile)
        process.standardOutput = handle
        process.standardError = handle
        do {
            try process.run()
            try? handle.close()
        } catch {
            try? handle.close()
            throw CodexBridgeError.launchFailed(error.localizedDescription)
        }
    }

    private static func codexAppBinary() throws -> String {
        let path = Self.environment("CODEX_APP_BIN") ?? "\(Self.codexAppPath())/Contents/MacOS/Codex"
        guard FileManager.default.isExecutableFile(atPath: path) else {
            throw CodexBridgeError.launchFailed("Codex Desktop binary not found at \(path)")
        }
        return path
    }

    private static func codexAppPath() -> String {
        Self.environment("CODEX_APP") ?? "/Applications/Codex.app"
    }

    private static func codexBundledCLI() -> String {
        "\(Self.codexAppPath())/Contents/Resources/codex"
    }

    private static func environment(_ key: String) -> String? {
        let value = ProcessInfo.processInfo.environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines)
        return value?.isEmpty == false ? value : nil
    }

    @discardableResult
    private static func runAndWait(_ path: String, arguments: [String], quiet: Bool = false) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        if quiet {
            process.standardOutput = Pipe()
            process.standardError = Pipe()
        }
        do {
            try process.run()
        } catch {
            AppLogger.error("Failed to launch process",
                            metadata: [
                                "path": path,
                                "arguments": arguments.joined(separator: " "),
                                "error": error.localizedDescription,
                            ])
            return 127
        }
        process.waitUntilExit()
        return process.terminationStatus
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

// MARK: - App Support
