@testable import CodexProfileCore
import Foundation
import Testing

final class KeychainMigrationCoordinatorTests {
    @Test
    func reviewOrdersCandidatesAndUsesSafeLabels() throws {
        let source = MigrationSource(captures: [
            try migrationCapture(profileID: "bravo", reference: "ref-bravo"),
            try migrationCapture(profileID: "alpha", reference: "ref-alpha"),
        ])
        let destination = MigrationDestination()
        let checkpoints = MigrationCheckpoints()
        let coordinator = makeCoordinator(
            source: source,
            destination: destination,
            profiles: [ProfileConfig(id: "alpha", label: "Alpha Account")],
            migrationStates: ["bravo": .copiedCleanupPending],
            checkpoints: checkpoints)

        let preview = try coordinator.review()

        try expectEqual(preview.candidateCount, 2, "Wrong migration candidate count")
        try expectEqual(preview.candidates.map(\.id), ["alpha", "bravo"], "Candidates were not ordered")
        try expectEqual(preview.candidates.map(\.label), ["Alpha Account", "Unconfigured saved account"],
                        "Candidate labels leaked configuration gaps")
        try expectEqual(preview.candidates.map(\.status), [.ready, .cleanupPending],
                        "Candidate migration statuses were wrong")
        try expectEqual(preview.candidates.map(\.action), [.moveAndRemoveLegacyCopy, .moveAndRemoveLegacyCopy],
                        "Live legacy candidates must expose their destructive action")
        try expectEqual(preview.pendingCompletionCount, 0,
                        "Live legacy candidates must not appear in the pending-only section")
        try expectEqual(source.deletedReferences, [], "Review must not delete legacy records")
        try expectEqual(destination.atomicCreateProfileIDs, [], "Review must not write destination records")
        try expectEqual(destination.normalSaveProfileIDs, [], "Review must not use normal destination updates")
        try expectEqual(checkpoints.changes, [], "Review must not checkpoint migration state")
    }

    @Test
    func confirmedMigrationUsesExactReferencesAndPersistsBothCheckpoints() throws {
        let alpha = try migrationCapture(profileID: "alpha", reference: "exact-alpha")
        let bravo = try migrationCapture(profileID: "bravo", reference: "exact-bravo")
        let source = MigrationSource(captures: [bravo, alpha])
        let destination = MigrationDestination()
        let checkpoints = MigrationCheckpoints()
        let coordinator = makeCoordinator(
            source: source,
            destination: destination,
            profiles: [],
            migrationStates: nil,
            checkpoints: checkpoints)

        let preview = try coordinator.review()
        try coordinator.confirm(preview, approvedCount: preview.candidateCount)

        try expectEqual(source.deletedReferences, [alpha.persistentReference, bravo.persistentReference],
                        "Cleanup must use only the captured persistent references in profile order")
        try expectEqual(
            checkpoints.changes,
            [
                MigrationCheckpoint(profileID: "alpha", state: .copiedCleanupPending),
                MigrationCheckpoint(profileID: "alpha", state: .complete),
                MigrationCheckpoint(profileID: "bravo", state: .copiedCleanupPending),
                MigrationCheckpoint(profileID: "bravo", state: .complete),
            ],
            "Migration checkpoints were not persisted in the required order")
        try expectEqual(try destination.loadAuthBlob(profileID: "alpha"), alpha.authBlob,
                        "Verified destination copy is missing")
        try expectEqual(try destination.loadAuthBlob(profileID: "bravo"), bravo.authBlob,
                        "Verified destination copy is missing")
        try expectEqual(destination.atomicCreateProfileIDs, ["alpha", "bravo"],
                        "Migration must create missing v2 copies atomically")
        try expectEqual(destination.normalSaveProfileIDs, [],
                        "Migration must never use normal destination updates")
    }

    @Test
    func preflightRejectsInvalidDuplicateAndStaleLegacyRecordsWithoutMutations() throws {
        let invalidSource = MigrationSource(captures: [
            LegacyKeychainAuthBlobCapture(
                profileID: "bad/profile",
                authBlob: Data("not-auth".utf8),
                persistentReference: Data("ref".utf8),
                service: LegacyKeychainAuthVault.defaultService),
        ])
        try expectPreflightFailure(
            .invalidLegacyRecord,
            source: invalidSource,
            migrationStates: nil)

        let duplicate = try migrationCapture(profileID: "duplicate", reference: "one")
        let duplicateSource = MigrationSource(captures: [
            duplicate,
            try migrationCapture(profileID: "duplicate", reference: "two"),
        ])
        try expectPreflightFailure(
            .duplicateProfileID,
            source: duplicateSource,
            migrationStates: nil)

        let staleSource = MigrationSource(captures: [
            try migrationCapture(profileID: "complete", reference: "stale"),
        ])
        try expectPreflightFailure(
            .completeProfileStillInLegacy,
            source: staleSource,
            migrationStates: ["complete": .complete])
    }

    @Test
    func countMismatchConsumesTheReviewWithoutMutatingEitherVault() throws {
        let source = MigrationSource(captures: [
            try migrationCapture(profileID: "one", reference: "ref-one"),
        ])
        let destination = MigrationDestination()
        let checkpoints = MigrationCheckpoints()
        let coordinator = makeCoordinator(
            source: source,
            destination: destination,
            profiles: [],
            migrationStates: nil,
            checkpoints: checkpoints)
        let preview = try coordinator.review()

        try expectMigrationError(.candidateCountMismatch) {
            try coordinator.confirm(preview, approvedCount: 0)
        }
        try expectEqual(source.deletedReferences, [], "Count mismatch must not delete legacy records")
        try expectEqual(destination.atomicCreateProfileIDs, [], "Count mismatch must not save destination records")
        try expectEqual(checkpoints.changes, [], "Count mismatch must not checkpoint state")
        try expectMigrationError(.staleOrConsumedPreview) {
            try coordinator.confirm(preview, approvedCount: preview.candidateCount)
        }
    }

    @Test
    func destinationSaveOrReadbackFailurePreventsDeletion() throws {
        let saveFailure = try migrationCapture(profileID: "save-failure", reference: "ref-save")
        let saveSource = MigrationSource(captures: [saveFailure])
        let saveDestination = MigrationDestination(createError: true)
        let saveCheckpoints = MigrationCheckpoints()
        let saveCoordinator = makeCoordinator(
            source: saveSource,
            destination: saveDestination,
            profiles: [],
            migrationStates: nil,
            checkpoints: saveCheckpoints)
        let savePreview = try saveCoordinator.review()

        try expectMigrationError(.destinationReadbackFailed) {
            try saveCoordinator.confirm(savePreview, approvedCount: 1)
        }
        try expectEqual(saveSource.deletedReferences, [], "Save failure must not delete legacy data")
        try expectEqual(saveCheckpoints.changes, [], "Save failure must not checkpoint state")

        let readbackFailure = try migrationCapture(profileID: "readback-failure", reference: "ref-readback")
        let readbackSource = MigrationSource(captures: [readbackFailure])
        let readbackDestination = MigrationDestination(nilLoadCalls: [4])
        let readbackCheckpoints = MigrationCheckpoints()
        let readbackCoordinator = makeCoordinator(
            source: readbackSource,
            destination: readbackDestination,
            profiles: [],
            migrationStates: nil,
            checkpoints: readbackCheckpoints)
        let readbackPreview = try readbackCoordinator.review()

        try expectMigrationError(.destinationReadbackFailed) {
            try readbackCoordinator.confirm(readbackPreview, approvedCount: 1)
        }
        try expectEqual(readbackSource.deletedReferences, [], "Readback failure must not delete legacy data")
        try expectEqual(readbackCheckpoints.changes, [], "Readback failure must not checkpoint state")
    }

    @Test
    func atomicCreateCollisionReloadsAndRejectsAConflictingCopy() throws {
        let capture = try migrationCapture(profileID: "atomic-collision", reference: "ref-collision")
        let source = MigrationSource(captures: [capture])
        let destination = MigrationDestination(createCollisionData: try differentAuthBlob())
        let checkpoints = MigrationCheckpoints()
        let coordinator = makeCoordinator(
            source: source,
            destination: destination,
            profiles: [],
            migrationStates: nil,
            checkpoints: checkpoints)
        let preview = try coordinator.review()

        try expectMigrationError(.conflictingDestination) {
            try coordinator.confirm(preview, approvedCount: 1)
        }
        try expectEqual(destination.atomicCreateProfileIDs, ["atomic-collision"],
                        "Migration did not use atomic creation")
        try expectEqual(destination.normalSaveProfileIDs, [],
                        "A concurrent add must not be overwritten by normal save")
        try expectEqual(source.deletedReferences, [],
                        "A conflicting concurrent add must not delete legacy data")
        try expectEqual(checkpoints.changes, [],
                        "A conflicting concurrent add must not checkpoint state")
    }

    @Test
    func checkpointFailurePreventsDeletionAfterVerifiedCopy() throws {
        let capture = try migrationCapture(profileID: "checkpoint", reference: "ref-checkpoint")
        let source = MigrationSource(captures: [capture])
        let destination = MigrationDestination()
        let checkpoints = MigrationCheckpoints(failAt: 1)
        let coordinator = makeCoordinator(
            source: source,
            destination: destination,
            profiles: [],
            migrationStates: nil,
            checkpoints: checkpoints)
        let preview = try coordinator.review()

        try expectMigrationError(.checkpointFailed) {
            try coordinator.confirm(preview, approvedCount: 1)
        }
        try expectEqual(source.deletedReferences, [], "Checkpoint failure must not delete legacy data")
        try expectEqual(checkpoints.changes, [], "Failed checkpoint must not be recorded")
        try expectEqual(try destination.loadAuthBlob(profileID: "checkpoint"), capture.authBlob,
                        "Verified destination copy must remain after checkpoint failure")
    }

    @Test
    func cleanupAndFinalReadbackFailureLeaveDurablePendingState() throws {
        let deleteCapture = try migrationCapture(profileID: "delete-failure", reference: "ref-delete")
        let deleteSource = MigrationSource(captures: [deleteCapture], deleteError: true)
        let deleteDestination = MigrationDestination()
        let deleteCheckpoints = MigrationCheckpoints()
        let deleteCoordinator = makeCoordinator(
            source: deleteSource,
            destination: deleteDestination,
            profiles: [],
            migrationStates: nil,
            checkpoints: deleteCheckpoints)
        let deletePreview = try deleteCoordinator.review()

        try expectMigrationError(.legacyCleanupFailed) {
            try deleteCoordinator.confirm(deletePreview, approvedCount: 1)
        }
        try expectEqual(
            deleteCheckpoints.changes,
            [MigrationCheckpoint(profileID: "delete-failure", state: .copiedCleanupPending)],
            "Cleanup failure must retain the durable pending checkpoint")
        try expectEqual(try deleteDestination.loadAuthBlob(profileID: "delete-failure"), deleteCapture.authBlob,
                        "Cleanup failure must retain the verified destination copy")

        let finalCapture = try migrationCapture(profileID: "final-readback", reference: "ref-final")
        let finalSource = MigrationSource(captures: [finalCapture])
        let finalDestination = MigrationDestination(nilLoadCalls: [5])
        let finalCheckpoints = MigrationCheckpoints()
        let finalCoordinator = makeCoordinator(
            source: finalSource,
            destination: finalDestination,
            profiles: [],
            migrationStates: nil,
            checkpoints: finalCheckpoints)
        let finalPreview = try finalCoordinator.review()

        try expectMigrationError(.destinationReadbackFailed) {
            try finalCoordinator.confirm(finalPreview, approvedCount: 1)
        }
        try expectEqual(sourceReferences(finalSource), [finalCapture.persistentReference],
                        "Final readback failure should happen only after exact legacy cleanup")
        try expectEqual(
            finalCheckpoints.changes,
            [MigrationCheckpoint(profileID: "final-readback", state: .copiedCleanupPending)],
            "Final readback failure must leave the durable pending checkpoint")
    }

    @Test
    func changedLegacySourceIsRejectedBeforeDeletion() throws {
        let capture = try migrationCapture(profileID: "changed-source", reference: "ref-changed")
        let source = MigrationSource(captures: [capture])
        let destination = MigrationDestination()
        let checkpoints = MigrationCheckpoints()
        let coordinator = makeCoordinator(
            source: source,
            destination: destination,
            profiles: [],
            migrationStates: nil,
            checkpoints: checkpoints)
        let preview = try coordinator.review()
        source.replaceAuthBlob(try differentAuthBlob(), profileID: "changed-source")

        try expectMigrationError(.staleLegacySource) {
            try coordinator.confirm(preview, approvedCount: 1)
        }
        try expectEqual(source.deletedReferences, [],
                        "A changed legacy record must not be deleted through its old reference")
        try expectEqual(
            checkpoints.changes,
            [MigrationCheckpoint(profileID: "changed-source", state: .copiedCleanupPending)],
            "A stale source must retain the verified-copy pending checkpoint")
    }

    @Test
    func finalCheckpointFailureCanBeCompletedLaterWithoutALegacyRecord() throws {
        let capture = try migrationCapture(profileID: "checkpoint-recovery", reference: "ref-recovery")
        let source = MigrationSource(captures: [capture])
        let destination = MigrationDestination()
        let firstCheckpoints = MigrationCheckpoints(failAt: 2)
        let firstCoordinator = makeCoordinator(
            source: source,
            destination: destination,
            profiles: [],
            migrationStates: nil,
            checkpoints: firstCheckpoints)
        let firstPreview = try firstCoordinator.review()

        try expectMigrationError(.checkpointFailed) {
            try firstCoordinator.confirm(firstPreview, approvedCount: 1)
        }
        try expectEqual(source.deletedReferences, [capture.persistentReference],
                        "Final checkpoint failure must occur after exact legacy cleanup")
        try expectEqual(
            firstCheckpoints.changes,
            [MigrationCheckpoint(profileID: "checkpoint-recovery", state: .copiedCleanupPending)],
            "Final checkpoint failure must retain the pending state")

        let recoveryCheckpoints = MigrationCheckpoints()
        let recoveryCoordinator = makeCoordinator(
            source: source,
            destination: destination,
            profiles: [],
            migrationStates: ["checkpoint-recovery": .copiedCleanupPending],
            checkpoints: recoveryCheckpoints)
        let recoveryPreview = try recoveryCoordinator.review()

        try expectEqual(recoveryPreview.candidateCount, 0,
                        "A pending-only recovery must not be counted as a legacy deletion")
        try expectEqual(recoveryPreview.pendingCompletionCount, 1,
                        "Pending migration must remain visible after legacy cleanup")
        try expectEqual(recoveryPreview.pendingCompletionCandidates[0].id, "checkpoint-recovery",
                        "Pending migration row used the wrong profile")
        try expectEqual(recoveryPreview.pendingCompletionCandidates[0].status, .cleanupPending,
                        "Pending migration row lost its cleanup status")
        try expectEqual(recoveryPreview.pendingCompletionCandidates[0].action, .completeVerifiedCopy,
                        "Pending migration row must use the non-destructive completion action")
        try recoveryCoordinator.completePending(recoveryPreview, approvedCount: 1)
        try expectEqual(
            recoveryCheckpoints.changes,
            [MigrationCheckpoint(profileID: "checkpoint-recovery", state: .complete)],
            "Explicit recovery must finish without a new deletion target")
        try expectEqual(source.deletedReferences, [capture.persistentReference],
                        "Recovery must not attempt a second legacy deletion")
    }

    @Test
    func mixedReviewSeparatesExactDeletionTargetsFromPendingCompletionRows() throws {
        let legacyCapture = try migrationCapture(profileID: "live-legacy", reference: "ref-live")
        let pendingData = try oauthAuthData(idToken: try idToken(subject: "pending-only"))
        let source = MigrationSource(captures: [legacyCapture])
        let destination = MigrationDestination(authBlobs: ["pending-only": pendingData])
        let checkpoints = MigrationCheckpoints()
        let coordinator = makeCoordinator(
            source: source,
            destination: destination,
            profiles: [],
            migrationStates: ["pending-only": .copiedCleanupPending],
            checkpoints: checkpoints)
        let preview = try coordinator.review()

        try expectEqual(preview.candidateCount, 1,
                        "Only live legacy captures may contribute to the deletion count")
        try expectEqual(preview.candidates.map(\.id), ["live-legacy"],
                        "Deletion targets must contain only captured legacy records")
        try expectEqual(preview.candidates.map(\.action), [.moveAndRemoveLegacyCopy],
                        "Live capture must identify its destructive action")
        try expectEqual(preview.pendingCompletionCount, 1,
                        "Pending-only rows need a separate explicit completion count")
        try expectEqual(preview.pendingCompletionCandidates.map(\.id), ["pending-only"],
                        "Pending-only recovery row is missing")
        try expectEqual(preview.pendingCompletionCandidates.map(\.action), [.completeVerifiedCopy],
                        "Pending-only row must identify its non-destructive action")

        try coordinator.confirm(preview, approvedCount: preview.candidateCount)
        try expectEqual(source.deletedReferences, [legacyCapture.persistentReference],
                        "Only the exact live legacy capture may be deleted")
        try expectEqual(
            checkpoints.changes,
            [
                MigrationCheckpoint(profileID: "live-legacy", state: .copiedCleanupPending),
                MigrationCheckpoint(profileID: "live-legacy", state: .complete),
            ],
            "Legacy confirmation must not complete pending-only rows")

        let recoveryCheckpoints = MigrationCheckpoints()
        let recoveryCoordinator = makeCoordinator(
            source: source,
            destination: destination,
            profiles: [],
            migrationStates: ["pending-only": .copiedCleanupPending],
            checkpoints: recoveryCheckpoints)
        let recoveryPreview = try recoveryCoordinator.review()
        try recoveryCoordinator.completePending(
            recoveryPreview,
            approvedCount: recoveryPreview.pendingCompletionCount)
        try expectEqual(
            recoveryCheckpoints.changes,
            [MigrationCheckpoint(profileID: "pending-only", state: .complete)],
            "Pending-only recovery needs its own explicit completion action")
    }

    @Test
    func destructiveConfirmationRejectsTotalRowsWhenPendingRowsArePresent() throws {
        let legacyCapture = try migrationCapture(profileID: "count-live", reference: "ref-count")
        let pendingData = try oauthAuthData(idToken: try idToken(subject: "count-pending"))
        let source = MigrationSource(captures: [legacyCapture])
        let destination = MigrationDestination(authBlobs: ["count-pending": pendingData])
        let checkpoints = MigrationCheckpoints()
        let coordinator = makeCoordinator(
            source: source,
            destination: destination,
            profiles: [],
            migrationStates: ["count-pending": .copiedCleanupPending],
            checkpoints: checkpoints)
        let preview = try coordinator.review()

        try expectMigrationError(.candidateCountMismatch) {
            try coordinator.confirm(preview, approvedCount: 2)
        }
        try expectEqual(source.deletedReferences, [],
                        "A total review-row count must not authorize a legacy deletion")
        try expectEqual(checkpoints.changes, [],
                        "A mismatched destructive count must not checkpoint migration state")
    }

    @Test
    func pendingCompletionRequiresItsExactDisplayedCount() throws {
        let pendingData = try oauthAuthData(idToken: try idToken(subject: "pending-count"))
        let source = MigrationSource(captures: [])
        let destination = MigrationDestination(authBlobs: ["pending-count": pendingData])
        let checkpoints = MigrationCheckpoints()
        let coordinator = makeCoordinator(
            source: source,
            destination: destination,
            profiles: [],
            migrationStates: ["pending-count": .copiedCleanupPending],
            checkpoints: checkpoints)
        let preview = try coordinator.review()

        try expectMigrationError(.pendingCompletionCountMismatch) {
            try coordinator.completePending(preview, approvedCount: 0)
        }
        try expectEqual(checkpoints.changes, [],
                        "A mismatched pending completion count must not checkpoint state")
    }

    @Test
    func pendingRecoveryRequiresAPlausibleV2Copy() throws {
        let source = MigrationSource(captures: [])
        let destination = MigrationDestination(authBlobs: ["pending-invalid": Data("not-auth".utf8)])
        let checkpoints = MigrationCheckpoints()
        let coordinator = makeCoordinator(
            source: source,
            destination: destination,
            profiles: [],
            migrationStates: ["pending-invalid": .copiedCleanupPending],
            checkpoints: checkpoints)

        try expectMigrationError(.destinationReadbackFailed) {
            _ = try coordinator.review()
        }
        try expectEqual(checkpoints.changes, [],
                        "An invalid v2 copy must not advance a pending migration")
    }

    @Test
    func conflictingDestinationBeforeOrAfterReviewPreventsMutation() throws {
        let capture = try migrationCapture(profileID: "conflict", reference: "ref-conflict")
        let source = MigrationSource(captures: [capture])
        let destination = MigrationDestination(authBlobs: ["conflict": try differentAuthBlob()])
        let checkpoints = MigrationCheckpoints()
        let coordinator = makeCoordinator(
            source: source,
            destination: destination,
            profiles: [],
            migrationStates: nil,
            checkpoints: checkpoints)

        try expectMigrationError(.conflictingDestination) {
            _ = try coordinator.review()
        }
        try expectEqual(source.deletedReferences, [], "Conflicting preflight must not delete legacy data")
        try expectEqual(destination.atomicCreateProfileIDs, [], "Conflicting preflight must not write destination data")

        let matchingSource = MigrationSource(captures: [capture])
        let changingDestination = MigrationDestination()
        let changingCheckpoints = MigrationCheckpoints()
        let changingCoordinator = makeCoordinator(
            source: matchingSource,
            destination: changingDestination,
            profiles: [],
            migrationStates: nil,
            checkpoints: changingCheckpoints)
        let preview = try changingCoordinator.review()
        changingDestination.setAuthBlob(try differentAuthBlob(), profileID: "conflict")

        try expectMigrationError(.conflictingDestination) {
            try changingCoordinator.confirm(preview, approvedCount: 1)
        }
        try expectEqual(matchingSource.deletedReferences, [], "Stale destination conflict must not delete legacy data")
        try expectEqual(changingDestination.atomicCreateProfileIDs, [], "Stale destination conflict must not save data")
        try expectEqual(changingCheckpoints.changes, [], "Stale destination conflict must not checkpoint state")
    }

    @Test
    func previewIsOneUseAndCancelInvalidatesIt() throws {
        let capture = try migrationCapture(profileID: "one-use", reference: "ref-one-use")
        let source = MigrationSource(captures: [capture])
        let destination = MigrationDestination()
        let checkpoints = MigrationCheckpoints()
        let coordinator = makeCoordinator(
            source: source,
            destination: destination,
            profiles: [],
            migrationStates: nil,
            checkpoints: checkpoints)
        let preview = try coordinator.review()
        coordinator.cancel(preview)

        try expectMigrationError(.staleOrConsumedPreview) {
            try coordinator.confirm(preview, approvedCount: 1)
        }
        let freshPreview = try coordinator.review()
        try coordinator.confirm(freshPreview, approvedCount: 1)
        try expectMigrationError(.staleOrConsumedPreview) {
            try coordinator.confirm(freshPreview, approvedCount: 1)
        }
    }

    @Test
    func confirmationIsConsumedBeforeDestinationCallbacksCanReenter() throws {
        let capture = try migrationCapture(profileID: "reentrant", reference: "ref-reentrant")
        let source = MigrationSource(captures: [capture])
        let destination = MigrationDestination()
        let checkpoints = MigrationCheckpoints()
        let coordinator = makeCoordinator(
            source: source,
            destination: destination,
            profiles: [],
            migrationStates: nil,
            checkpoints: checkpoints)
        let preview = try coordinator.review()
        var didAttemptReentry = false
        var reentrantError: KeychainMigrationError?
        destination.beforeLoad = {
            guard !didAttemptReentry else { return }
            didAttemptReentry = true
            do {
                try coordinator.confirm(preview, approvedCount: preview.candidateCount)
            } catch let error as KeychainMigrationError {
                reentrantError = error
            } catch {
                reentrantError = nil
            }
        }

        try coordinator.confirm(preview, approvedCount: preview.candidateCount)

        try expect(didAttemptReentry, "Destination callback did not exercise reentrant confirmation")
        try expectEqual(reentrantError, .staleOrConsumedPreview,
                        "Reentrant confirmation must not retain an active session")
        try expectEqual(source.deletedReferences, [capture.persistentReference],
                        "Outer confirmation should retain its exact deletion path")
    }

    @Test
    func reviewIsRejectedWhileAConfirmationCallbackIsRunning() throws {
        let capture = try migrationCapture(profileID: "reentrant-review", reference: "ref-review")
        let source = MigrationSource(captures: [capture])
        let destination = MigrationDestination()
        let checkpoints = MigrationCheckpoints()
        let coordinator = makeCoordinator(
            source: source,
            destination: destination,
            profiles: [],
            migrationStates: nil,
            checkpoints: checkpoints)
        let preview = try coordinator.review()
        var didAttemptReview = false
        var reentrantReviewError: KeychainMigrationError?
        destination.beforeLoad = {
            guard !didAttemptReview else { return }
            didAttemptReview = true
            do {
                _ = try coordinator.review()
            } catch let error as KeychainMigrationError {
                reentrantReviewError = error
            } catch {
                reentrantReviewError = nil
            }
        }

        try coordinator.confirm(preview, approvedCount: preview.candidateCount)

        try expect(didAttemptReview, "Destination callback did not attempt a reentrant review")
        try expectEqual(reentrantReviewError, .reviewAlreadyInProgress,
                        "A review must not create a second session during confirmation")
        try expectEqual(source.captureCallCount, 1,
                        "Reentrant review must not recapture legacy Keychain records")
        try expectEqual(source.deletedReferences, [capture.persistentReference],
                        "Reentrant review must not add a second deletion")
        try expectEqual(
            checkpoints.changes,
            [
                MigrationCheckpoint(profileID: "reentrant-review", state: .copiedCleanupPending),
                MigrationCheckpoint(profileID: "reentrant-review", state: .complete),
            ],
            "Reentrant review must not add a checkpoint")
    }

    @Test
    func reviewIsRejectedWhileSourceCaptureIsRunning() throws {
        let capture = try migrationCapture(profileID: "reentrant-capture", reference: "ref-capture")
        let source = MigrationSource(captures: [capture])
        let destination = MigrationDestination()
        let checkpoints = MigrationCheckpoints()
        let coordinator = makeCoordinator(
            source: source,
            destination: destination,
            profiles: [],
            migrationStates: nil,
            checkpoints: checkpoints)
        var reentrantReviewError: KeychainMigrationError?
        source.beforeCapture = {
            do {
                _ = try coordinator.review()
            } catch let error as KeychainMigrationError {
                reentrantReviewError = error
            } catch {
                reentrantReviewError = nil
            }
        }

        let preview = try coordinator.review()

        try expectEqual(reentrantReviewError, .reviewAlreadyInProgress,
                        "Source capture must not create a nested migration review")
        try expectEqual(source.captureCallCount, 1,
                        "Reentrant review must not capture legacy records a second time")
        try coordinator.confirm(preview, approvedCount: preview.candidateCount)
        try expectEqual(source.deletedReferences, [capture.persistentReference],
                        "Only the outer review session may authorize deletion")
        try expectEqual(
            checkpoints.changes,
            [
                MigrationCheckpoint(profileID: "reentrant-capture", state: .copiedCleanupPending),
                MigrationCheckpoint(profileID: "reentrant-capture", state: .complete),
            ],
            "The outer review must retain its single valid session")
    }
}

private struct MigrationCheckpoint: Equatable {
    let profileID: String
    let state: AuthMigrationState
}

private enum MigrationTestError: Error {
    case expected
}

private final class MigrationSource {
    private var captures: [LegacyKeychainAuthBlobCapture]
    let deleteError: Bool
    private(set) var deletedReferences: [Data] = []
    private(set) var captureCallCount = 0
    var beforeCapture: (() -> Void)?

    init(captures: [LegacyKeychainAuthBlobCapture], deleteError: Bool = false) {
        self.captures = captures
        self.deleteError = deleteError
    }

    func capture() throws -> [LegacyKeychainAuthBlobCapture] {
        self.beforeCapture?()
        self.captureCallCount += 1
        return self.captures
    }

    func delete(_ capture: LegacyKeychainAuthBlobCapture) throws {
        guard let index = self.captures.firstIndex(where: {
            $0.persistentReference == capture.persistentReference
        }) else {
            throw KeychainAuthVaultError.staleMigrationSource
        }
        guard self.captures[index].authBlob == capture.authBlob else {
            throw KeychainAuthVaultError.staleMigrationSource
        }
        guard !self.deleteError else { throw MigrationTestError.expected }
        self.deletedReferences.append(capture.persistentReference)
        self.captures.remove(at: index)
    }

    func replaceAuthBlob(_ data: Data, profileID: String) {
        guard let index = self.captures.firstIndex(where: { $0.profileID == profileID }) else { return }
        let capture = self.captures[index]
        self.captures[index] = LegacyKeychainAuthBlobCapture(
            profileID: capture.profileID,
            authBlob: data,
            persistentReference: capture.persistentReference,
            service: capture.service)
    }
}

private final class MigrationDestination: KeychainMigrationDestination, @unchecked Sendable {
    private var authBlobs: [String: Data]
    private let createError: Bool
    private let createCollisionData: Data?
    private let nilLoadCalls: Set<Int>
    private(set) var atomicCreateProfileIDs: [String] = []
    private(set) var normalSaveProfileIDs: [String] = []
    private var loadCallCount = 0
    var beforeLoad: (() -> Void)?

    init(
        authBlobs: [String: Data] = [:],
        createError: Bool = false,
        createCollisionData: Data? = nil,
        nilLoadCalls: Set<Int> = []
    ) {
        self.authBlobs = authBlobs
        self.createError = createError
        self.createCollisionData = createCollisionData
        self.nilLoadCalls = nilLoadCalls
    }

    func listProfileIDs() throws -> [String] {
        self.authBlobs.keys.sorted()
    }

    func loadAuthBlob(profileID: String) throws -> Data? {
        self.beforeLoad?()
        self.loadCallCount += 1
        guard !self.nilLoadCalls.contains(self.loadCallCount) else { return nil }
        return self.authBlobs[profileID]
    }

    func saveAuthBlob(_ data: Data, profileID: String) throws {
        self.normalSaveProfileIDs.append(profileID)
        self.authBlobs[profileID] = data
    }

    func deleteAuthBlob(profileID: String) throws {
        self.authBlobs[profileID] = nil
    }

    func hasAuthBlob(profileID: String) throws -> Bool {
        self.authBlobs[profileID] != nil
    }

    func diagnostics() -> AuthVaultDiagnostics {
        AuthVaultDiagnostics(activeBackend: .dataProtectionKeychain)
    }

    func createAuthBlobIfAbsentForMigration(
        _ data: Data,
        profileID: String
    ) throws -> KeychainMigrationCreateResult {
        guard !self.createError else { throw MigrationTestError.expected }
        self.atomicCreateProfileIDs.append(profileID)
        if let collisionData = self.createCollisionData {
            self.authBlobs[profileID] = collisionData
            return .alreadyExists
        }
        guard self.authBlobs[profileID] == nil else { return .alreadyExists }
        self.authBlobs[profileID] = data
        return .created
    }

    func setAuthBlob(_ data: Data, profileID: String) {
        self.authBlobs[profileID] = data
    }
}

private final class MigrationCheckpoints {
    private let failAt: Int?
    private(set) var changes: [MigrationCheckpoint] = []
    private var attempts = 0

    init(failAt: Int? = nil) {
        self.failAt = failAt
    }

    func save(profileID: String, state: AuthMigrationState) throws {
        self.attempts += 1
        guard self.attempts != self.failAt else { throw MigrationTestError.expected }
        self.changes.append(MigrationCheckpoint(profileID: profileID, state: state))
    }
}

private func makeCoordinator(
    source: MigrationSource,
    destination: MigrationDestination,
    profiles: [ProfileConfig],
    migrationStates: [String: AuthMigrationState]?,
    checkpoints: MigrationCheckpoints
) -> KeychainMigrationCoordinator {
    KeychainMigrationCoordinator(
        captureLegacyRecords: { try source.capture() },
        deleteLegacyRecord: { capture in try source.delete(capture) },
        destination: destination,
        profiles: profiles,
        migrationStates: migrationStates,
        checkpoint: { profileID, state in
            try checkpoints.save(profileID: profileID, state: state)
        })
}

private func migrationCapture(
    profileID: String,
    reference: String
) throws -> LegacyKeychainAuthBlobCapture {
    LegacyKeychainAuthBlobCapture(
        profileID: profileID,
        authBlob: try oauthAuthData(idToken: try idToken(subject: profileID)),
        persistentReference: Data(reference.utf8),
        service: LegacyKeychainAuthVault.defaultService)
}

private func differentAuthBlob() throws -> Data {
    try oauthAuthData(idToken: try idToken(subject: "different-user"))
}

private func expectPreflightFailure(
    _ expected: KeychainMigrationError,
    source: MigrationSource,
    migrationStates: [String: AuthMigrationState]?
) throws {
    let destination = MigrationDestination()
    let checkpoints = MigrationCheckpoints()
    let coordinator = makeCoordinator(
        source: source,
        destination: destination,
        profiles: [],
        migrationStates: migrationStates,
        checkpoints: checkpoints)

    try expectMigrationError(expected) {
        _ = try coordinator.review()
    }
    try expectEqual(source.deletedReferences, [], "Invalid preflight must not delete legacy data")
    try expectEqual(destination.atomicCreateProfileIDs, [], "Invalid preflight must not write destination data")
    try expectEqual(checkpoints.changes, [], "Invalid preflight must not checkpoint state")
}

private func sourceReferences(_ source: MigrationSource) -> [Data] {
    source.deletedReferences
}

private func expectMigrationError(
    _ expected: KeychainMigrationError,
    _ body: () throws -> Void
) throws {
    do {
        try body()
    } catch let error as KeychainMigrationError {
        try expectEqual(error, expected, "Wrong migration failure")
        return
    } catch {
        try fail("Expected KeychainMigrationError")
    }
    try fail("Expected KeychainMigrationError, but no error was thrown")
}
