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
| `CodexProfileCLI` | CLI helper for login, app switching, status, diagnostics, and scripted rotation (`best-auth`, `exec`, `import-auth`, `lease`) |
| `CodexProfileCore/Auth` | Auth token parsing plus Keychain and file-backed vaults |
| `CodexProfileCore/Profiles` | Shared config, paths, validation, and profile switch transactions |
| `CodexProfileCore/Usage` | UI-independent usage fetching via Codex JSON-RPC, profile selection, and best-auth reporting |
| `CodexProfileCore/Support` | Shared low-level helpers such as atomic file writes, the cross-process cache lock, redaction, and core log forwarding |
| `CodexProfileSwitcherApp/AppDelegate.swift` | Menu bar lifecycle, status item ownership, refresh timers, and action dispatch |
| `CodexProfileSwitcherApp/AppInfo.swift` | App version and bundle metadata |
| `CodexProfileSwitcherApp/AppLogging.swift` | App-side log configuration and redaction setup |
| `CodexProfileSwitcherApp/ProfileModels.swift` | View-layer profile and usage model types |
| `CodexProfileSwitcherApp/ProfileStore.swift` | `@MainActor` profile state store — loads, saves, and publishes profile config |
| `CodexProfileSwitcherApp/UsageProvider.swift` | `@MainActor` usage coordinator — schedules refreshes and merges snapshots |
| `CodexProfileSwitcherApp/CodexBridge.swift` | Launches `codex app-server` and translates its JSON-RPC responses |
| `CodexProfileSwitcherApp/DebugInfoBuilder.swift` | Assembles redacted debug info for clipboard copy |
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

Usage data is fetched via a single path: Codex's own `app-server` JSON-RPC endpoint. The CLI or app launches `codex app-server` in a temporary profile-scoped environment and reads quota from its JSON-RPC response. There is no direct OpenAI usage API call and no OAuth refresh on poll.

The app coordinates refresh state through an app-local `UsageProvider` (`@MainActor`). Profile config is owned by `ProfileStore` (`@MainActor`). UI-independent fetching and profile selection logic live in `CodexProfileCore/Usage`.

The `best-auth` CLI command runs the same fetch path independently (bounded concurrency of 3) so it never relies solely on a stale cache when the menu bar app is not running.

## Scripted Account Rotation

The CLI exposes the same usage-aware selection the app uses, for scripts and agents that drive Codex without the menu bar:

- `best-auth` writes the best profile's credentials into a directory you point `CODEX_HOME` at.
- `exec` wraps one command and retries it on the next-best profile when it hits a usage limit.
- `lease` holds an account open for a warm Codex session and rotates the credential underneath it on a limit, so the session is never restarted.

`lease` records each reservation in the shared usage cache (`~/.codex-switcher/usage-cache.json`) as a TTL-bounded entry, and every other selector skips a reserved account, so concurrent agents never collide on one profile. The CLI and the menu bar app both read and write that cache, so each whole-cache update runs inside a cross-process advisory lock: a writer reads, mutates, and atomically replaces the file while holding the lock, and a concurrent writer can never drop a just-committed reservation. Disk is authoritative for the lease map, which stops the long-lived app from resurrecting a reservation that a short-lived CLI run already released.

## Security

- Auth tokens stored in macOS Keychain with `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`
- Log output redacts emails, bearer tokens, cookies, API keys, and OAuth fields
- No network calls except to Codex's `app-server` JSON-RPC endpoint (via a local process, authenticated per-profile)
