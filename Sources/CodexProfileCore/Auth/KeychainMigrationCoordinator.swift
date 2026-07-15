import Foundation

public enum KeychainMigrationCandidateStatus: Equatable, Sendable {
    case ready
    case cleanupPending
}

public enum KeychainMigrationCandidateAction: Equatable, Sendable {
    case moveAndRemoveLegacyCopy
    case completeVerifiedCopy
}

public struct KeychainMigrationCandidate: Equatable, Identifiable, Sendable {
    public let id: String
    public let label: String
    public let status: KeychainMigrationCandidateStatus
    public let action: KeychainMigrationCandidateAction

    init(
        id: String,
        label: String,
        status: KeychainMigrationCandidateStatus,
        action: KeychainMigrationCandidateAction
    ) {
        self.id = id
        self.label = label
        self.status = status
        self.action = action
    }
}

public struct KeychainMigrationPreview: Equatable, Sendable {
    /// Candidates that will delete one captured legacy Keychain item after v2 verification.
    public let candidates: [KeychainMigrationCandidate]
    /// Pending records whose legacy source was already deleted and only need an explicit completion checkpoint.
    public let pendingCompletionCandidates: [KeychainMigrationCandidate]

    public var candidateCount: Int {
        self.candidates.count
    }

    public var pendingCompletionCount: Int {
        self.pendingCompletionCandidates.count
    }

    fileprivate let sessionID: UUID

    init(
        candidates: [KeychainMigrationCandidate],
        pendingCompletionCandidates: [KeychainMigrationCandidate],
        sessionID: UUID
    ) {
        self.candidates = candidates
        self.pendingCompletionCandidates = pendingCompletionCandidates
        self.sessionID = sessionID
    }
}

public enum KeychainMigrationError: LocalizedError, Equatable {
    case legacySourceFailed
    case invalidLegacyRecord
    case duplicateProfileID
    case completeProfileStillInLegacy
    case destinationUnavailable
    case destinationReadbackFailed
    case conflictingDestination
    case checkpointFailed
    case staleLegacySource
    case legacyCleanupFailed
    case reviewAlreadyInProgress
    case staleOrConsumedPreview
    case candidateCountMismatch
    case pendingCompletionCountMismatch

    public var errorDescription: String? {
        switch self {
        case .legacySourceFailed:
            return "Could not read legacy Keychain copies for migration."
        case .invalidLegacyRecord:
            return "A legacy Keychain copy is not a valid saved account."
        case .duplicateProfileID:
            return "Legacy Keychain copies contain duplicate profile IDs."
        case .completeProfileStillInLegacy:
            return "A completed migration still has a legacy Keychain copy."
        case .destinationUnavailable:
            return "The Data Protection Keychain is unavailable for migration."
        case .destinationReadbackFailed:
            return "Could not verify the Data Protection Keychain copy."
        case .conflictingDestination:
            return "A Data Protection Keychain copy conflicts with a legacy copy."
        case .checkpointFailed:
            return "Could not save migration progress."
        case .staleLegacySource:
            return "A legacy Keychain copy changed before it could be removed."
        case .legacyCleanupFailed:
            return "The new Keychain copy is safe, but the legacy copy could not be removed."
        case .reviewAlreadyInProgress:
            return "A legacy Keychain migration review is already in progress."
        case .staleOrConsumedPreview:
            return "This legacy Keychain migration review is no longer valid."
        case .candidateCountMismatch:
            return "The approved legacy Keychain copy count does not match the review."
        case .pendingCompletionCountMismatch:
            return "The approved pending migration count does not match the review."
        }
    }
}

enum KeychainMigrationCreateResult: Equatable {
    case created
    case alreadyExists
}

protocol KeychainMigrationDestination: AuthVault {
    func createAuthBlobIfAbsentForMigration(
        _ data: Data,
        profileID: String
    ) throws -> KeychainMigrationCreateResult
}

public final class KeychainMigrationCoordinator {
    private struct Session {
        let id: UUID
        let captures: [LegacyKeychainAuthBlobCapture]
        let pendingCompletionProfileIDs: [String]
        let preview: KeychainMigrationPreview
    }

    private let captureLegacyRecords: () throws -> [LegacyKeychainAuthBlobCapture]
    private let deleteLegacyRecord: (LegacyKeychainAuthBlobCapture) throws -> Void
    private let destination: KeychainMigrationDestination
    private let profiles: [ProfileConfig]
    private let migrationStates: [String: AuthMigrationState]
    private let checkpoint: (String, AuthMigrationState) throws -> Void
    private var activeSession: Session?
    private var isOperationInProgress = false

    public convenience init(
        legacyVault: LegacyKeychainAuthVault,
        destination: DataProtectionKeychainAuthVault,
        profiles: [ProfileConfig],
        migrationStates: [String: AuthMigrationState]?,
        checkpoint: @escaping (String, AuthMigrationState) throws -> Void
    ) {
        self.init(
            captureLegacyRecords: { try legacyVault.captureLegacyAuthBlobsForMigration() },
            deleteLegacyRecord: { capture in try legacyVault.deleteCapturedLegacyAuthBlob(capture) },
            destination: destination,
            profiles: profiles,
            migrationStates: migrationStates,
            checkpoint: checkpoint)
    }

    init(
        captureLegacyRecords: @escaping () throws -> [LegacyKeychainAuthBlobCapture],
        deleteLegacyRecord: @escaping (LegacyKeychainAuthBlobCapture) throws -> Void,
        destination: KeychainMigrationDestination,
        profiles: [ProfileConfig],
        migrationStates: [String: AuthMigrationState]?,
        checkpoint: @escaping (String, AuthMigrationState) throws -> Void
    ) {
        self.captureLegacyRecords = captureLegacyRecords
        self.deleteLegacyRecord = deleteLegacyRecord
        self.destination = destination
        self.profiles = profiles
        self.migrationStates = migrationStates ?? [:]
        self.checkpoint = checkpoint
    }

    public func review() throws -> KeychainMigrationPreview {
        guard !self.isOperationInProgress else {
            throw KeychainMigrationError.reviewAlreadyInProgress
        }
        guard self.activeSession == nil else {
            throw KeychainMigrationError.reviewAlreadyInProgress
        }
        self.isOperationInProgress = true
        defer { self.isOperationInProgress = false }
        guard self.destination.diagnostics().activeBackend == .dataProtectionKeychain else {
            throw KeychainMigrationError.destinationUnavailable
        }

        let captures: [LegacyKeychainAuthBlobCapture]
        do {
            captures = try self.captureLegacyRecords()
        } catch {
            throw KeychainMigrationError.legacySourceFailed
        }
        try self.validateLegacyCaptures(captures)
        try self.validateDestinationCopies(captures)

        let pendingCompletionProfileIDs = try self.pendingCompletionProfileIDs(excluding: captures)
        let candidates = captures
            .sorted { $0.profileID < $1.profileID }
            .map { capture in
                KeychainMigrationCandidate(
                    id: capture.profileID,
                    label: self.label(for: capture.profileID),
                    status: self.migrationStates[capture.profileID] == .copiedCleanupPending
                        ? .cleanupPending
                        : .ready,
                    action: .moveAndRemoveLegacyCopy)
            }
        let pendingCompletionCandidates = pendingCompletionProfileIDs.map { profileID in
            KeychainMigrationCandidate(
                id: profileID,
                label: self.label(for: profileID),
                status: .cleanupPending,
                action: .completeVerifiedCopy)
        }
        let sessionID = UUID()
        let preview = KeychainMigrationPreview(
            candidates: candidates,
            pendingCompletionCandidates: pendingCompletionCandidates,
            sessionID: sessionID)
        self.activeSession = Session(
            id: sessionID,
            captures: captures,
            pendingCompletionProfileIDs: pendingCompletionProfileIDs,
            preview: preview)
        return preview
    }

    public func cancel(_ preview: KeychainMigrationPreview) {
        guard self.activeSession?.id == preview.sessionID else { return }
        self.activeSession = nil
    }

    /// Confirms only the legacy-copy removals represented by `candidateCount`.
    public func confirm(_ preview: KeychainMigrationPreview, approvedCount: Int) throws {
        guard !self.isOperationInProgress else {
            throw KeychainMigrationError.staleOrConsumedPreview
        }
        guard let session = self.consumeSession(matching: preview), !session.captures.isEmpty else {
            throw KeychainMigrationError.staleOrConsumedPreview
        }
        self.isOperationInProgress = true
        defer { self.isOperationInProgress = false }
        guard approvedCount == session.preview.candidateCount else {
            throw KeychainMigrationError.candidateCountMismatch
        }
        try self.validateDestinationCopies(session.captures)

        for capture in session.captures.sorted(by: { $0.profileID < $1.profileID }) {
            try self.copyAndVerify(capture)
            try self.saveCheckpoint(.copiedCleanupPending, for: capture.profileID)
            try self.deleteLegacy(capture)
            try self.verifyDestinationCopy(for: capture)
            try self.saveCheckpoint(.complete, for: capture.profileID)
        }
    }

    /// Completes only pending records whose legacy source was already removed.
    public func completePending(_ preview: KeychainMigrationPreview, approvedCount: Int) throws {
        guard !self.isOperationInProgress else {
            throw KeychainMigrationError.staleOrConsumedPreview
        }
        guard let session = self.consumeSession(matching: preview),
              session.captures.isEmpty,
              !session.pendingCompletionProfileIDs.isEmpty else {
            throw KeychainMigrationError.staleOrConsumedPreview
        }
        self.isOperationInProgress = true
        defer { self.isOperationInProgress = false }
        guard approvedCount == session.preview.pendingCompletionCount else {
            throw KeychainMigrationError.pendingCompletionCountMismatch
        }
        for profileID in session.pendingCompletionProfileIDs {
            try self.verifyPendingCompletionCopy(profileID: profileID)
            try self.saveCheckpoint(.complete, for: profileID)
        }
    }

    private func consumeSession(matching preview: KeychainMigrationPreview) -> Session? {
        guard let session = self.activeSession, session.id == preview.sessionID else {
            return nil
        }
        self.activeSession = nil
        return session
    }

    private func validateLegacyCaptures(_ captures: [LegacyKeychainAuthBlobCapture]) throws {
        var profileIDs = Set<String>()
        for capture in captures {
            guard ProfileValidator.isValid(capture.profileID),
                  AuthBlob.isPlausibleAuthBlob(capture.authBlob),
                  !capture.persistentReference.isEmpty else {
                throw KeychainMigrationError.invalidLegacyRecord
            }
            guard profileIDs.insert(capture.profileID).inserted else {
                throw KeychainMigrationError.duplicateProfileID
            }
            guard self.migrationStates[capture.profileID] != .complete else {
                throw KeychainMigrationError.completeProfileStillInLegacy
            }
        }
    }

    private func validateDestinationCopies(_ captures: [LegacyKeychainAuthBlobCapture]) throws {
        for capture in captures {
            let existing: Data?
            do {
                existing = try self.destination.loadAuthBlob(profileID: capture.profileID)
            } catch {
                throw KeychainMigrationError.destinationReadbackFailed
            }
            guard existing == nil || existing == capture.authBlob else {
                throw KeychainMigrationError.conflictingDestination
            }
        }
    }

    private func copyAndVerify(_ capture: LegacyKeychainAuthBlobCapture) throws {
        let existing: Data?
        do {
            existing = try self.destination.loadAuthBlob(profileID: capture.profileID)
        } catch {
            throw KeychainMigrationError.destinationReadbackFailed
        }
        if let existing {
            guard existing == capture.authBlob else {
                throw KeychainMigrationError.conflictingDestination
            }
            return
        }

        let createResult: KeychainMigrationCreateResult
        do {
            createResult = try self.destination.createAuthBlobIfAbsentForMigration(
                capture.authBlob,
                profileID: capture.profileID)
        } catch {
            throw KeychainMigrationError.destinationReadbackFailed
        }
        if createResult == .alreadyExists {
            try self.verifyDestinationCopy(for: capture, mismatchedCopyError: .conflictingDestination)
            return
        }
        try self.verifyDestinationCopy(for: capture)
    }

    private func verifyDestinationCopy(
        for capture: LegacyKeychainAuthBlobCapture,
        mismatchedCopyError: KeychainMigrationError = .destinationReadbackFailed
    ) throws {
        let copied: Data?
        do {
            copied = try self.destination.loadAuthBlob(profileID: capture.profileID)
        } catch {
            throw KeychainMigrationError.destinationReadbackFailed
        }
        guard let copied else {
            throw KeychainMigrationError.destinationReadbackFailed
        }
        guard copied == capture.authBlob else {
            throw mismatchedCopyError
        }
    }

    private func saveCheckpoint(_ state: AuthMigrationState, for profileID: String) throws {
        do {
            try self.checkpoint(profileID, state)
        } catch {
            throw KeychainMigrationError.checkpointFailed
        }
    }

    private func deleteLegacy(_ capture: LegacyKeychainAuthBlobCapture) throws {
        do {
            try self.deleteLegacyRecord(capture)
        } catch KeychainAuthVaultError.staleMigrationSource {
            throw KeychainMigrationError.staleLegacySource
        } catch {
            throw KeychainMigrationError.legacyCleanupFailed
        }
    }

    private func pendingCompletionProfileIDs(
        excluding captures: [LegacyKeychainAuthBlobCapture]
    ) throws -> [String] {
        let sourceProfileIDs = Set(captures.map(\.profileID))
        let profileIDs = self.migrationStates.compactMap { profileID, state in
            state == .copiedCleanupPending && !sourceProfileIDs.contains(profileID) ? profileID : nil
        }
        for profileID in profileIDs {
            try self.verifyPendingCompletionCopy(profileID: profileID)
        }
        return profileIDs.sorted()
    }

    private func verifyPendingCompletionCopy(profileID: String) throws {
        guard ProfileValidator.isValid(profileID) else {
            throw KeychainMigrationError.destinationReadbackFailed
        }
        let data: Data?
        do {
            data = try self.destination.loadAuthBlob(profileID: profileID)
        } catch {
            throw KeychainMigrationError.destinationReadbackFailed
        }
        guard let data, AuthBlob.isPlausibleAuthBlob(data) else {
            throw KeychainMigrationError.destinationReadbackFailed
        }
    }

    private func label(for profileID: String) -> String {
        guard let label = self.profiles.first(where: { $0.id == profileID })?.label
            .trimmingCharacters(in: .whitespacesAndNewlines), !label.isEmpty else {
            return "Unconfigured saved account"
        }
        return label
    }
}
