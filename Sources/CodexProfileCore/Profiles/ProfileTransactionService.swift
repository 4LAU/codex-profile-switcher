import Foundation

public struct PreparedProfileSwitch {
    public let profileID: String
    public let outgoingProfileID: String?
    public let alreadyActive: Bool

    private let targetData: Data
    private let outgoingLiveData: Data?
    private let vault: AuthVault
    private let paths: AppPaths
    private let fileManager: FileManager

    init(
        profileID: String,
        outgoingProfileID: String?,
        alreadyActive: Bool,
        targetData: Data,
        outgoingLiveData: Data?,
        vault: AuthVault,
        paths: AppPaths,
        fileManager: FileManager
    ) {
        self.profileID = profileID
        self.outgoingProfileID = outgoingProfileID
        self.alreadyActive = alreadyActive
        self.targetData = targetData
        self.outgoingLiveData = outgoingLiveData
        self.vault = vault
        self.paths = paths
        self.fileManager = fileManager
    }

    @discardableResult
    public func commit() throws -> ProfileSwitchCommitOutcome {
        let snapshots = try ProfileSwitchFileSnapshots.capture(paths: self.paths, fileManager: self.fileManager)
        if let outgoingProfileID, let outgoingLiveData {
            try self.vault.saveAuthBlob(outgoingLiveData, profileID: outgoingProfileID)
        }
        do {
            try AtomicFileWriter.write(self.targetData, to: self.paths.liveAuthURL, fileManager: self.fileManager)
        } catch {
            throw self.rollbackWriteFailure(error, path: self.paths.liveAuthURL, snapshots: snapshots)
        }
        do {
            try ProfileConfigStore(paths: self.paths, fileManager: self.fileManager).saveActiveProfile(self.profileID)
        } catch {
            throw self.rollbackWriteFailure(error, path: self.paths.configURL, snapshots: snapshots)
        }
        return .committed
    }

    private func rollbackWriteFailure(
        _ error: Error,
        path: URL,
        snapshots: ProfileSwitchFileSnapshots
    ) -> ProfileSwitchCommitError {
        snapshots.restore(fileManager: self.fileManager)
        return ProfileSwitchCommitError(
            outcome: .rolledBackAfterWriteFailure(
                ProfileSwitchWriteFailure(path: path.path, underlyingError: error)))
    }
}

public enum ProfileSwitchCommitOutcome {
    case committed
    case rolledBackAfterWriteFailure(ProfileSwitchWriteFailure)
    case committedButLaunchFailed(Error)
}

public struct ProfileSwitchWriteFailure: Error {
    public let path: String
    public let underlyingError: Error

    public init(path: String, underlyingError: Error) {
        self.path = path
        self.underlyingError = underlyingError
    }
}

public struct ProfileSwitchCommitError: LocalizedError {
    public let outcome: ProfileSwitchCommitOutcome

    public init(outcome: ProfileSwitchCommitOutcome) {
        self.outcome = outcome
    }

    public var errorDescription: String? {
        switch self.outcome {
        case .committed:
            return nil
        case .rolledBackAfterWriteFailure(let failure):
            return "Profile switch write failed at \(failure.path); restored previous auth and config state: \(failure.underlyingError.localizedDescription)"
        case .committedButLaunchFailed(let error):
            return "Profile switch committed, but Codex Desktop could not be relaunched: \(error.localizedDescription)"
        }
    }
}

private struct ProfileSwitchFileSnapshots {
    let liveAuth: ProfileSwitchFileSnapshot
    let config: ProfileSwitchFileSnapshot

    static func capture(paths: AppPaths, fileManager: FileManager) throws -> Self {
        Self(
            liveAuth: try ProfileSwitchFileSnapshot.capture(url: paths.liveAuthURL, fileManager: fileManager),
            config: try ProfileSwitchFileSnapshot.capture(url: paths.configURL, fileManager: fileManager))
    }

    func restore(fileManager: FileManager) {
        self.liveAuth.restore(fileManager: fileManager)
        self.config.restore(fileManager: fileManager)
    }
}

private struct ProfileSwitchFileSnapshot {
    let url: URL
    let data: Data?

    static func capture(url: URL, fileManager: FileManager) throws -> Self {
        guard fileManager.fileExists(atPath: url.path) else {
            return Self(url: url, data: nil)
        }
        do {
            return Self(url: url, data: try Data(contentsOf: url))
        } catch {
            throw ProfileTransactionError.unreadableSnapshot(path: url.path, error: error)
        }
    }

    func restore(fileManager: FileManager) {
        do {
            if let data {
                try AtomicFileWriter.write(data, to: self.url, fileManager: fileManager)
            } else if fileManager.fileExists(atPath: self.url.path) {
                try fileManager.removeItem(at: self.url)
            }
        } catch {
            CoreLogger.error(
                "Failed to roll back profile switch file",
                metadata: ["path": self.url.path, "error": error.localizedDescription])
        }
    }
}

public struct ProfileTransactionService {
    private let vault: AuthVault
    private let paths: AppPaths
    private let fileManager: FileManager
    private let isCodexDesktopRunning: () -> Bool

    public init(
        vault: AuthVault,
        paths: AppPaths = AppPaths(),
        fileManager: FileManager = .default,
        isCodexDesktopRunning: @escaping () -> Bool = { false }
    ) {
        self.vault = vault
        self.paths = paths
        self.fileManager = fileManager
        self.isCodexDesktopRunning = isCodexDesktopRunning
    }

    public func prepareSwitch(to profileID: String) throws -> PreparedProfileSwitch {
        try ProfileValidator.validate(profileID)
        guard var targetData = try self.vault.loadAuthBlobForActivation(profileID: profileID) else {
            throw ProfileTransactionError.missingSavedAuth(profileID)
        }

        try AtomicFileWriter.ensurePrivateDirectory(self.paths.liveCodexHome, fileManager: self.fileManager)

        let liveData = try self.readLiveAuthIfPresent()
        let outgoingProfileID = try liveData.flatMap { try self.classifyOutgoingProfile(liveData: $0) }
        if outgoingProfileID == profileID, let liveData {
            targetData = liveData
        }
        let alreadyActive = outgoingProfileID == profileID && self.isCodexDesktopRunning()

        return PreparedProfileSwitch(
            profileID: profileID,
            outgoingProfileID: outgoingProfileID,
            alreadyActive: alreadyActive,
            targetData: targetData,
            outgoingLiveData: liveData,
            vault: self.vault,
            paths: self.paths,
            fileManager: self.fileManager)
    }

    public func matchingProfiles(for liveData: Data) throws -> [String] {
        guard let liveFingerprint = AuthBlob.identityFingerprint(from: liveData) else { return [] }
        return try self.vault.listProfileIDs()
            .filter(ProfileValidator.isValid)
            .filter { profile in
                guard let data = try? self.vault.loadAuthBlob(profileID: profile) else { return false }
                return AuthBlob.identityFingerprint(from: data) == liveFingerprint
            }
            .sorted()
    }

    private func readLiveAuthIfPresent() throws -> Data? {
        let liveAuthURL = self.paths.liveAuthURL
        guard self.fileManager.fileExists(atPath: liveAuthURL.path) else { return nil }
        do {
            return try Data(contentsOf: liveAuthURL)
        } catch {
            throw ProfileTransactionError.unreadableLiveAuth(path: liveAuthURL.path, error: error)
        }
    }

    private func classifyOutgoingProfile(liveData: Data) throws -> String {
        let matches = try self.matchingProfiles(for: liveData)
        if matches.count == 1 {
            return matches[0]
        }
        if matches.count > 1 {
            let active = ProfileConfigStore(paths: self.paths, fileManager: self.fileManager).loadConfig()?.activeProfile ?? ""
            if matches.contains(active) {
                return active
            }
            throw ProfileTransactionError.ambiguousLiveAuth
        }

        let active = ProfileConfigStore(paths: self.paths, fileManager: self.fileManager).loadConfig()?.activeProfile ?? ""
        let liveFingerprint = AuthBlob.identityFingerprint(from: liveData)
        if ProfileValidator.isValid(active),
           let data = try self.vault.loadAuthBlobForActivation(profileID: active),
           let savedFingerprint = AuthBlob.identityFingerprint(from: data),
           savedFingerprint == liveFingerprint {
            return active
        }
        throw ProfileTransactionError.unmanagedLiveAuth
    }
}

public struct ProfileConfigStore {
    public static let keychainAuthStorageVersion = 2

    private let paths: AppPaths
    private let fileManager: FileManager

    public init(paths: AppPaths = AppPaths(), fileManager: FileManager = .default) {
        self.paths = paths
        self.fileManager = fileManager
    }

    public func loadConfig() -> AppConfig? {
        guard let data = try? Data(contentsOf: self.paths.configURL) else { return nil }
        return try? JSONDecoder().decode(AppConfig.self, from: data)
    }

    public func saveActiveProfileIfMissing(_ profileID: String) throws {
        if self.loadConfig()?.activeProfile == nil {
            try self.saveActiveProfile(profileID)
        }
    }

    public func saveActiveProfile(_ profileID: String) throws {
        try AtomicFileWriter.ensurePrivateDirectory(self.paths.switcherHome, fileManager: self.fileManager)
        var config = self.loadConfig() ?? AppConfig(
            profiles: [],
            activeProfile: profileID,
            authStorageVersion: Self.keychainAuthStorageVersion)
        config.activeProfile = profileID
        config.authStorageVersion = max(
            config.authStorageVersion ?? Self.keychainAuthStorageVersion,
            Self.keychainAuthStorageVersion)
        if !config.profiles.contains(where: { $0.id == profileID }) {
            config.profiles.append(ProfileConfig(id: profileID, label: "Profile \(profileID)"))
        }
        let data = try JSONEncoder.codexProfilePrettySorted.encode(config)
        try AtomicFileWriter.write(data, to: self.paths.configURL, fileManager: self.fileManager)
    }

    public func markAuthStorageVersion(_ version: Int) throws {
        guard var config = self.loadConfig() else { return }
        config.authStorageVersion = max(config.authStorageVersion ?? version, version)
        let data = try JSONEncoder.codexProfilePrettySorted.encode(config)
        try AtomicFileWriter.write(data, to: self.paths.configURL, fileManager: self.fileManager)
    }

    public func markMigrationComplete(_ complete: Bool) throws {
        try AtomicFileWriter.ensurePrivateDirectory(self.paths.switcherHome, fileManager: self.fileManager)
        var config = self.loadConfig() ?? AppConfig(
            profiles: [],
            activeProfile: "1",
            authStorageVersion: Self.keychainAuthStorageVersion)
        config.migrationComplete = complete
        let data = try JSONEncoder.codexProfilePrettySorted.encode(config)
        try AtomicFileWriter.write(data, to: self.paths.configURL, fileManager: self.fileManager)
    }

    public func ensureProfiles(_ profileIDs: [String]) throws {
        guard !profileIDs.isEmpty else { return }
        try AtomicFileWriter.ensurePrivateDirectory(self.paths.switcherHome, fileManager: self.fileManager)
        let sortedIDs = profileIDs.filter(ProfileValidator.isValid).sorted()
        guard !sortedIDs.isEmpty else { return }

        var config = self.loadConfig() ?? AppConfig(
            profiles: [],
            activeProfile: sortedIDs[0],
            authStorageVersion: Self.keychainAuthStorageVersion)
        if config.activeProfile.isEmpty {
            config.activeProfile = sortedIDs[0]
        }
        for id in sortedIDs where !config.profiles.contains(where: { $0.id == id }) {
            config.profiles.append(ProfileConfig(id: id, label: "Profile \(id)"))
        }
        let data = try JSONEncoder.codexProfilePrettySorted.encode(config)
        try AtomicFileWriter.write(data, to: self.paths.configURL, fileManager: self.fileManager)
    }
}

public enum ProfileTransactionError: LocalizedError {
    case missingSavedAuth(String)
    case unreadableLiveAuth(path: String, error: Error)
    case unreadableSnapshot(path: String, error: Error)
    case unmanagedLiveAuth
    case ambiguousLiveAuth

    public var errorDescription: String? {
        switch self {
        case .missingSavedAuth(let profileID):
            return "No saved auth for profile '\(profileID)'. Run 'codex-profile login \(profileID)' first."
        case let .unreadableLiveAuth(path, error):
            return "Could not read live auth at \(path). Refusing to overwrite it: \(error.localizedDescription)"
        case let .unreadableSnapshot(path, error):
            return "Could not snapshot profile switch state at \(path). Refusing to switch profiles: \(error.localizedDescription)"
        case .unmanagedLiveAuth:
            return "Live auth does not match any saved profile. Refusing to overwrite ~/.codex/auth.json until the current account is saved in the switcher."
        case .ambiguousLiveAuth:
            return "Live auth matches multiple saved profiles and config.activeProfile is not one of them."
        }
    }
}

public extension JSONEncoder {
    static let codexProfilePrettySorted: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()
}
