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

    public func commit() throws {
        if let outgoingProfileID, let outgoingLiveData {
            try self.vault.saveAuthBlob(outgoingLiveData, profileID: outgoingProfileID)
        }
        try AtomicFileWriter.write(self.targetData, to: self.paths.liveAuthURL, fileManager: self.fileManager)
        try ProfileConfigStore(paths: self.paths, fileManager: self.fileManager).saveActiveProfile(self.profileID)
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
        guard let targetData = try self.vault.loadAuthBlob(profileID: profileID) else {
            throw ProfileTransactionError.missingSavedAuth(profileID)
        }

        try AtomicFileWriter.ensurePrivateDirectory(self.paths.liveCodexHome, fileManager: self.fileManager)

        let liveData = try self.readLiveAuthIfPresent()
        let outgoingProfileID = try liveData.flatMap { try self.classifyOutgoingProfile(liveData: $0) }
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
}

public enum ProfileTransactionError: LocalizedError {
    case missingSavedAuth(String)
    case unreadableLiveAuth(path: String, error: Error)
    case unmanagedLiveAuth
    case ambiguousLiveAuth

    public var errorDescription: String? {
        switch self {
        case .missingSavedAuth(let profileID):
            return "No saved auth for profile '\(profileID)'. Run 'codex-profile login \(profileID)' first."
        case let .unreadableLiveAuth(path, error):
            return "Could not read live auth at \(path). Refusing to overwrite it: \(error.localizedDescription)"
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
