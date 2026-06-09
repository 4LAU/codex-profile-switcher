import Cocoa
import CodexProfileCore
import CryptoKit
import SwiftUI

// MARK: - ProfileStore

final class ProfileStore {
    private static let keychainAuthStorageVersion = 2
    private static let keychainAccessRepairVersion = 4

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
                authStorageVersion: nil)
            isFirstLaunch = true
        }

        let keychainService = Self.keychainService(environment: environment)
        if let authVault {
            self.authVault = authVault
            self.authStorageDescription = "custom auth vault"
        } else {
            let vault = LegacyKeychainAuthVault(service: keychainService)
            self.authVault = vault
            self.authStorageDescription = "macOS Keychain (\(keychainService))"
            AppLogger.info("Auth vault selected",
                           metadata: ["backend": "legacyACL"])
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
        return LegacyKeychainAuthVault.defaultService
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
        self.cache.exhaustionOverrides.removeValue(forKey: id)
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
        guard let data = try self.authVault.loadAuthBlob(profileID: profileId) else {
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
    }

    func saveRefreshedAuthToVault(_ data: Data, for profileId: String, originalData: Data) throws {
        let originalFingerprint = AuthBlob.identityFingerprint(from: originalData)
        let refreshedFingerprint = AuthBlob.identityFingerprint(from: data)
        guard let orig = originalFingerprint, let refreshed = refreshedFingerprint else {
            try self.saveAuthDataToVault(data, for: profileId)
            return
        }
        guard orig == refreshed else {
            try self.saveAuthDataToVault(data, for: profileId)
            return
        }
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
        let diagnostics = self.authVault.diagnostics()
        var lines: [String] = [
            "config: \(self.configURL.path)",
            "cache: \(self.cacheURL.path)",
            "auth_storage: \(self.authStorageDescription)",
            "auth_storage_backend: \(diagnostics.activeBackend.rawValue)",
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
            let availability = self.authStoreAvailability(for: profile.id)
            lines.append(
                "profile[\(profile.id)]: label=\"\(profile.label)\" status=\(Self.debugStatusName(status)) " +
                    "auth_saved=\(availability == .present) " +
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
        self.cache.exhaustionOverrides.removeValue(forKey: id)
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
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            if let diskData = try? Data(contentsOf: self.cacheURL),
               let diskCache = try? decoder.decode(UsageCache.self, from: diskData),
               !diskCache.exhaustionOverrides.isEmpty {
                for (id, override) in diskCache.exhaustionOverrides where self.cache.exhaustionOverrides[id] == nil {
                    self.cache.exhaustionOverrides[id] = override
                }
            }
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
            let result = try self.authVault.repairStoredAuthAccess()
            if result.isComplete {
                self.config.authStorageVersion = Self.keychainAccessRepairVersion
                try self.saveConfigThrowing()
            }
            if result.repaired > 0 {
                AppLogger.info("Repaired saved auth Keychain access",
                               metadata: [
                                   "complete": "\(result.isComplete)",
                                   "repaired": "\(result.repaired)",
                                   "total": "\(result.total)",
                               ])
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
