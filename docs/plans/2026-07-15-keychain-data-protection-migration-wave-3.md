# Keychain Data Protection Migration: Wave 3

This serialized Wave 3 plan completes the entitlement and packaging boundary that makes the v2 Data Protection Keychain the release-only credential store. It may add code capable of performing a later user-approved migration, but it never runs a real migration, inspects a real credential, packages an official release, or publishes anything. Every automated check remains Keychain-free.

## Task 1: Isolate the signed smoke service at the v2 vault boundary

Touch only:

- `Sources/CodexProfileCore/Auth/DataProtectionKeychainAuthVault.swift`

Add a narrowly scoped manual-smoke service override. The production default must remain exactly `com.4lau.codex-profile-switcher.auth`; the access group must remain exactly `W3ZHLSH96F.com.4lau.codex-profile-switcher.auth-v2` for every query. Accept an override only when `CODEX_PROFILE_SIGNED_SMOKE=1` and `CODEX_PROFILE_DATA_PROTECTION_KEYCHAIN_SERVICE` is nonempty and begins with the fixed manual-smoke prefix `com.4lau.codex-profile-switcher.auth.smoke.`. Otherwise ignore it and use the fixed production service. Keep the override private to this vault and add only the short comment needed to explain its disposable-record safety purpose.

Do not change legacy Keychain code, migration coordinator behavior, profile state, normal app/CLI selection, or tests. Do not call a `SecItem` API in any automated check. Run `./build.sh` and `git diff --check`. Do not commit.

## Task 2: Add release-only entitlement and provisioning-profile validation

Depends on Task 1. Touch only:

- `CodexProfileSwitcher.entitlements`
- `CodexProfileHelper.entitlements`
- `Scripts/package_app.sh`

Give the app and nested helper distinct application identifiers: `W3ZHLSH96F.com.4lau.codex-profile-switcher` and `W3ZHLSH96F.com.4lau.codex-profile-switcher.helper`. Both entitlement files must contain exactly one Keychain access group, `W3ZHLSH96F.com.4lau.codex-profile-switcher.auth-v2`.

Teach the package script to accept `--validate-release-profiles` as a metadata-only mode and to require two externally supplied profiles for a release-signing build: `CODEX_PROFILE_APP_PROVISIONING_PROFILE` and `CODEX_PROFILE_HELPER_PROVISIONING_PROFILE`. Decode profiles without importing them; validate plist syntax, team prefix, each exact application identifier, and the singleton access-group inventory. The metadata-only mode must return before downloading Sparkle, compiling, creating a bundle, signing, or writing release artifacts.

For a real release-signing build, embed the validated profile in its matching bundle, sign the helper before the app, set the helper's own bundle identifier in its `Info.plist`, and inspect the final signed entitlements of both binaries to prove their exact identifiers and singleton v2 group. A non-release/ad-hoc package must keep using empty signed entitlements so it selects the file vault. An official release build must reject a custom app or helper identifier, missing profile, malformed profile, wrong team prefix, mismatched identifier, or any extra/missing access group before producing an app bundle.

Never add a provisioning profile, certificate, bundle, or credential to the repository. Run `bash -n Scripts/package_app.sh`, `plutil -lint` on both entitlement plists, `./build.sh`, and `git diff --check`. Do not run a signed package or any Keychain operation. Do not commit.

## Task 3: Make release and loose-CLI paths fail closed

Depends on Task 2. Touch only:

- `Scripts/release_app.sh`
- `Makefile`

Make `release_app.sh` invoke the package script's metadata-only validation before it resolves notarization, creates a release directory, calls `hdiutil`, generates an appcast, generates a cask, or changes any release artifact. It must propagate the failure unchanged and then invoke normal packaging only after validation succeeds. Do not add a bypass for release profile validation.

Update the Makefile guidance so its installed loose Developer ID CLI is explicitly file-vault-only without the packaged helper's Keychain Sharing entitlement. Do not add entitlements to the loose CLI target and do not change any normal CLI behavior.

Run `bash -n Scripts/release_app.sh`, `make check`, and `git diff --check`. Do not invoke the release script, package a signed app, change an appcast, or access Keychain. Do not commit.

## Task 4: Replace the Keychain smoke path with a manual disposable-record proof

Depends on Tasks 1 through 3. Touch only:

- `Scripts/keychain_signed_smoke.sh`

Make this a deliberately manual smoke script. It must require an already built, Developer ID-signed app bundle and never invoke `package_app.sh`; verify the app and nested helper signatures, identifiers, and exact v2 entitlement inventory before it can proceed. Create a unique service beginning with `com.4lau.codex-profile-switcher.auth.smoke.`, set both required smoke environment variables, and fail if a caller supplies a non-disposable service. Exercise only the signed app/helper's v2 data through fake Codex input and a temporary home.

Prove helper writes are readable by the app-side path, app-side writes are readable by the helper, and a subsequent signed repackage can still read the same disposable records. Add explicit cleanup through the entitled helper for every disposable profile and retain the existing `trap` only as a best-effort final cleanup. Do not create, read, mutate, or repair any legacy ACL item; remove the legacy ACL interop path entirely. Do not print credential data, persistent references, or a Keychain item inventory. The script may display its disposable service and an instruction that interactive macOS consent is expected once for the disposable record.

Run `bash -n Scripts/keychain_signed_smoke.sh`, `./build.sh`, and `git diff --check`. Do not execute the smoke script or perform any `SecItem` operation in automation. Do not commit.

## Task 5: Final Wave 3 safety audit

Depends on Tasks 1 through 4. Touch no files unless a directly related safety defect is found and then touch only the Task 1–4 allowlist.

Confirm the changed-file inventory equals the six frozen Wave 3 files plus the one approved added vault file: app entitlement, helper entitlement, package script, release script, smoke script, Makefile, and `DataProtectionKeychainAuthVault.swift`. Confirm no profile/certificate/artifact/appcast or real-Keychain test was added. Check that the override is smoke-gated and prefix-restricted, release validation precedes all release side effects, both final-signature checks demand the exact singleton access group, the helper has its distinct identifier, normal/ad-hoc package entitlements are empty, and the smoke script does not touch legacy services.

Run `./build.sh`, `make check`, `bash -n Scripts/package_app.sh Scripts/release_app.sh Scripts/keychain_signed_smoke.sh`, `plutil -lint CodexProfileSwitcher.entitlements CodexProfileHelper.entitlements`, `git diff --check`, and a metadata-only validation failure check with missing profiles that proves it creates no bundle or release artifact. Do not run signed packaging, the smoke script, a migration, release publication, or a Keychain operation. Report the evidence and changed-file inventory without committing.

## Execution Log

- PLAN START 2026-07-15 — base: `program/keychain-data-protection-migration`, base_sha: `83c0910626ba6e0298de18ecbfb9df11b6f5a16a`, branch: `plan/keychain-data-protection-migration-wave-3`, worktree: `/Users/aaron/Code/codex-profile-switcher-3001-worktree3`, port: none.
