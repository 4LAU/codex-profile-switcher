# Architecture

## Overview

Codex Profile Switcher is a macOS menu bar app that lets users switch between multiple OpenAI Codex accounts. It operates alongside the standard Codex Desktop app without modifying its internals.

## Core Concept: Auth Swap

Codex Desktop uses a single `~/.codex/auth.json` file for authentication. This app stores per-profile auth blobs in macOS Keychain and swaps the active profile's auth into that file when switching.

```
macOS Keychain
  Profile 1 auth blob ─┐
  Profile 2 auth blob  │  swap on switch
  Profile 3 auth blob  │──────────────────> ~/.codex/auth.json
  ...                  ─┘

~/.codex-switcher/config.json   (profile labels, active profile)
```

## Components

| Target or path | Role |
|---|---|
| `CodexProfileSwitcherApp` | SwiftUI menu bar app, usage polling, settings UI |
| `CodexProfileCLI` | CLI helper for login, app switching, status, and diagnostics |
| `CodexProfileCore/Auth` | Auth token parsing plus Keychain and file-backed vaults |
| `CodexProfileCore/Profiles` | Shared config, paths, validation, and profile switch transactions |
| `CodexProfileCore/Usage` | UI-independent usage API, OAuth refresh, Codex CLI resolver, and JSON-RPC fallback |
| `CodexProfileCore/Support` | Shared low-level helpers such as atomic file writes, redaction, and core log forwarding |
| `CodexProfileSwitcherApp/AppDelegate.swift` | Menu bar lifecycle, status item ownership, refresh timers, and action dispatch |
| `CodexProfileSwitcherApp/MenuViews.swift` | Menu card views and usage display helpers |
| `CodexProfileSwitcherApp/SettingsViews.swift` | Settings window and profile management UI |

## Profile Switch Flow

`ProfileTransactionService` owns the auth transaction used by the helper:

1. Read and classify the current live auth.
2. Refuse unreadable, unmanaged, or ambiguous live auth.
3. Quit the running Codex instance at the CLI boundary.
4. Save outgoing profile auth back to the vault.
5. Restore selected profile auth to `~/.codex/auth.json`.
6. Update `~/.codex-switcher/config.json`.
7. Relaunch Codex.

## Usage Polling

The app coordinates refresh state through an app-local `UsageProvider`. UI-independent clients live in `CodexProfileCore/Usage`: OAuth profiles can refresh their tokens, the direct usage API fetcher reads OpenAI usage data, and the Codex JSON-RPC fallback runs `codex app-server` in a temporary environment when needed.

## Security

- Auth tokens stored in macOS Keychain with `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`
- Log output redacts emails, bearer tokens, cookies, API keys, and OAuth fields
- No network calls except to OpenAI's usage API (authenticated per-profile)
