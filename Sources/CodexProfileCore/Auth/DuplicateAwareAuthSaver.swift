import Foundation

public enum DuplicateAwareAuthSaverError: LocalizedError, Equatable {
    case duplicate(existingLabel: String)
    case missingFingerprint
    case staleWrite(profileLabel: String)

    public var errorDescription: String? {
        switch self {
        case .duplicate(let existingLabel):
            return "This account is already saved as '\(existingLabel)'."
        case .missingFingerprint:
            return "Saved auth does not contain enough account identity information."
        case .staleWrite(let profileLabel):
            return "Refusing to save: '\(profileLabel)' already holds a more recently refreshed credential for this account."
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

        try vault.transact {
            for profile in profiles where profile.id != targetProfileID {
                guard let existingData = try vault.loadAuthBlob(profileID: profile.id),
                      AuthBlob.identityFingerprint(from: existingData) == newFingerprint else {
                    continue
                }
                throw DuplicateAwareAuthSaverError.duplicate(existingLabel: profile.label)
            }

            // A concurrent nightly renewal can rotate the credential in
            // `targetProfileID` between when this caller read it and when it
            // writes. Refuse only on positive evidence of regression: the same
            // account already stored here with a strictly newer `lastRefresh`
            // than the one about to be written. An absent timestamp on either
            // side is not evidence of going backwards, and a different account
            // (different identity fingerprint) is always a legitimate replace.
            if let existingData = try vault.loadAuthBlob(profileID: targetProfileID),
               AuthBlob.identityFingerprint(from: existingData) == newFingerprint,
               let existingLastRefresh = (try? AuthBlob.load(from: existingData))?.lastRefresh,
               let newLastRefresh = (try? AuthBlob.load(from: data))?.lastRefresh,
               existingLastRefresh > newLastRefresh {
                let profileLabel = profiles.first(where: { $0.id == targetProfileID })?.label ?? targetProfileID
                throw DuplicateAwareAuthSaverError.staleWrite(profileLabel: profileLabel)
            }

            try vault._saveAuthBlobUnlocked(data, profileID: targetProfileID)
        }
    }
}
