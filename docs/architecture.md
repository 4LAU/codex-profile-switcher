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
| `CodexProfileCLI` | CLI helper for login, app switching, status, diagnostics, scripted rotation (`best-auth`, `exec`, `import-auth`, `lease`), and credential renewal (`renew`) |
| `CodexProfileCore/Auth` | Auth token parsing plus Keychain and file-backed vaults |
| `CodexProfileCore/Profiles` | Shared config, paths, validation, profile switch transactions, and Codex Desktop lifecycle |
| `CodexProfileCore/Usage` | UI-independent usage fetching via Codex JSON-RPC, profile selection, and best-auth reporting |
| `CodexProfileCore/Support` | Shared low-level helpers such as atomic file writes, the cross-process cache lock, redaction, and core log forwarding |
| `CodexProfileSwitcherApp/AppDelegate.swift` | Menu bar lifecycle, status item ownership, refresh timers, and action dispatch |
| `CodexProfileSwitcherApp/AppInfo.swift` | App version and bundle metadata |
| `CodexProfileSwitcherApp/LaunchAtLogin.swift` | Registers the login item and the daily credential-renewal LaunchAgent through `SMAppService` |
| `Resources/LaunchAgents/` | The bundled renewal agent plist, copied into `Contents/Library/LaunchAgents/` at package time |
| `CodexProfileSwitcherApp/AppLogging.swift` | App-side log configuration and redaction setup |
| `CodexProfileSwitcherApp/ProfileModels.swift` | View-layer profile and usage model types |
| `CodexProfileSwitcherApp/ProfileStore.swift` | `@MainActor` profile state store — loads, saves, and publishes profile config |
| `CodexProfileSwitcherApp/UsageProvider.swift` | `@MainActor` usage coordinator — schedules refreshes and merges snapshots |
| `CodexProfileSwitcherApp/CodexBridge.swift` | Uses the shared Codex Desktop lifecycle for profile switches and translates helper responses |
| `CodexProfileSwitcherApp/DebugInfoBuilder.swift` | Assembles redacted debug info for clipboard copy |
| `CodexProfileSwitcherApp/MenuViews.swift` | Menu card views and usage display helpers |
| `CodexProfileSwitcherApp/SettingsViews.swift` | Settings window and profile management UI |

## Profile Switch Flow

`ProfileTransactionService` owns the auth transaction used by the helper:

1. Read and classify the current live auth.
2. Refuse unreadable, unmanaged, or ambiguous live auth.
3. Resolve the `com.openai.codex` installation, stop its desktop process and app-server children, and verify shutdown.
4. Save outgoing profile auth back to the vault.
5. Restore selected profile auth to `~/.codex/auth.json`.
6. Update `~/.codex-switcher/config.json`.
7. Relaunch through the bundled `codex app [workspace]` command and verify the desktop process started.

## Usage Polling

Usage data is fetched via a single path: Codex's own `app-server` JSON-RPC endpoint. The CLI or app launches `codex app-server` in a temporary profile-scoped environment and reads quota from its JSON-RPC response. There is no direct OpenAI usage API call and no OAuth refresh on poll. Each returned window includes its duration, which the menu uses for its label instead of assuming fixed five-hour and weekly slots. Missing windows are omitted.

The app coordinates refresh state through an app-local `UsageProvider` (`@MainActor`). Profile config is owned by `ProfileStore` (`@MainActor`). UI-independent fetching and profile selection logic live in `CodexProfileCore/Usage`.

The `best-auth` CLI command runs the same fetch path independently (bounded concurrency of 3) so it never relies solely on a stale cache when the menu bar app is not running.

## Scripted Account Rotation

The CLI exposes the same usage-aware selection the app uses, for scripts and agents that drive Codex without the menu bar:

- `best-auth` writes the best profile's credentials into a directory you point `CODEX_HOME` at.
- `exec` wraps one command and retries it on the next-best profile when it hits a usage limit.
- `lease` holds an account open for a warm Codex session and rotates the credential underneath it on a limit, so the session is never restarted.

`lease` records each reservation in the shared usage cache (`~/.codex-switcher/usage-cache.json`) as a TTL-bounded entry, and every other selector skips a reserved account, so concurrent agents never collide on one profile. The CLI and the menu bar app both read and write that cache, so each whole-cache update runs inside a cross-process advisory lock: a writer reads, mutates, and atomically replaces the file while holding the lock, and a concurrent writer can never drop a just-committed reservation. Disk is authoritative for the lease map, which stops the long-lived app from resurrecting a reservation that a short-lived CLI run already released.

## Credential Renewal

Codex leaves a stored credential alone while it works and reaches for its own refresh only once that credential is stale. Several of its subsystems can then attempt the refresh at the same time, each carrying the same single-use refresh token. Refresh tokens rotate, so the replays lose, and the observed result is a revoked token chain and an account that needs an interactive sign-in. The revocation mechanism is inferred from that behaviour and from upstream reports (openai/codex#10332), not directly observed.

`renew` refreshes ahead of that point. It groups profiles by refresh token and issues one request per credential group, never one per profile, so a credential shared by several profiles is refreshed once. A reservation in the shared usage cache serialises it against `exec`, `lease`, and `best-auth --dir`, so a credential in use is skipped rather than rotated underneath a live session. The write back into the Keychain checks every profile in a group before saving any, so a failure partway through cannot leave half the group holding a spent token.

The signed app registers `com.4lau.codex-profile-switcher.renew` through `SMAppService` on launch. The agent runs `codex-profile renew` at 03:00 daily and exits; nothing stays resident. `SMAppService` reports an agent that has never been registered on the machine as `notFound`, which is indistinguishable from a genuinely missing plist until `register()` is called, so registration is always attempted from that state.

## Security

- Auth tokens stored in the Data Protection Keychain with `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`; older ACL-backed copies move only through a reviewed, explicit Settings action
- Log output redacts emails, bearer tokens, cookies, API keys, and OAuth fields
- Two network destinations only: Codex's `app-server` JSON-RPC endpoint (via a local process, authenticated per-profile) for usage, and `https://auth.openai.com/oauth/token` for credential renewal
