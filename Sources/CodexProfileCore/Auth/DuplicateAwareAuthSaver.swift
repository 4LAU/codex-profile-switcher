import Foundation

public enum DuplicateAwareAuthSaverError: LocalizedError, Equatable {
    case duplicate(existingLabel: String)
    case missingFingerprint

    public var errorDescription: String? {
        switch self {
        case .duplicate(let existingLabel):
            return "This account is already saved as '\(existingLabel)'."
        case .missingFingerprint:
            return "Saved auth does not contain enough account identity information."
        }
    }
}

public enum DuplicateAwareAuthSaver {
    public static func save(
        _ data: Data,
        profileID targetProfileID: String,
        profiles: [ProfileConfig],
        vault: AuthVault
    ) throws {
        guard let newFingerprint = AuthBlob.identityFingerprint(from: data) else {
            throw DuplicateAwareAuthSaverError.missingFingerprint
        }

        for profile in profiles where profile.id != targetProfileID {
            guard let existingData = try vault.loadAuthBlob(profileID: profile.id),
                  AuthBlob.identityFingerprint(from: existingData) == newFingerprint else {
                continue
            }
            throw DuplicateAwareAuthSaverError.duplicate(existingLabel: profile.label)
        }

        try vault.saveAuthBlob(data, profileID: targetProfileID)
    }
}
