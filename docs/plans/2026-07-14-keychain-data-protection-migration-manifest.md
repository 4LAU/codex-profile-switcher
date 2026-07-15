# Program Manifest: Keychain Data Protection Migration

---

# REGION 1: FROZEN BASELINE

> Nothing above the `END FROZEN BASELINE` marker may change after approval. Corrections, additions, and program events belong in Region 2.

- **Program:** Keychain Data Protection Migration
- **Date created:** 2026-07-14
- **Objective:** End per-release Keychain password prompts by moving release credentials to a fixed, entitlement-protected Data Protection Keychain group, with an explicit, recoverable migration for legacy ACL items.
- **base_sha:** `5b4362c1304c9fc91b722fa7d066850cabc9c1bc`

## In-Scope Inventory

| # | Item | Type | Wave | Risk | Blast radius | Expected count |
|---|---|---|---|---|---|---|
| 1 | `Sources/CodexProfileCore/Auth/AuthVault.swift` | source | 1 | high | Shared vault interface and diagnostics used by app, helper, and tests | 1 file |
| 2 | `Sources/CodexProfileCore/Auth/DataProtectionKeychainAuthVault.swift` | source, new | 1 | critical | New primary credential destination | 1 file |
| 3 | `Sources/CodexProfileCore/Auth/KeychainAccessGroupResolver.swift` | source, new | 1 | high | Decides whether a binary may use release credentials | 1 file |
| 4 | `Sources/CodexProfileCore/Auth/ProcessSigningIdentity.swift` | source | 1 | high | Must reject signed but unentitled binaries from the release vault | 1 file |
| 5 | `Sources/CodexProfileCore/Auth/KeychainAuthVault.swift` | source | 1 | critical | Legacy ACL source contains the only old credential copy before migration | 1 file |
| 6 | `Sources/CodexProfileCore/Auth/KeychainMigrationCoordinator.swift` | source, new | 2 | critical | Controls copy, verified readback, checkpointing, and exact-source cleanup | 1 file |
| 7 | `Sources/CodexProfileCore/Auth/DuplicateAwareAuthSaver.swift` | source | 2 | medium | Login must write only the primary vault | 1 file |
| 8 | `Sources/CodexProfileCore/Profiles/AppConfig.swift` | source | 1 | high | Per-profile migration state survives crashes and retry | 1 file |
| 9 | `Sources/CodexProfileCore/Profiles/ProfileTransactionService.swift` | source | 2 | high | Profile-switch rollback must retain current guarantees | 1 file |
| 10 | `Sources/CodexProfileSwitcherApp/ProfileStore.swift` | source | 2 | critical | Current startup and refresh can touch every legacy ACL item | 1 file |
| 11 | `Sources/CodexProfileSwitcherApp/UsageProvider.swift` | source | 2 | high | Background usage checks must never receive the legacy vault | 1 file |
| 12 | `Sources/CodexProfileSwitcherApp/AppDelegate.swift` | source | 2 | high | User action and background startup wiring | 1 file |
| 13 | `Sources/CodexProfileSwitcherApp/SettingsViews.swift` | source | 2 | high | Native confirmation and retry UI for legacy cleanup | 1 file |
| 14 | `Sources/CodexProfileSwitcherApp/MenuViews.swift`, `ProfileHealth.swift`, `ProfileModels.swift`, `DebugInfoBuilder.swift`, `CodexBridge.swift` | source | 2 and 4 | high | Menu status, redacted diagnostics, and helper routing must agree | 5 files |
| 15 | `Sources/CodexProfileCLI/CodexProfileCLI.swift` | source | 2 | critical | Non-TTY commands must stay prompt-free; migration must be deliberate | 1 file |
| 16 | `CodexProfileSwitcher.entitlements` | entitlement | 3 | critical | Main app must hold the exact v2 access group | 1 file |
| 17 | `CodexProfileHelper.entitlements` | entitlement | 3 | critical | Helper must hold the same v2 access group with its own app identifier | 1 file |
| 18 | `Scripts/package_app.sh` | packaging | 3 | critical | Embeds profiles, uses separate IDs, signs nested helper first, and proves final entitlements | 1 script |
| 19 | `Scripts/release_app.sh` | release | 3 | high | Must stop before DMG, appcast, Homebrew, or publication when profile validation fails | 1 script |
| 20 | `Scripts/keychain_signed_smoke.sh` | manual validation | 3 | high | Disposable-service proof for app-helper sharing, repackage continuity, and explicit migration | 1 script |
| 21 | `Makefile` | build guidance | 3 | medium | Loose CLI guidance must not promise release-vault access | 1 file |
| 22 | `Tests/AuthBlobTests/KeychainRepairTests.swift` | hermetic test | 1 | medium | Replace repair-only expectations with silent credential-safety invariants | 1 file |
| 23 | `Tests/ProfileStoreEnvironmentTests/ProfileStoreEnvironmentTests.swift`, `ProfileTransactionRollbackTests.swift`, `Tests/run-integration-tests.sh` | hermetic test | 1 and 2 | high | Fake-vault migration, no-background-legacy-access, and rollback behavior | 3 test areas |
| 24 | `README.md`, `docs/DEVELOPMENT.md`, `docs/RELEASING.md`, `docs/architecture.md`, `docs/testing-policy.md`, `CHANGELOG.md` | documentation | 4 | medium | Public claims and release procedure must match entitlement-protected storage | 6 files |
| 25 | Runtime deletion of legacy ACL items | user data | 3 | critical | Only the approved legacy copies for one explicit migration session may be removed | **0 during this program.** Each future user-run migration must establish and show its own exact count before deletion. |

## Required Runtime Deletion Inventory

The program does not inspect or delete any real Keychain item. The feature it builds may delete a legacy item only after all conditions below are true in one explicit migration session:

1. Preflight has built a deterministic, deduplicated ordered list of valid legacy records for the legacy service. Each row contains a profile ID, its display label or `Unconfigured saved account`, status, and an opaque in-memory reference. It never contains secret bytes, a fingerprint, or Keychain internals.
2. The confirmation sheet shows every row and says `Move and remove N legacy Keychain copies`, where `N` equals the distinct candidate count.
3. The approved count, candidate count, and deletion-target count match exactly. A duplicate, stale source, unreadable item, invalid ID, or mismatch stops the run before deletion.
4. For each approved item, the source has been read interactively, validated by `AuthBlob.isPlausibleAuthBlob`, copied to the v2 vault, read back with byte equality, and checkpointed as `copied_cleanup_pending`.
5. Cleanup deletes only the captured record, then re-reads the v2 item and checkpoints `complete`. A failed cleanup stays `copied_cleanup_pending` and is retried only by another explicit migration action.

The verified v2 copy and readback are the restorable backup. No plaintext recovery file is permitted.

## Out of Scope

- Reading, listing, exporting, backing up, or changing a person’s real Keychain data during development, tests, or this audit.
- Another legacy-ACL repair release, automatic migration, launch-time cleanup, refresh-time cleanup, profile-switch fallback, or headless CLI migration.
- Creating Apple Developer portal resources, provisioning profiles, certificate changes, notarization, public release publication, appcast changes, or Homebrew publication. These need separate authority after the code is ready.
- iCloud Keychain synchronization, a change to Codex `auth.json`, or a migration of legacy disk auth under `~/.codex-switcher/auth`.
- Sparkle code changes. Sparkle is a release validation surface only.
- Provisioning profiles, certificates, credentials, temporary recovery files, app bundles, logs, and the existing untracked `docs/keychain-migration-plan.html` planning artifact.

## External Prerequisites

Before an official release can use this feature, the Apple Developer account for team `W3ZHLSH96F` must provide two Developer ID distribution provisioning profiles outside this repository:

- App ID `com.4lau.codex-profile-switcher`.
- Helper ID `com.4lau.codex-profile-switcher.helper`.
- Keychain Sharing enabled for both, authorizing only `W3ZHLSH96F.com.4lau.codex-profile-switcher.auth-v2`.

The release machine must also hold the existing Developer ID Application certificate. Official packaging will fail without these inputs. Loose development binaries and loose Developer ID CLI binaries without the entitlement must use the isolated file vault.

## Wave Plan

| Wave | Contents | Risk level | Reversible? | Gate criteria |
|---|---|---|---|---|
| 1 | Primary Data Protection vault, entitlement resolver, legacy-source isolation, per-profile state model, and hermetic credential-safety coverage. No UI or CLI action can trigger migration. | high | yes | `./build.sh`, `make check`, and fake-vault verification prove normal paths make zero legacy calls; no real Keychain access. |
| 2 | Explicit migration coordinator and app/helper UX and CLI integration. Legacy reads and cleanup exist only behind an interactive confirmation backed by the exact inventory contract above. | high | yes for this program, runtime cleanup is intentionally irreversible | Gate 1 still passes; hermetic failure matrix proves no delete before verified v2 copy and durable checkpoint; all ordinary app and non-TTY CLI paths stay legacy-free. |
| 3 | Entitlements, profile-aware packaging and release preflight, separate helper identifier, manual disposable-service smoke support, and exact runtime deletion guardrails. This is the last wave that can enable legacy cleanup. | critical | code changes yes, user data cleanup no | Both profile files available and metadata-only preflight passes; signed app-helper smoke uses disposable records only; every legacy delete has a verified v2 backup and exact approved inventory. No publication. |
| 4 | Documentation closeout, release notes, developer guidance, and program cleanup. | low | yes | Docs match implemented behavior; manifest log records all gates; every recorded worktree is reaped. |

**Baseline approved by L:** `2026-07-14`

<!-- ===================== END FROZEN BASELINE ===================== -->

---

# REGION 2: AMENDMENT + GATE LOG

> Append only. Each entry has a date and an explicit approval marker. A WAVE START without a later GATE RESULT means the wave is in flight and must be recovered from Git state before more work begins.

### `2026-07-14`: BASELINE APPROVAL

- **Decision:** L approved the frozen baseline and authorized Wave 1 planning.
- **Approved by L:** `2026-07-14`
- **Logged by:** orchestrator.

### `2026-07-14`: AMENDMENT

- **Change:** Move `Sources/CodexProfileSwitcherApp/ProfileStore.swift`, `Sources/CodexProfileSwitcherApp/UsageProvider.swift`, and `Sources/CodexProfileCLI/CodexProfileCLI.swift` from Wave 2 to Wave 1.
- **Reason:** The Wave 1 gate requires ordinary app and CLI paths to make zero legacy-vault calls. These three files select or consume the normal credential backend, so leaving them in Wave 2 would make that gate impossible to prove.
- **Approved by L:** `2026-07-14`
- **Logged by:** orchestrator.

### `2026-07-14`: WAVE START

- **Wave:** 1.
- **Worktree path:** `/Users/aaron/Code/codex-profile-switcher-3001-worktree1`
- **Plan branch:** `plan/keychain-data-protection-migration-wave-1`
- **Base branch:** `program/keychain-data-protection-migration`
- **Dev-server port:** none.
- **Approved by L:** `2026-07-14`
- **Logged by:** orchestrator.

### `2026-07-14`: AMENDMENT

- **Change:** Add `Sources/CodexProfileCore/Auth/DataProtectionKeychainAuthVault.swift` to Wave 2 Task 1 for a migration-only atomic create-if-absent operation. Require legacy capture byte revalidation immediately before exact-reference deletion. Add explicit recovery for a durable pending checkpoint whose source was already deleted but whose final `complete` checkpoint failed.
- **Reason:** The initial coordinator review found a concurrent v2 write could be overwritten, a changed legacy record could be deleted through its stable persistent reference, and a final checkpoint failure could leave a recoverable pending state with no review path.
- **Approved by L:** not required; this stays within existing approved Wave 1 and Wave 2 inventory and does not change wave assignment.
- **Logged by:** orchestrator.

### `2026-07-14`: AMENDMENT

- **Change:** Clarify the Wave 2 Settings flow: the destructive confirmation lists only live legacy captures, so its displayed candidate, approval, and deletion-target counts remain equal. A `copied_cleanup_pending` record whose source was already deleted after a final-checkpoint failure appears in a later explicit review with a separate non-destructive completion confirmation.
- **Reason:** The final-checkpoint recovery has no deletion target and cannot share the frozen exact-count destructive confirmation.
- **Approved by L:** not required; this stays within approved Wave 2 behavior and does not change wave assignment.
- **Logged by:** orchestrator.

### `2026-07-14`: AUDIT COMPLETE

- **Scope evidence:** Current production storage is `LegacyKeychainAuthVault`, which creates trusted-application ACLs with `SecTrustedApplicationCreateFromPath`. `ProfileStore` invokes ACL repair at startup. The CLI invokes repair on ordinary interactive paths. Both entitlement files are empty, package output embeds no profile, and the nested helper currently has the same bundle identifier as the app.
- **Safety evidence:** The current repair path makes plaintext recovery files under `~/.codex-switcher/tmp/keychain-repair-recovery`; the new migration must not use it. The removed historical `MigratingAuthVault` performed automatic activation-time cleanup and must not be restored verbatim.
- **No user data touched:** confirmed. The audit inspected repository code and safe local signing metadata only.
- **Approved by L:** not required, read-only audit.
- **Logged by:** orchestrator.

### `2026-07-14`: ESCALATION

- **Trigger:** Wave 1 Task 2 code-quality review found that `ProfileTransactionService.saveActiveProfile` and `ensureProfiles` advance `authStorageVersion` for file-vault login. An entitled build can then skip its disk-auth migration and remove the remaining legacy disk credentials.
- **Action:** Halted Wave 1 before Task 3. Preserved the unmerged worktree at `/Users/aaron/Code/codex-profile-switcher-3001-worktree1`, branch `plan/keychain-data-protection-migration-wave-1`, last committed task `27a1c54`.
- **Proposed amendment:** Move `Sources/CodexProfileCore/Profiles/ProfileTransactionService.swift` from Wave 2 to Wave 1, and add its hermetic regression to the existing Wave 1 test surfaces. `AuthVault.swift` is already in Wave 1 and will also replace its ambiguous custom backend diagnostic with a dedicated Data Protection backend value.
- **Resolution / approval:** pending L approval.
- **Logged by:** orchestrator.

### `2026-07-14`: AMENDMENT

- **Change:** Move `Sources/CodexProfileCore/Profiles/ProfileTransactionService.swift` from Wave 2 to Wave 1. Add a hermetic file-vault regression proving that a normal login cannot mark legacy disk credentials migrated or remove their source file. In the existing Wave 1 auth surface, replace the ambiguous `custom` Data Protection Keychain diagnostic with a dedicated backend value.
- **Reason:** Generic config writes could falsely mark an incomplete disk-auth migration as complete, allowing a later entitled build to delete the remaining source credentials.
- **Approved by L:** `2026-07-14`
- **Logged by:** orchestrator.

### `2026-07-14`: WAVE START

- **Wave:** 1 (resumed after approved escalation)
- **Worktree:** `/Users/aaron/Code/codex-profile-switcher-3001-worktree1`
- **Plan branch:** `plan/keychain-data-protection-migration-wave-1`
- **Base branch:** `program/keychain-data-protection-migration`
- **Port:** none
- **Logged by:** orchestrator.

### `2026-07-14`: AMENDMENT

- **Change:** Add a small shared primary-vault selector in existing Wave 1 auth code, route the app and CLI through it, and test that a rejected exact-access-group resolution selects the file vault.
- **Reason:** The Wave 1 gate requires a direct hermetic proof of entitlement rejection routing. Existing independently passing resolver and unsigned-process tests did not connect those two facts.
- **Approved by L:** not required; this stays within the approved Wave 1 inventory and does not change wave assignment.
- **Logged by:** orchestrator.

### `2026-07-14`: GATE RESULT

- **Wave:** 1
- **Result:** checks passed; authorization for Wave 2 is pending L approval.
- **Checks:** final whole-wave specification and code-quality reviews approved; `./build.sh` and `make check` passed on merged program branch; `git diff --check` passed.
- **Safety evidence:** The hermetic suite proves a wrong `keychain-access-groups` value routes to the file vault, ordinary unentitled app and CLI paths use the file vault, and `CODEX_PROFILE_FORCE_KEYCHAIN` cannot bypass that route. No automated test invokes a `SecItem` operation. Static inspection found no `LegacyKeychainAuthVault` construction in normal app or CLI sources; the legacy repair method remains only as fail-closed compatibility API.
- **Approval to begin Wave 2:** pending L approval.
- **Logged by:** orchestrator.

### `2026-07-14`: GATE APPROVAL

- **Decision:** L approved the Wave 1 gate and authorized Wave 2 planning and execution.
- **Approved by L:** `2026-07-14`
- **Logged by:** orchestrator.

### `2026-07-14`: WAVE START

- **Wave:** 2
- **Worktree:** `/Users/aaron/Code/codex-profile-switcher-3001-worktree2`
- **Plan branch:** `plan/keychain-data-protection-migration-wave-2`
- **Base branch:** `program/keychain-data-protection-migration`
- **Port:** none
- **Approved by L:** `2026-07-14`
- **Logged by:** orchestrator.
