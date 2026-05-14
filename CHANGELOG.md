# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/).

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
