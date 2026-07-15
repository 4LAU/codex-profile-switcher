# Keychain Data Protection Migration: Wave 2

This serialized Wave 2 plan builds an explicit, app-only legacy Keychain migration. It never runs during launch, refresh, profile switching, usage polling, or a normal CLI command. Every automated check uses fake vaults and temporary homes only.

## Task 1: Build the verified migration coordinator

Touch only these files:

- `Sources/CodexProfileCore/Auth/KeychainAuthVault.swift`
- `Sources/CodexProfileCore/Auth/DataProtectionKeychainAuthVault.swift`
- `Sources/CodexProfileCore/Auth/KeychainMigrationCoordinator.swift` (new)
- `Tests/AuthBlobTests/KeychainMigrationCoordinatorTests.swift` (new)
- Directly related additions under `Tests/AuthBlobTests/`

Add an internal migration-only legacy source that captures all matching legacy-service records in one interactive query. Each capture contains a profile ID, auth bytes, and opaque persistent reference, but neither bytes nor references may be exposed to UI, logs, diagnostics, or public preview values. Reject duplicate IDs, invalid IDs, invalid auth blobs, missing fields, a source that contradicts a `complete` checkpoint, and a different existing v2 value before any write or deletion.

The coordinator returns a one-use, secret-free preview ordered by profile ID. Each candidate has its ID, configured label or `Unconfigured saved account`, and migration status. It accepts only the preview's exact candidate count as approval. For every legacy candidate: use an identical existing v2 copy or an atomic create-if-absent operation, then require byte-equal readback; persist `copied_cleanup_pending`; revalidate the captured legacy bytes and delete only its captured persistent reference; require another byte-equal v2 readback; then persist `complete`. A failed delete or final readback stays `copied_cleanup_pending`; save, readback, or checkpoint failures prevent deletion. Never roll back a verified v2 copy. A retry requires a fresh explicit preflight. A pending record whose legacy source was already deleted after a final-checkpoint failure is shown only in a later explicit review, re-verifies v2 data, and may then checkpoint `complete` without a deletion target.

Use fake source, destination, and checkpoint closures in hermetic tests. Cover ordering, labels, duplicate/invalid/stale preflight failure, count mismatch, atomic-create collision, save/readback failure, checkpoint failure, changed-source rejection before deletion, delete failure, final readback failure, final-checkpoint recovery, conflicting existing v2 bytes, one-use and reentrant sessions, and exact-reference deletion. Do not construct `LegacyKeychainAuthVault` in a test or perform `SecItem` operations. Finish with focused tests, `./build.sh`, and `git diff --check`. Do not commit.

## Task 2: Add an explicit ProfileStore migration boundary

Depends on Task 1. Touch only these files:

- `Sources/CodexProfileSwitcherApp/ProfileStore.swift`
- `Tests/ProfileStoreEnvironmentTests/ProfileStoreEnvironmentTests.swift`

Expose review, confirm, and cancel methods for Settings. Only `review` may construct `LegacyKeychainAuthVault(interactionAllowed: true)`, and only when the selected primary vault reports `.dataProtectionKeychain`. Retain the coordinator session solely while a review is pending, persist each state checkpoint immediately through the existing config write path, and discard the session on cancel, error, or completion. Preserve custom vault injection with a coordinator factory seam for hermetic tests.

Prove app initialization, refresh, profile switching, and usage-source creation never construct or invoke the factory. Prove an explicit review has no deletion before confirmation, a mismatched confirmation count does not mutate either fake vault, and a cleanup failure is surfaced with a durable pending state. Run focused tests, `./build.sh`, and `git diff --check`. Do not commit.

## Task 3: Put migration behind a Settings confirmation

Depends on Task 2. Touch only these files:

- `Sources/CodexProfileSwitcherApp/SettingsViews.swift`
- `Sources/CodexProfileSwitcherApp/AppDelegate.swift`
- `Sources/CodexProfileCLI/CodexProfileCLI.swift`
- `Tests/run-integration-tests.sh`

Add a General-tab Keychain Migration section. Its sole entry point is an explicit `Review Legacy Keychain Copies…` button. After preflight, present a sheet that lists every candidate label and profile ID, says exactly `Move and remove N legacy Keychain copies`, and offers Cancel or the destructive action. A zero-candidate review does not offer deletion. Pending-cleanup rows remain visible on a later explicit review and can be retried only through another confirmation. Do not add a menu item, launch prompt, background action, or automatic cleanup.

Keep `keychain-repair` as a backward-compatible CLI command that refuses before any legacy Keychain access and directs people to Settings; no terminal, TTY, or headless CLI migration is part of this wave. Update the hermetic integration check to assert that the command changes neither config nor file-vault data, and that no normal command gained a legacy fallback. Finish with focused checks, `./build.sh`, and `make check`. Do not commit.

## Task 4: Prove the Wave 2 negative paths and review the combined change

Depends on Tasks 1 through 3. Touch only directly related hermetic tests from Tasks 1 through 3 when a missing safety assertion is found.

Run the complete coordinator failure matrix and the app/CLI negative-path checks together. Confirm that the only `LegacyKeychainAuthVault` construction added by this wave is inside the explicit ProfileStore review action, that no preview or log contains auth bytes, persistent references, or fingerprints, and that no test reaches macOS Keychain. Run `./build.sh`, `make check`, and `git diff --check`. Report status and changed files without committing.

## Execution Log

- PLAN START 2026-07-14: base: `program/keychain-data-protection-migration`, base_sha: `c8b494434c24aa6b139d23d593f9779a5b15c433`, branch: `plan/keychain-data-protection-migration-wave-2`, worktree: `/Users/aaron/Code/codex-profile-switcher-3001-worktree2`, port: none
- PLAN AMENDMENT 2026-07-14: Task 1 adds atomic v2 creation, legacy source revalidation, reentrant-session consumption, and explicit final-checkpoint recovery after code-quality review identified concurrency and recovery gaps.
