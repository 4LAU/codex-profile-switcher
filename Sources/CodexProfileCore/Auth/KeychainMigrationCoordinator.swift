import Foundation
import CryptoKit

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
        let legacyProfileIDs: [String]
        let pendingCompletionProfileIDs: [String]
        let preview: KeychainMigrationPreview
    }

    private let captureLegacyRecords: () throws -> [LegacyKeychainAuthBlobCapture]
    private let listLegacyProfileIDs: (() throws -> [String])?
    private let captureLegacyRecord: ((String) throws -> LegacyKeychainAuthBlobCapture)?
    private let deleteLegacyRecord: (LegacyKeychainAuthBlobCapture) throws -> Void
    private let destination: KeychainMigrationDestination
    private let profiles: [ProfileConfig]
    private let migrationStates: [String: AuthMigrationState]
    private let pendingFingerprints: [String: String]
    private let checkpoint: (String, AuthMigrationState, String?) throws -> Void
    private var activeSession: Session?
    private var isOperationInProgress = false

    public convenience init(
        legacyVault: LegacyKeychainAuthVault,
        destination: DataProtectionKeychainAuthVault,
        profiles: [ProfileConfig],
        migrationStates: [String: AuthMigrationState]?,
        pendingFingerprints: [String: String]?,
        checkpoint: @escaping (String, AuthMigrationState, String?) throws -> Void
    ) {
        self.init(
            captureLegacyRecords: { try legacyVault.captureLegacyAuthBlobsForMigration() },
            listLegacyProfileIDs: { try legacyVault.listProfileIDs() },
            captureLegacyRecord: { try legacyVault.captureLegacyAuthBlobForMigration(profileID: $0) },
            deleteLegacyRecord: { capture in try legacyVault.deleteCapturedLegacyAuthBlob(capture) },
            destination: destination,
            profiles: profiles,
            migrationStates: migrationStates,
            pendingFingerprints: pendingFingerprints,
            checkpoint: checkpoint)
    }

    init(
        captureLegacyRecords: @escaping () throws -> [LegacyKeychainAuthBlobCapture],
        listLegacyProfileIDs: (() throws -> [String])? = nil,
        captureLegacyRecord: ((String) throws -> LegacyKeychainAuthBlobCapture)? = nil,
        deleteLegacyRecord: @escaping (LegacyKeychainAuthBlobCapture) throws -> Void,
        destination: KeychainMigrationDestination,
        profiles: [ProfileConfig],
        migrationStates: [String: AuthMigrationState]?,
        pendingFingerprints: [String: String]?,
        checkpoint: @escaping (String, AuthMigrationState, String?) throws -> Void
    ) {
        self.captureLegacyRecords = captureLegacyRecords
        self.listLegacyProfileIDs = listLegacyProfileIDs
        self.captureLegacyRecord = captureLegacyRecord
        self.deleteLegacyRecord = deleteLegacyRecord
        self.destination = destination
        self.profiles = profiles
        self.migrationStates = migrationStates ?? [:]
        self.pendingFingerprints = pendingFingerprints ?? [:]
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
        let legacyProfileIDs: [String]
        if let listLegacyProfileIDs = self.listLegacyProfileIDs {
            do {
                legacyProfileIDs = try listLegacyProfileIDs()
            } catch {
                throw KeychainMigrationError.legacySourceFailed
            }
            try self.validateLegacyProfileIDs(legacyProfileIDs)
            captures = []
        } else {
            do {
                captures = try self.captureLegacyRecords()
            } catch {
                throw KeychainMigrationError.legacySourceFailed
            }
            try self.validateLegacyCaptures(captures)
            try self.validateDestinationCopies(captures)
            legacyProfileIDs = captures.map(\.profileID)
        }

        let pendingCompletionProfileIDs = try self.pendingCompletionProfileIDs(excluding: legacyProfileIDs)
        let candidates = legacyProfileIDs
            .sorted()
            .map { capture in
                KeychainMigrationCandidate(
                    id: capture,
                    label: self.label(for: capture),
                    status: self.migrationStates[capture] == .copiedCleanupPending
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
            legacyProfileIDs: legacyProfileIDs,
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
        guard let session = self.consumeSession(matching: preview), !session.legacyProfileIDs.isEmpty else {
            throw KeychainMigrationError.staleOrConsumedPreview
        }
        self.isOperationInProgress = true
        defer { self.isOperationInProgress = false }
        guard approvedCount == session.preview.candidateCount else {
            throw KeychainMigrationError.candidateCountMismatch
        }
        if self.captureLegacyRecord == nil {
            try self.validateDestinationCopies(session.captures)
        }
        for profileID in session.legacyProfileIDs.sorted() {
            let capture: LegacyKeychainAuthBlobCapture
            if let captureLegacyRecord = self.captureLegacyRecord {
                do {
                    capture = try captureLegacyRecord(profileID)
                } catch {
                    throw KeychainMigrationError.legacySourceFailed
                }
                try self.validateLegacyCaptures([capture])
                try self.validateDestinationCopies([capture])
            } else {
                guard let existingCapture = session.captures.first(where: { $0.profileID == profileID }) else {
                    throw KeychainMigrationError.staleOrConsumedPreview
                }
                capture = existingCapture
            }
            try self.copyAndVerify(capture)
            try self.saveCheckpoint(
                .copiedCleanupPending,
                pendingFingerprint: self.integrityFingerprint(capture.authBlob),
                for: capture.profileID)
            try self.deleteLegacy(capture)
            try self.verifyDestinationAfterLegacyDeletion(capture)
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
            guard let fingerprint = self.pendingFingerprints[profileID] else {
                throw KeychainMigrationError.destinationReadbackFailed
            }
            try self.verifyPendingCompletionCopy(profileID: profileID, fingerprint: fingerprint)
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
        try self.validateLegacyProfileIDs(captures.map(\.profileID))
        for capture in captures {
            guard AuthBlob.isPlausibleAuthBlob(capture.authBlob),
                  !capture.persistentReference.isEmpty else {
                throw KeychainMigrationError.invalidLegacyRecord
            }
        }
    }

    private func validateLegacyProfileIDs(_ profileIDs: [String]) throws {
        var seenProfileIDs = Set<String>()
        for profileID in profileIDs {
            guard ProfileValidator.isValid(profileID) else {
                throw KeychainMigrationError.invalidLegacyRecord
            }
            guard seenProfileIDs.insert(profileID).inserted else {
                throw KeychainMigrationError.duplicateProfileID
            }
            guard self.migrationStates[profileID] != .complete else {
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
            guard existing == nil || existing == capture.authBlob
                    || self.migrationStates[capture.profileID] == .copiedCleanupPending else {
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
            if existing != capture.authBlob {
                guard self.migrationStates[capture.profileID] == .copiedCleanupPending else {
                    throw KeychainMigrationError.conflictingDestination
                }
                try self.restoreVerifiedDestinationCopy(capture)
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

    private func verifyDestinationAfterLegacyDeletion(
        _ capture: LegacyKeychainAuthBlobCapture
    ) throws {
        do {
            try self.verifyDestinationCopy(for: capture)
        } catch let error as KeychainMigrationError {
            try self.restoreVerifiedDestinationCopy(capture)
            throw error
        }
    }

    private func restoreVerifiedDestinationCopy(_ capture: LegacyKeychainAuthBlobCapture) throws {
        do {
            try self.destination.saveAuthBlob(capture.authBlob, profileID: capture.profileID)
        } catch {
            throw KeychainMigrationError.destinationReadbackFailed
        }
        try self.verifyDestinationCopy(for: capture)
    }

    private func saveCheckpoint(
        _ state: AuthMigrationState,
        pendingFingerprint: String? = nil,
        for profileID: String
    ) throws {
        do {
            try self.checkpoint(profileID, state, pendingFingerprint)
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

    private func pendingCompletionProfileIDs(excluding legacyProfileIDs: [String]) throws -> [String] {
        let sourceProfileIDs = Set(legacyProfileIDs)
        let profileIDs = self.migrationStates.compactMap { profileID, state in
            state == .copiedCleanupPending
                && !sourceProfileIDs.contains(profileID)
                && self.pendingFingerprints[profileID] != nil ? profileID : nil
        }
        for profileID in profileIDs {
            guard let fingerprint = self.pendingFingerprints[profileID] else { continue }
            try self.verifyPendingCompletionCopy(profileID: profileID, fingerprint: fingerprint)
        }
        return profileIDs.sorted()
    }

    private func verifyPendingCompletionCopy(profileID: String, fingerprint: String) throws {
        guard ProfileValidator.isValid(profileID) else {
            throw KeychainMigrationError.destinationReadbackFailed
        }
        let data: Data?
        do {
            data = try self.destination.loadAuthBlob(profileID: profileID)
        } catch {
            throw KeychainMigrationError.destinationReadbackFailed
        }
        guard let data,
              AuthBlob.isPlausibleAuthBlob(data),
              self.integrityFingerprint(data) == fingerprint else {
            throw KeychainMigrationError.destinationReadbackFailed
        }
    }

    private func integrityFingerprint(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func label(for profileID: String) -> String {
        guard let label = self.profiles.first(where: { $0.id == profileID })?.label
            .trimmingCharacters(in: .whitespacesAndNewlines), !label.isEmpty else {
            return "Unconfigured saved account"
        }
        return label
    }
}
