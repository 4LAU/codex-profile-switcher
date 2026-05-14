# Repository Boundaries

SwiftPM owns compile and test source membership. Add Swift code under `Sources/` or `Tests/`, then update `Package.swift` if a new target is needed. Do not add root-level Swift files or reintroduce script-maintained source arrays.

## Targets

| Target | Owns |
|---|---|
| `CodexProfileCore` | Auth blob parsing, auth vaults, profile config, paths, validation, atomic writes, redaction, usage/RPC clients, and profile switch transactions |
| `CodexProfileSwitcherApp` | Menu bar lifecycle, SwiftUI views, settings, usage polling orchestration, icon rendering, launch-at-login, and Sparkle UI hooks |
| `CodexProfileCLI` | Command parsing, Codex Desktop process control, isolated login, app launch, and terminal output |

`CodexProfileCore` must stay UI-free. It may use Foundation and Security. It must not import AppKit, SwiftUI, Cocoa, or Sparkle. App-only orchestration, windows, menu items, status item ownership, and launch-at-login belong in `CodexProfileSwitcherApp`.

## Local And Generated Paths

Skip these when reading the tracked source structure:

- `.build/`
- `CodexProfileSwitcher.app/`
- `.plans/`
- `.internal/`
- `.security/`

Release artifacts are produced under `.build/release/`. Sparkle is downloaded into `.build/sparkle/`.

## User Data And Secrets

The app must preserve existing user data under `~/.codex/` and `~/.codex-switcher/`. Automated tests must use `CODEX_PROFILE_HOME` and file-backed vaults for isolation.

Never commit auth files, credentials, logs, notarization credentials, or local Keychain-derived artifacts.
