# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/).

## Unreleased

### Added

- `best-auth` now fetches live usage (Codex app-server, bounded concurrency) before ranking, instead of relying on the menu bar app's cached usage file. When the app isn't running it no longer silently picks alphabetically off a stale/empty cache. Per-profile fetch failures fall back to the cached snapshot, and fresh snapshots are merged back into the cache.
- `best-auth --json` emits a stable machine-readable report (`selected`, `tier`, `score`, `candidates[]`, `fetched`). `status --json` and `list --json` emit structured output too. Default (non-JSON) `best-auth` output is unchanged: the bare selected profile ID.
- `best-auth` now has documented, stable exit codes: 0 selected, 2 no eligible profile, 3 no profiles configured, 4 usage data unavailable, 6 keychain interaction required, 7 watchdog timeout.

### Changed

- Usage polling now uses Codex's app-server exclusively; removes the reverse-engineered usage API client and OAuth refresh-on-poll.
- `best-auth` and `import-auth` are now official supported commands. `import-auth` exits 5 only on an identity mismatch (a refreshed credential belonging to a different account) and 1 for other failures.

### Fixed

- Fixed a potential data race between background usage refreshes and profile state.
- `best-auth` no longer hangs forever in non-interactive shells (CI, command substitution, background tasks). When stdin is not a terminal (or `--non-interactive` is passed), a Keychain read that needs interactive consent now exits with a clear message (code 6) instead of blocking on a modal prompt with no UI. A global watchdog (`--timeout`, default 30s, exit 7) guarantees the command always terminates.

## 0.2.1 -- 2026-06-04

### Fixed

- Reduced Keychain password prompts from 36 to 12 (one per profile, one-time after binary change) by eliminating redundant reads during save and refresh
- ACL repair now retries on next launch if any profiles were denied — previously a partial failure was treated as complete
- Added crash-window recovery files so credentials survive a process kill during repair
- CLI auto-repair runs before auth-reading commands (`best-auth`, `status`, `import-auth`, `login`, `app`) — no longer requires explicit `keychain-repair`

## 0.2.0 -- 2026-06-02

### Changed

- Switched from data protection Keychain to legacy ACL Keychain — `swift build` now produces a fully working binary without entitlements or provisioning profiles
- Removed `migrate` CLI command and all migration machinery

### Removed

- Data protection Keychain backend (`DataProtectionKeychainAuthVault`)
- Dual-backend migration wrapper (`MigratingAuthVault`)
- Provisioning profile discovery and embedding in `package_app.sh`
- "Migration needed" profile status in the UI

### Breaking

- Existing profiles stored in the data protection Keychain are no longer accessible — re-login each profile with `codex-profile login <name>`

## 0.1.12 -- 2026-05-30

### Added

- `best-auth` CLI command — selects the least-used configured profile and exports its credentials to a temp directory for `codex exec --ephemeral`
- `mark-exhausted` CLI command — flags a profile as rate-limited so `best-auth` skips it
- `import-auth` CLI command — imports refreshed credentials back from a temp directory with identity verification

### Fixed

- GUI app now preserves CLI-written exhaustion overrides when saving the usage cache
- Profile removal and auth clearing now clean up exhaustion overrides

## 0.1.11 -- 2026-05-29

### Added

- Show "Update to vX.Y.Z — restart now?" inline in the menu when a new version is downloaded, instead of requiring a manual check

## 0.1.10 -- 2026-05-29

### Fixed

- Fix "Unable to find Electron app" error when relaunching Codex Desktop after a profile switch (compatibility with Codex CLI 0.134+)

## 0.1.9 -- 2026-05-21

### Changed

- Reduce polite quit window from 15s to 5s before escalating to SIGTERM, making profile switches faster

## 0.1.8 -- 2026-05-21

### Fixed

- Fix crash when profile switch fails: error alert was shown on a background thread instead of the main thread
- Fix profile switch failing when Codex's app-server lingers after quit: escalate from polite quit to SIGTERM then SIGKILL

## 0.1.7 -- 2026-05-15

### Fixed

- Bring Sparkle update check windows to the front from the menu bar app

## 0.1.6 -- 2026-05-15

### Fixed

- Fix false duplicate-account detection for separate OpenAI users that share an account/workspace context
- Improve login failure messages in Settings and keep error toasts visible longer

### Added

- In-app update checking via Sparkle 2.9.1 — DMG users are notified when a new version is available
- "Check for Updates..." menu item in the status bar menu
- Appcast generation in the release pipeline for automatic update feeds

## 0.1.5 -- 2026-05-14

### Fixed

- Fix new profile defaulting to "Profile 1" instead of the next number when added from Settings

## 0.1.4 -- 2026-05-14

### Fixed

- Fix Keychain ACL discovery when CLI helper runs inside the app bundle (e.g. via Homebrew symlink) so both binaries are trusted without prompting

## 0.1.3 -- 2026-05-14

### Fixed

- Pre-authorize both the app and CLI helper in Keychain item access control lists

## 0.1.2 -- 2026-05-14

### Added

- App icon (stacked Codex visors on dark squircle)
- "Why" section in README
- Docs index in README linking architecture, development, and release guides
- Keychain Access.app troubleshooting tip for signed builds

### Changed

- Rewrite README: concise intro, Privacy section, macOS Permissions, condensed Troubleshooting
- Shorten Launch at Login description in Settings

### Removed

- CODE_OF_CONDUCT.md (unnecessary for single-maintainer utility)

## 0.1.1 -- 2026-05-14

### Fixed

- Eliminate Keychain password prompts on first launch before any account is set up
- Close remaining Keychain access leaks when all profiles are unset (menu open, sync)
- Fix pipe data truncation in CLI process output reading
- Fix incorrect "Use Re-auth" instruction for profiles that have never been set up

### Changed

- Redesign Settings Profiles tab with Apple-native master-detail layout (sidebar + detail panel)
- Auto-save profile labels on focus loss, Return, tab switch, and window close (no Save button)
- Add standard keyboard shortcuts: Cmd+Q, Cmd+H, Cmd+Option+H, Cmd+M
- Extract shared pipe-drain helper and use static ISO8601 formatters

## 0.1.0 -- 2026-05-13

### Added

- macOS menu bar app for switching between multiple Codex profiles
- 5-hour and weekly usage tracking per profile with progress bars
- Credit balance display when available
- Profile labels with custom naming
- OAuth token refresh for inactive profiles
- Launch at login support
- `codex-profile` CLI helper for login, logout, status, and diagnostics
- macOS Keychain storage for profile auth
- Log redaction for emails, bearer tokens, cookies, API keys, and OAuth fields
- Copy Debug Info, Open Log, and Report Bug from Settings
- Developer ID signed and Apple-notarized DMG distribution
- Homebrew cask via `brew install --cask 4lau/tap/codex-profile-switcher`
- Build-from-source support with `./build.sh`
