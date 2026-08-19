import Foundation
import CodexProfileCore
import Combine
import CryptoKit

// MARK: - ProfileStore

@MainActor
final class ProfileStore: ObservableObject {
    private static let keychainAuthStorageVersion = 2

    typealias KeychainMigrationCoordinatorFactory = (
        AuthVault,
        [ProfileConfig],
        [String: AuthMigrationState]?,
        [String: String]?,
        @escaping (String, AuthMigrationState, String?) throws -> Void
    ) throws -> KeychainMigrationCoordinator

    private let paths: AppPaths
    private let configDir: URL
    private let configURL: URL
    private let cacheURL: URL
    private let authStoreDir: URL
    private let authVault: AuthVault
    private let authStorageDescription: String
    private let keychainMigrationCoordinatorFactory: KeychainMigrationCoordinatorFactory?
    private let codexHome: URL
    private let codexAuthPath: URL
    private let codexGlobalStateURL: URL
    private let fileManager = FileManager.default
    private var authMutationInProgress = false
    private var cacheDirty = false
    private var keychainMigrationCoordinator: KeychainMigrationCoordinator?
    private var keychainMigrationPreview: KeychainMigrationPreview?

    private(set) var config: AppConfig
    private(set) var cache: UsageCache
    @Published private(set) var statuses: [String: ProfileStatus] = [:]
    private(set) var refreshDiagnostics: [String: ProfileRefreshDiagnostics] = [:]
    private(set) var liveProfileId: String?
    private(set) var shouldShowKeychainMigration = false

    init(
        authVault: AuthVault? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        keychainMigrationCoordinatorFactory: KeychainMigrationCoordinatorFactory? = nil
    ) {
        let paths = AppPaths(environment: environment)
        self.paths = paths
        self.configDir = paths.switcherHome
        self.configURL = paths.configURL
        self.cacheURL = paths.cacheURL
        self.authStoreDir = paths.legacyAuthDirectory
        self.codexHome = paths.liveCodexHome
        self.codexAuthPath = paths.liveAuthURL
        self.codexGlobalStateURL = paths.globalStateURL
        self.keychainMigrationCoordinatorFactory = keychainMigrationCoordinatorFactory

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

        if let authVault {
            self.authVault = authVault
            self.authStorageDescription = "custom auth vault"
        } else {
            let hasDataProtectionKeychainAccess = ProcessSigningIdentity.hasDataProtectionKeychainAccess
            self.authVault = PrimaryAuthVaultSelector.makeVault(
                hasDataProtectionKeychainAccess: hasDataProtectionKeychainAccess,
                fileVaultRoot: paths.devAuthStoreURL,
                authLockURL: paths.authLockURL)
            if hasDataProtectionKeychainAccess {
                self.authStorageDescription = "data-protection Keychain auth vault"
                AppLogger.info("Auth vault selected",
                               metadata: ["backend": "dataProtectionKeychain"])
            } else {
                self.authStorageDescription = "file auth vault (no data-protection Keychain entitlement)"
                AppLogger.info("Auth vault selected",
                               metadata: ["backend": "file", "reason": "missing data-protection Keychain entitlement"])
            }
        }

        let cacheDecoder = JSONDecoder()
        cacheDecoder.dateDecodingStrategy = .iso8601
        let cacheData = try? Data(contentsOf: self.cacheURL)
        if let cacheData {
            do {
                self.cache = try cacheDecoder.decode(UsageCache.self, from: cacheData)
            } catch {
                // Distinguish a genuine decode failure (corrupt/incompatible file)
                // from a legitimately empty cache: only warn when data existed but
                // could not be decoded, and include the underlying error.
                AppLogger.warning("Cache exists but could not be decoded",
                                  metadata: ["path": self.cacheURL.path,
                                             "error": error.localizedDescription])
                self.cache = UsageCache(snapshots: [:])
            }
        } else {
            self.cache = UsageCache(snapshots: [:])
        }

        if isFirstLaunch, self.legacyAuthStoreFiles().isEmpty {
            // Only the data-protection Keychain backend owns the disk-auth
            // migration version. A file vault must leave it untouched so a later
            // entitlement-bearing build can migrate the old disk store.
            if self.ownsLegacyDiskMigrationBookkeeping {
                self.config.authStorageVersion = Self.keychainAuthStorageVersion
            }
            self.config.profiles = [ProfileConfig(id: "1", label: "Profile 1")]
            self.statuses["1"] = .notSetUp
            self.saveConfig()
        } else {
            self.migrateLegacyProfiles()
            self.discoverProfiles()
            self.refreshStatusesFromStoredAuth()
        }
        self.liveProfileId = self.config.activeProfile.isEmpty ? nil : self.config.activeProfile
        self.refreshKeychainMigrationVisibility()
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

        try self.removeAuthMigrationState(for: id)
        try self.authVault.deleteAuthBlob(profileID: id)

        self.config.profiles.removeAll { $0.id == id }
        self.statuses.removeValue(forKey: id)
        self.refreshDiagnostics.removeValue(forKey: id)
        self.cache.snapshots.removeValue(forKey: id)
        self.cache.exhaustionOverrides.removeValue(forKey: id)
        self.cache.renewalStates.removeValue(forKey: id)
        self.saveConfig()
        self.saveCache(excludingOverridesFor: id, renewalStateChange: .remove(id))
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

    /// Plain, `Sendable` values needed to perform the potentially-blocking auth
    /// reads (file or Keychain) off the main actor. The vault conformers are
    /// immutable structs, and the URL is a value type, so this carries no
    /// reference to `ProfileStore`'s mutable state.
    struct UsageAuthSource {
        let vault: AuthVault
        let liveAuthURL: URL
    }

    func usageAuthSource() -> UsageAuthSource {
        UsageAuthSource(vault: self.authVault, liveAuthURL: self.codexAuthPath)
    }

    func saveAuthDataToVault(_ data: Data, for profileId: String) throws {
        try DuplicateAwareAuthSaver.save(
            data,
            profileID: profileId,
            profiles: self.config.profiles,
            vault: self.authVault)
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
            let lastAttemptAt = diagnostics?.lastAttemptAt.map { ISO8601DateFormatter().string(from: $0) } ?? "<none>"
            let decision = diagnostics?.lastDecision ?? "<none>"
            let error = diagnostics?.lastError.map { LogRedactor.excerpt($0, maxLength: 120) } ?? "<none>"
            let availability = self.authStoreAvailability(for: profile.id)
            lines.append(
                "profile[\(profile.id)]: label=\"\(profile.label)\" status=\(Self.debugStatusName(status)) " +
                    "auth_saved=\(availability == .present) " +
                    "cache_age=\(cacheText) " +
                    "last_attempt_at=\(lastAttemptAt) last_decision=\(decision) last_error=\(error)")
        }

        return lines
    }

    func updateLabel(for id: String, label: String) {
        if let idx = self.config.profiles.firstIndex(where: { $0.id == id }) {
            self.config.profiles[idx].label = label
            self.saveConfig()
        }
    }

    /// A persisted rejection only overrides a status that itself implies a
    /// credential is present (available/stale/reloginNeeded/loading). `.notSetUp`
    /// means there is no credential to relogin to, so it must pass through
    /// unchanged — otherwise a profile that was rejected and then had its saved
    /// auth cleared would show a permanent, un-actionable "re-login needed"
    /// banner instead of "not set up".
    private static func statusImpliesCredentialPresent(_ status: ProfileStatus) -> Bool {
        if case .notSetUp = status { return false }
        return true
    }

    func updateStatus(_ id: String, _ status: ProfileStatus) {
        if self.cache.renewalStates[id]?.action == "rejected", Self.statusImpliesCredentialPresent(status) {
            self.statuses[id] = .reloginNeeded(status.snapshot)
        } else {
            self.statuses[id] = status
        }
        if case let .available(snapshot) = status {
            self.cache.snapshots[id] = snapshot
            self.cacheDirty = true
        }
    }

    func recordRenewalState(_ state: RenewalState, for id: String) {
        switch state.action {
        case "renewed", "recovered":
            self.clearRenewalState(for: id)
        case "rejected":
            self.cache.renewalStates[id] = state
            self.saveCache(renewalStateChange: .set(id, state))
        default:
            break
        }
    }

    func clearRenewalState(for id: String) {
        self.cache.renewalStates.removeValue(forKey: id)
        self.saveCache(renewalStateChange: .remove(id))
    }

    /// Clears a persisted rejection once the credential it condemned has been
    /// replaced (e.g. by a terminal `codex-profile login`). A fresh credential
    /// is not due for renewal, so `renew` reports nothing for this profile and
    /// nothing else would ever clear the old rejection — it would otherwise be
    /// sticky forever. Only clears when both fingerprints are known and they
    /// differ; an unknown current fingerprint (auth unreadable this cycle)
    /// leaves the rejection in place rather than guessing.
    func clearRenewalStateIfCredentialMoved(for id: String, currentCredentialFingerprint: String?) {
        guard let renewal = self.cache.renewalStates[id], renewal.action == "rejected" else { return }
        guard let condemned = renewal.credentialFingerprint,
              let current = currentCredentialFingerprint,
              current != condemned else { return }
        self.clearRenewalState(for: id)
    }

    /// Re-reads renewal states from the on-disk cache. `self.cache` is
    /// otherwise loaded once at init and never mutated by `saveCache` (see its
    /// doc comment); the nightly renewal LaunchAgent writes rejections to the
    /// cache file from a separate process, so without this the app would never
    /// observe them. Call at the start of a refresh cycle.
    func reloadRenewalStatesFromDisk() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: self.cacheURL),
              let diskCache = try? decoder.decode(UsageCache.self, from: data) else { return }
        self.cache.renewalStates = diskCache.renewalStates
        self.cache.lastRenewalRun = diskCache.lastRenewalRun
    }

    /// Re-reads only the last-renewal-run record from disk. Settings needs this
    /// on its own: the nightly LaunchAgent writes the record from a separate
    /// process, and `self.cache` would otherwise only ever show a run this app
    /// launched itself.
    func reloadLastRenewalRunFromDisk() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: self.cacheURL),
              let diskCache = try? decoder.decode(UsageCache.self, from: data) else { return }
        self.cache.lastRenewalRun = diskCache.lastRenewalRun
    }

    func recordRenewalRun(_ run: LastRenewalRun) {
        self.cache.lastRenewalRun = run
        self.saveCache(lastRenewalRunChange: run)
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

        try self.removeAuthMigrationState(for: id)
        try self.authVault.deleteAuthBlob(profileID: id)
        self.cache.snapshots.removeValue(forKey: id)
        self.cache.exhaustionOverrides.removeValue(forKey: id)
        self.cache.renewalStates.removeValue(forKey: id)
        self.refreshDiagnostics.removeValue(forKey: id)
        self.statuses[id] = .notSetUp
        self.saveCache(excludingOverridesFor: id, renewalStateChange: .remove(id))
    }

    func reviewLegacyKeychainMigration() throws -> KeychainMigrationPreview {
        guard self.keychainMigrationCoordinator == nil else {
            throw KeychainMigrationError.reviewAlreadyInProgress
        }
        guard self.authVault.diagnostics().activeBackend == .dataProtectionKeychain else {
            throw KeychainMigrationError.destinationUnavailable
        }

        do {
            let checkpoint = self.keychainMigrationCheckpoint()
            let coordinator: KeychainMigrationCoordinator
            if let factory = self.keychainMigrationCoordinatorFactory {
                coordinator = try factory(
                    self.authVault,
                    self.config.profiles,
                    self.config.authMigrationStates,
                    self.config.authMigrationPendingFingerprints,
                    checkpoint)
            } else {
                guard let destination = self.authVault as? DataProtectionKeychainAuthVault else {
                    throw KeychainMigrationError.destinationUnavailable
                }
                let legacyVault = LegacyKeychainAuthVault(interactionAllowed: true)
                coordinator = KeychainMigrationCoordinator(
                    legacyVault: legacyVault,
                    destination: destination,
                    profiles: self.config.profiles,
                    migrationStates: self.config.authMigrationStates,
                    pendingFingerprints: self.config.authMigrationPendingFingerprints,
                    checkpoint: checkpoint)
            }
            let preview = try coordinator.review()
            self.keychainMigrationCoordinator = coordinator
            self.keychainMigrationPreview = preview
            return preview
        } catch {
            self.discardKeychainMigrationReview()
            throw error
        }
    }

    func confirmLegacyKeychainMigration(
        _ preview: KeychainMigrationPreview,
        approvedCount: Int
    ) throws {
        let coordinator = try self.coordinator(for: preview)
        do {
            try coordinator.confirm(preview, approvedCount: approvedCount)
            self.discardKeychainMigrationReview()
            self.refreshAfterKeychainMigration()
        } catch {
            self.discardKeychainMigrationReview()
            throw error
        }
    }

    func completePendingKeychainMigration(
        _ preview: KeychainMigrationPreview,
        approvedCount: Int
    ) throws {
        let coordinator = try self.coordinator(for: preview)
        do {
            try coordinator.completePending(preview, approvedCount: approvedCount)
            self.discardKeychainMigrationReview()
            self.refreshAfterKeychainMigration()
        } catch {
            self.discardKeychainMigrationReview()
            throw error
        }
    }

    func cancelLegacyKeychainMigrationReview(_ preview: KeychainMigrationPreview) {
        guard self.keychainMigrationPreview == preview else { return }
        self.keychainMigrationCoordinator?.cancel(preview)
        self.discardKeychainMigrationReview()
    }

    func flushCacheIfDirty() {
        guard self.cacheDirty else { return }
        self.cacheDirty = false
        self.saveCache()
    }

    func beginAuthMutation() {
        self.authMutationInProgress = true
    }

    func endAuthMutation() {
        self.authMutationInProgress = false
    }

    func isAuthMutationInProgress() -> Bool {
        self.authMutationInProgress
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

    private func keychainMigrationCheckpoint() -> (String, AuthMigrationState, String?) throws -> Void {
        { [weak self] profileID, state, pendingFingerprint in
            guard let self else { throw KeychainMigrationError.checkpointFailed }
            let previousStates = self.config.authMigrationStates
            let previousFingerprints = self.config.authMigrationPendingFingerprints
            var updatedStates = previousStates ?? [:]
            var updatedFingerprints = previousFingerprints ?? [:]
            updatedStates[profileID] = state
            switch state {
            case .copiedCleanupPending:
                guard let pendingFingerprint else {
                    throw KeychainMigrationError.checkpointFailed
                }
                updatedFingerprints[profileID] = pendingFingerprint
            case .complete:
                updatedFingerprints.removeValue(forKey: profileID)
            }
            self.config.authMigrationStates = updatedStates
            self.config.authMigrationPendingFingerprints = updatedFingerprints.isEmpty
                ? nil
                : updatedFingerprints
            do {
                try self.saveConfigThrowing()
            } catch {
                self.config.authMigrationStates = previousStates
                self.config.authMigrationPendingFingerprints = previousFingerprints
                throw error
            }
        }
    }

    /// Persist this before deleting destination auth. A pending cleanup marker
    /// without a destination copy cannot be completed safely.
    private func removeAuthMigrationState(for profileID: String) throws {
        var states = self.config.authMigrationStates ?? [:]
        var fingerprints = self.config.authMigrationPendingFingerprints ?? [:]
        guard states.removeValue(forKey: profileID) != nil
                || fingerprints.removeValue(forKey: profileID) != nil else {
            return
        }

        let previousStates = self.config.authMigrationStates
        let previousFingerprints = self.config.authMigrationPendingFingerprints
        self.config.authMigrationStates = states.isEmpty ? nil : states
        self.config.authMigrationPendingFingerprints = fingerprints.isEmpty ? nil : fingerprints
        do {
            try self.saveConfigThrowing()
        } catch {
            self.config.authMigrationStates = previousStates
            self.config.authMigrationPendingFingerprints = previousFingerprints
            throw error
        }
    }

    private func coordinator(for preview: KeychainMigrationPreview) throws -> KeychainMigrationCoordinator {
        guard self.keychainMigrationPreview == preview,
              let coordinator = self.keychainMigrationCoordinator else {
            self.discardKeychainMigrationReview()
            throw KeychainMigrationError.staleOrConsumedPreview
        }
        return coordinator
    }

    private func discardKeychainMigrationReview() {
        self.keychainMigrationCoordinator = nil
        self.keychainMigrationPreview = nil
    }

    private func refreshAfterKeychainMigration() {
        self.discoverProfiles()
        self.refreshStatusesFromStoredAuth()
        self.refreshKeychainMigrationVisibility()
    }

    private func refreshKeychainMigrationVisibility() {
        guard self.authVault.diagnostics().activeBackend == .dataProtectionKeychain else {
            self.shouldShowKeychainMigration = false
            return
        }

        let hasPendingCleanup = self.config.authMigrationStates?.values.contains(.copiedCleanupPending) == true
        do {
            let legacyIDs = try LegacyKeychainAuthVault(interactionAllowed: false).listProfileIDs()
            self.shouldShowKeychainMigration = hasPendingCleanup || !legacyIDs.isEmpty
        } catch {
            self.shouldShowKeychainMigration = hasPendingCleanup || self.config.authMigrationStates == nil
        }
    }

    private func saveCache() {
        self.saveCache(excludingOverridesFor: nil)
    }

    private enum RenewalStateChange {
        case set(String, RenewalState)
        case remove(String)
    }

    /// Persists the in-memory cache to disk.
    ///
    /// Concurrent-merge semantics: a CLI process (`mark-exhausted`) may write
    /// exhaustion overrides to the same file between our reads, so we merge any
    /// disk-only overrides into the write to avoid clobbering them. The merge is
    /// purely additive and writes into a LOCAL copy — `self.cache` is never
    /// mutated here, so a removal made in memory is not silently re-injected.
    ///
    /// Deletion exception: when a profile's override is removed in memory
    /// (`clearSavedAuth`/`removeProfile`), pass its id as `excludingOverridesFor`
    /// so the disk override for that id is NOT merged back. This makes the
    /// removal stick on disk while still preserving concurrent overrides for
    /// every OTHER profile.
    private func saveCache(
        excludingOverridesFor excludedID: String? = nil,
        renewalStateChange: RenewalStateChange? = nil,
        lastRenewalRunChange: LastRenewalRun? = nil
    ) {
        do {
            // Hold the cross-process cache lock across the disk re-read
            // (mergingDiskOverrides) and the atomic write so this whole-cache
            // replace cannot drop a lease (or override) a concurrent CLI process
            // committed between our read and our write. Without the lock, the
            // disk-verbatim leases merge only protects leases that exist at the
            // instant of the merge read — a lease landing after that read, but
            // before this write, would be clobbered.
            try CacheLock.withLock(at: self.paths.cacheLockURL) {
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                var toWrite = self.cache.mergingDiskOverrides(
                    fromCacheAt: self.cacheURL,
                    excluding: excludedID,
                    decoder: decoder)
                if let renewalStateChange {
                    switch renewalStateChange {
                    case .set(let id, let state):
                        toWrite.renewalStates[id] = state
                    case .remove(let id):
                        toWrite.renewalStates.removeValue(forKey: id)
                    }
                }
                if let lastRenewalRunChange {
                    toWrite.lastRenewalRun = lastRenewalRunChange
                }
                let data = try Self.cacheEncoder.encode(toWrite)
                try data.write(to: self.cacheURL, options: .atomic)
            }
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
                    self.updateStatus(profile.id, .stale(cached))
                } else {
                    self.updateStatus(profile.id, .loading)
                }
            case .missing:
                self.updateStatus(
                    profile.id,
                    self.missingAuthStatus(cached: self.cache.snapshots[profile.id]))
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

    /// File vaults must leave the disk-auth migration incomplete so a later
    /// entitlement-bearing build can move those credentials.
    private var ownsLegacyDiskMigrationBookkeeping: Bool {
        self.authVault.diagnostics().activeBackend != .file
    }

    private func migrateLegacyProfiles() {
        guard self.ownsLegacyDiskMigrationBookkeeping else { return }
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
            AppLogger.info("Migrated legacy disk auth store to primary auth vault",
                           metadata: ["profile_count": "\(validatedFiles.count)"])
        } catch {
            self.rollbackLegacyDiskAuthMigration(touchedProfileIDs: touchedProfileIDs, priorBlobs: priorBlobs)
            AppLogger.error("Failed to migrate legacy disk auth store to primary auth vault",
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

    private func rollbackLegacyDiskAuthMigration(touchedProfileIDs: [String], priorBlobs: [String: Data?]) {
        for id in Set(touchedProfileIDs) {
            do {
                if let prior = priorBlobs[id] ?? nil {
                    try self.authVault.saveAuthBlob(prior, profileID: id)
                } else {
                    try self.authVault.deleteAuthBlob(profileID: id)
                }
            } catch {
                AppLogger.error("Failed to roll back migrated auth vault data",
                                metadata: ["profile": id, "error": error.localizedDescription])
            }
        }
    }

    private func cleanupLegacyAuthStoreIfMigrated() {
        guard self.ownsLegacyDiskMigrationBookkeeping else { return }
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
        try AtomicFileWriter.write(data, to: destination)
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
