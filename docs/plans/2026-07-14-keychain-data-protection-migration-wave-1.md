# Keychain Data Protection Migration: Wave 1

This is the serialized Wave 1 plan for the approved program manifest. Every task is intentionally unmarked: the credential surfaces overlap and write provenance is not isolated per worker.

## Task 1: Create the entitlement-gated Data Protection vault foundation

Touch only these files:

- `Sources/CodexProfileCore/Auth/AuthVault.swift`
- `Sources/CodexProfileCore/Auth/DataProtectionKeychainAuthVault.swift` (new)
- `Sources/CodexProfileCore/Auth/KeychainAccessGroupResolver.swift` (new)
- `Sources/CodexProfileCore/Auth/ProcessSigningIdentity.swift`
- `Sources/CodexProfileCore/Auth/KeychainAuthVault.swift`
- `Sources/CodexProfileCore/Profiles/AppConfig.swift`
- New or directly related hermetic tests under `Tests/AuthBlobTests/`

Build a fixed v2 Data Protection Keychain destination for `W3ZHLSH96F.com.4lau.codex-profile-switcher.auth-v2`. Its queries must include `kSecUseDataProtectionKeychain`, the exact access group, the existing service and account keys, `kSecAttrSynchronizable = false`, and `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` for new items. Add a resolver that accepts only the exact signed `keychain-access-groups` entitlement and is testable without the real Keychain. Replace the incorrect stable-legacy-ACL claim with the entitlement capability check.

Extend diagnostics and configuration with backward-compatible per-profile migration state, without a global completion flag. Preserve the legacy vault as a compatibility source only. Do not invoke it, create a legacy ACL item, create a recovery file, or access a real Keychain in tests. Tests must guard silent credential-safety failures, use fakes or query construction only, and show the failure before the implementation changes make them pass.

Finish by running the focused tests and `swift build`. Report `DONE`, `DONE_WITH_CONCERNS`, `NEEDS_CONTEXT`, or `BLOCKED`, and list changed files. Do not commit.

## Task 2: Route all ordinary paths to the primary vault

Depends on Task 1. Touch only these files:

- `Sources/CodexProfileSwitcherApp/ProfileStore.swift`
- `Sources/CodexProfileSwitcherApp/UsageProvider.swift`
- `Sources/CodexProfileCLI/CodexProfileCLI.swift`
- Directly related hermetic tests under `Tests/ProfileStoreEnvironmentTests/` and `Tests/run-integration-tests.sh`

Release-shaped binaries with the exact entitlement use the Data Protection vault. Unsigned and signed-but-unentitled binaries use the isolated file vault. Normal app startup, menu refresh, usage polling, switching, login, status, best-auth, import-auth, lease operations, and non-TTY commands must not construct or read the legacy vault.

Remove automatic ACL repair calls from every ordinary path. Do not add a migration command or UI in this wave. Keep the existing disk-auth migration separate. Preserve current file-vault integration behavior and credential rollback safety. Add only hermetic coverage for silent failures, and do not reach the real Keychain. Finish with focused checks and `./build.sh`; report status and changed files without committing.

## Task 2A: Keep generic profile writes from completing disk-auth migration

Depends on Task 2. Touch only these files:

- `Sources/CodexProfileCore/Profiles/ProfileTransactionService.swift`
- `Tests/run-integration-tests.sh`

Remove the generic `authStorageVersion` initialization or advancement from `saveActiveProfile` and `ensureProfiles`. Only a verified, completed disk-auth migration may mark that migration complete. Add a hermetic file-vault CLI regression that seeds a legacy disk credential, performs a normal login, and proves both that the config remains incomplete and the legacy source file remains. Do not access the real Keychain. Finish with the focused integration check and `./build.sh`; report status and changed files without committing.

## Task 2B: Make the primary vault diagnostic unambiguous

Depends on Task 2. Touch only these files:

- `Sources/CodexProfileCore/Auth/AuthVault.swift`
- `Sources/CodexProfileCore/Auth/DataProtectionKeychainAuthVault.swift`
- `Sources/CodexProfileCLI/CodexProfileCLI.swift`
- New or directly related hermetic tests under `Tests/AuthBlobTests/`

Give Data Protection Keychain its own `AuthVaultBackend` value instead of reporting it as `custom`. Keep other custom vault behavior unchanged. Make CLI diagnostics and login output identify this backend as Data Protection Keychain. Add a hermetic check for the vault diagnostic without accessing the real Keychain. Finish with focused checks and `./build.sh`; report status and changed files without committing.

## Task 3: Prove the Wave 1 safety contract in the hermetic suite

Depends on Tasks 2A and 2B. Touch only these files:

- `Tests/AuthBlobTests/KeychainRepairTests.swift` and new directly related test files
- `Tests/ProfileStoreEnvironmentTests/ProfileStoreEnvironmentTests.swift`
- `Tests/ProfileStoreEnvironmentTests/ProfileTransactionRollbackTests.swift` when a silent regression needs coverage
- `Tests/run-integration-tests.sh`

Replace obsolete repair assertions with deterministic fake- or file-vault checks. Prove that resolver mismatch routes to the file vault, that Data Protection query construction carries the fixed security fields, that migration state survives config encode and decode, and that ordinary paths do not access a supplied legacy-vault fake. Preserve any existing test that still guards a silent account or auth corruption failure.

Run the focused tests, then `./build.sh` and `make check`. Do not add a test that accesses macOS Keychain. Report status and changed files without committing.

## Execution Log

- PLAN START 2026-07-14: base: `program/keychain-data-protection-migration`, base_sha: `879ad77b3461e91bfa62cc3c721f18fdcacbfe33`, branch: `plan/keychain-data-protection-migration-wave-1`, worktree: `/Users/aaron/Code/codex-profile-switcher-3001-worktree1`, port: none
- PLAN AMENDMENT 2026-07-14: after L approved the escalation, Task 2A moved `ProfileTransactionService.swift` and its hermetic file-vault migration regression into Wave 1. Task 2B makes the Data Protection Keychain diagnostic explicit before the Wave 1 contract is tested.
