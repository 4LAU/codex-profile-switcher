# Startup Identity Recovery

## Decision

Codex Profile Switcher will use macOS Service Management for Launch at Login and refuse to open the production profile store from an unsigned build.

The signed application installed at `/Applications/CodexProfileSwitcher.app` remains the only menu app allowed to open production profiles. Another build may run only when `CODEX_PROFILE_HOME` or `CODEX_PROFILE_TEST_HOME` resolves to a home distinct from the user’s normal home.

## Problem

The current Launch at Login setting writes an absolute executable path to `~/Library/LaunchAgents/com.codex-profile-switcher.plist`. That path can outlive the build that created it.

On July 17, 2026, the Mac restarted and the legacy rule opened `~/.local/bin/codex-profile-switcher`. That unsigned development build correctly selected its file auth vault, but it also read the production profile configuration and usage cache. The result looked like credential loss: every profile became “Not set up” or “Re-login needed” even though the Keychain records were intact.

## Desired Behavior

At login, macOS opens the signed installed application. Updates and bundle replacement must not leave startup tied to an old inner executable.

If an unsigned build starts against the normal user home, it must stop before `ProfileStore` is created. When a valid signed installation is available, it opens that application, explains the correction once, and exits. When no valid installation is available, it explains what is wrong and exits without displaying profile state.

Actual Keychain failures keep their current explicit error handling. Recovery never copies, edits, or deletes credentials.

## Startup Classification

`StartupIdentityGate` runs at the start of `applicationDidFinishLaunching`, after logging is configured and before any profile or auth object exists.

It produces one of three outcomes:

1. The app with the exact production Keychain capability running from the fixed installed bundle continues as the production app.
2. A process with an explicit home that canonicalizes to a location distinct from the real home continues in isolation.
3. Every other menu-app launch enters recovery and cannot create `ProfileStore`.

The classification uses the existing `ProcessSigningIdentity` capability check, the current bundle location, and the same environment keys already recognized by `AppPaths`. Standardization and symlink resolution happen before comparing an override with the real home.

This gate applies only to `CodexProfileSwitcherApp`. The CLI’s documented file-vault behavior remains unchanged because commands such as `exec`, `lease`, and `best-auth` depend on it.

## Recovery Handoff

Recovery resolves the fixed `/Applications/CodexProfileSwitcher.app` bundle before using Launch Services to open or activate it. Before opening it, the app validates the candidate with Security framework APIs:

- the code signature is valid;
- the bundle identifier is `com.4lau.codex-profile-switcher`;
- the signing team matches the team encoded in the required access group;
- the candidate has exactly `W3ZHLSH96F.com.4lau.codex-profile-switcher.auth-v2` as its Keychain access group.

Recovery never launches an app selected only by path or display name.

After validation succeeds, the development process opens the signed app with a recovery launch argument, records the correction, and exits on a short fixed timeout. The signed app opens its menu once with a brief notice stating that startup was repaired and saved profiles were unchanged. This avoids notification permission and cannot block login. If the signed app is already running, recovery activates it instead of opening another copy.

If lookup or validation fails, the development process shows an alert that directs the user to install or open the signed app from Applications. No profile menu or settings window is created.

## Launch at Login

`LaunchAtLogin` will use `SMAppService.mainApp` instead of writing a LaunchAgent property list. The Settings toggle reads the service status rather than checking for a file.

The setting has four visible states:

- enabled;
- disabled;
- awaiting approval in System Settings;
- unavailable because the current build is not the signed installed app.

When macOS requires approval, Settings keeps the attempted state visible and offers an “Open Login Items” button. Registration errors revert the toggle and show the existing settings toast or an inline error.

Builds outside `/Applications` cannot register themselves for login. Their Settings view explains that Launch at Login is managed by the installed app.

## Legacy Registration Migration

The signed app checks the single owned legacy path on startup. Registration, migration, and deletion are unavailable unless the process has the production Keychain capability and runs from `/Applications/CodexProfileSwitcher.app`. If the legacy file is absent, migration does nothing.

If the file contains the expected label and a single executable argument, its presence means Launch at Login was enabled. The app first registers `SMAppService.mainApp`. It removes the legacy property list only after the native service reports fully enabled.

If macOS is awaiting approval, the app keeps the legacy file and directs the user to Login Items. The recovery gate prevents that old rule from displaying false profile state in the meantime. A later signed launch finishes migration after approval.

If native registration fails, the legacy file remains untouched and the failure is logged. A malformed or unexpected file is never deleted automatically.

The currently loaded legacy process does not need to be forcibly terminated. A non-installed process exits through the recovery handoff, and removing the property list prevents it from returning at the next login.

Before profile initialization, the installed app also checks for an existing installed instance with the same bundle identifier and executable location. It activates that instance and terminates the newcomer, preventing two signed menu apps if legacy and native startup registrations fire together.

## Error Handling

Startup identity errors are resolved before profile state exists, so they cannot appear as “Not set up” or “Re-login needed.” Error text never includes executable arguments beyond a redacted path, signing details beyond expected public identifiers, or auth material.

Service Management failures do not change profile availability. They affect only Launch at Login and remain visible in Settings.

Keychain errors remain separate from startup identity errors. The app must not suggest relogin when it has not opened the production vault.

## Verification

The startup classification and recovery boundary are on the repository’s narrow test list because a regression can silently make intact auth appear missing. Add red-green coverage for trusted installed production, canonical isolated homes, overrides that resolve to the real home, and the recovery handoff completing without constructing `ProfileStore`.

Do not mock or test `SMAppService` itself. Apple owns that behavior. Verify integration by rebuilding first, running `make check`, packaging a signed app, and inspecting its signature and exact Keychain entitlement.

The live migration check is separate because it changes the user’s login registration. Before running it, inventory the one known legacy file, preserve a backup, and get approval. Then open the signed app, confirm native registration, confirm the legacy file is gone, restart the login session or inspect the registered service, and verify that the signed app is the selected executable.

## Execution Signals

### Component to file surface

| Component | Files |
| --- | --- |
| Startup classification and signed handoff | `Sources/CodexProfileSwitcherApp/StartupIdentityGate.swift`, `Sources/CodexProfileSwitcherApp/AppDelegate.swift` |
| Native login registration and legacy migration | `Sources/CodexProfileSwitcherApp/LaunchAtLogin.swift`, `Sources/CodexProfileSwitcherApp/AppDelegate.swift`, `Package.swift` |
| Settings state and recovery messages | `Sources/CodexProfileSwitcherApp/SettingsViews.swift` |
| Credential-safety regression coverage | `Tests/ProfileStoreEnvironmentTests/StartupIdentityGateTests.swift` |
| Public change record and development rule | `CHANGELOG.md`, `docs/DEVELOPMENT.md` |

No generated files or dependency lockfiles should change.

### Dependency edges

`StartupIdentityGate` must exist before `AppDelegate` can enforce it. Native login registration must exist before Settings can display its state. Legacy migration depends on native registration because registration must succeed before deletion. Documentation follows the final behavior.

### Irreversible or external state changes

The implementation changes no credentials, profiles, usage data, or Keychain records.

On a migrated installation, it registers one native main-app login item and removes at most one file: `~/Library/LaunchAgents/com.codex-profile-switcher.plist`. This machine currently has exactly one such file. Live verification must inventory that count again, back up the file, and obtain approval before opening a build that performs migration.

### External dependencies

The design depends on macOS 14 Service Management, Launch Services, and Security frameworks. No network service or third-party approval is required. macOS may require the user to approve the login item in System Settings.

### Estimated span

Implementation and automated verification fit in one session. The live migration check waits for explicit approval because it changes the current login registration.

## Post-Implementation

Run `staffcheck` on the complete diff and fix confirmed findings. Because this change controls access to production auth state, run `cross-challenge` in implementation review mode against the captured base SHA with `REVIEW_ONLY: true`. Apply accepted fixes through the normal verified executor, reproduce each failure case, run affected checks, audit the fix delta, and commit only verified changes.

Do not run an optional cleanup pass unless requested. The remaining manual action is installing the signed build. If macOS reports that login registration requires approval, open System Settings from the app and approve it there.
