import Foundation

public struct ProfileConfig: Codable, Identifiable, Equatable {
    public var id: String
    public var label: String

    public init(id: String, label: String) {
        self.id = id
        self.label = label
    }
}

public struct AppConfig: Codable, Equatable {
    public var profiles: [ProfileConfig]
    public var activeProfile: String
    public var authStorageVersion: Int?
    public var migrationComplete: Bool?

    public init(
        profiles: [ProfileConfig],
        activeProfile: String,
        authStorageVersion: Int? = nil,
        migrationComplete: Bool? = nil
    ) {
        self.profiles = profiles
        self.activeProfile = activeProfile
        self.authStorageVersion = authStorageVersion
        self.migrationComplete = migrationComplete
    }
}
