# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/).

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
