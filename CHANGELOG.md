# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/).

## Unreleased

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
