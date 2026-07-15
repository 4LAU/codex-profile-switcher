import Foundation

public struct ProfileConfig: Codable, Identifiable, Equatable {
    public var id: String
    public var label: String

    public init(id: String, label: String) {
        self.id = id
        self.label = label
    }
}

public enum AuthMigrationState: String, Codable, Equatable {
    case copiedCleanupPending = "copied_cleanup_pending"
    case complete
}

public struct AppConfig: Codable, Equatable {
    public var profiles: [ProfileConfig]
    public var activeProfile: String
    public var authStorageVersion: Int?
    public var authMigrationStates: [String: AuthMigrationState]?

    public init(
        profiles: [ProfileConfig],
        activeProfile: String,
        authStorageVersion: Int? = nil,
        authMigrationStates: [String: AuthMigrationState]? = nil
    ) {
        self.profiles = profiles
        self.activeProfile = activeProfile
        self.authStorageVersion = authStorageVersion
        self.authMigrationStates = authMigrationStates
    }
}
