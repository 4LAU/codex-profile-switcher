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

| File | Role |
|---|---|
| `CodexProfileSwitcher.swift` | SwiftUI menu bar app, usage polling, settings UI |
| `CodexProfileCLI.swift` | CLI helper for login, logout, switch, diagnostics |
| `AuthBlob.swift` | Auth token model supporting OAuth and API key flows |
| `AuthVault.swift` | Protocol for auth storage backends |
| `KeychainAuthVault.swift` | macOS Keychain implementation |
| `FileAuthVault.swift` | File-based implementation (tests, migration) |

## Profile Switch Flow

1. Quit running Codex instance
2. Save outgoing profile's live auth back to Keychain
3. Restore selected profile's auth to `~/.codex/auth.json`
4. Relaunch Codex

## Usage Polling

The app polls the OpenAI usage API for each profile. OAuth profiles are refreshed automatically to keep usage data current. Falls back to `codex app-server` in a temporary environment if the API is unavailable.

## Security

- Auth tokens stored in macOS Keychain with `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`
- Log output redacts emails, bearer tokens, cookies, API keys, and OAuth fields
- No network calls except to OpenAI's usage API (authenticated per-profile)
