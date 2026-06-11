# codex-profile-switcher

Tiny macOS 14+ menu bar app that manages **multiple OpenAI Codex accounts** and shows per-profile usage. Switch profiles without logging in again, track 5-hour and weekly limits with reset countdowns. Auth stored in macOS Keychain. No Dock icon, no main window, just a menu bar dropdown.

[![Latest release](https://img.shields.io/github/v/release/4LAU/codex-profile-switcher?style=flat-square&color=0a0a0c)](https://github.com/4LAU/codex-profile-switcher/releases/latest)
[![macOS 14+](https://img.shields.io/badge/macOS-14%2B-0a0a0c?style=flat-square)](https://github.com/4LAU/codex-profile-switcher/releases/latest)
[![Homebrew](https://img.shields.io/badge/brew-4lau%2Ftap%2Fcodex--profile--switcher-orange?style=flat-square)](https://github.com/4LAU/homebrew-tap)
[![License: MIT](https://img.shields.io/badge/license-MIT-6e5aff?style=flat-square)](LICENSE)

<img src="assets/screenshot-menu.png" width="300" alt="Codex Profile Switcher menu bar dropdown showing profiles with usage bars">

## Why

- You have multiple Codex accounts (personal, work, client). Logging out and back in every time is painful. This app makes switching instant.
- Usage limits reset on rolling windows, and you can't see them for inactive accounts. This app tracks every saved profile, not just the active one.
- Auth lives in macOS Keychain. No telemetry, no cloud sync, no account linking.

## Features

- Manage multiple saved Codex profiles with custom labels
- See 5-hour and weekly usage for each saved profile
- Show credit balance when Codex exposes it
- Switch accounts without logging in every time
- Refresh inactive OAuth profiles so usage data stays current
- Keep the last known usage snapshot in the menu
- Launch at login
- Copy redacted debug info, open the log file, and jump to the GitHub issue form

## Privacy

The app reads and writes macOS Keychain items it creates, `~/.codex/auth.json`, and its own config at `~/.codex-switcher/config.json`. It does not read browser data, does not access files outside those paths, and does not send telemetry or phone home. All data stays on your machine.

## Install

Requires macOS 14+ and the [Codex desktop app](https://openai.com/codex/).

### GitHub Releases

Download the latest signed and notarized DMG from
[GitHub Releases](https://github.com/4LAU/codex-profile-switcher/releases), open
it, and drag `CodexProfileSwitcher.app` to Applications.

### Homebrew

Install via the [4lau/tap](https://github.com/4LAU/homebrew-tap):

```bash
brew install --cask 4lau/tap/codex-profile-switcher
```

### Build from Source

Building from source requires Xcode.app. The test and package scripts use SwiftPM targets under `Sources/` and set `DEVELOPER_DIR=/Applications/Xcode.app` when available.

```bash
git clone https://github.com/4LAU/codex-profile-switcher.git
cd codex-profile-switcher

./build.sh

# Start the app
codex-profile-switcher
```

The menu bar app is installed to `~/.local/bin/codex-profile-switcher`, and the
matching Swift CLI helper is installed to `~/.local/bin/codex-profile`.

If Codex is not installed at `/Applications/Codex.app`, set `CODEX_APP` or
`CODEX_CLI` before using the helper.

To build a signed app bundle instead of loose binaries:

```bash
Scripts/package_app.sh

# Optional Developer ID / Apple Development identity.
APP_IDENTITY="Developer ID Application: Your Name (TEAMID)" Scripts/package_app.sh
```

Maintainer releases should use the DMG release flow in [docs/RELEASING.md](docs/RELEASING.md).

## Getting Started

Each profile needs one login before the app can switch to it.

Open Settings from the menu bar icon, select a profile, and click **Set Up**.
This opens Codex's normal browser login flow and saves the resulting auth in
macOS Keychain. After that, switching does not require logging in again.

You can also set up profiles from the terminal:

```bash
codex-profile login 1
codex-profile login 2
```

## CLI Reference

The `codex-profile` helper manages profiles from the terminal.

```
codex-profile app <profile> [workspace]
codex-profile login <profile> [codex-login-args...]
codex-profile status [profile] [--json]
codex-profile list [--json]
codex-profile path <profile>
codex-profile doctor
codex-profile keychain-repair
codex-profile best-auth --dir <path> [--exclude <id1,id2,...>] [--json] [--non-interactive] [--timeout <seconds>]
codex-profile exec [--max-attempts <n>] [--exclude <id1,id2,...>] [--timeout <seconds>] -- <command> [args...]
codex-profile import-auth --dir <path> --profile <id>
```

**Core commands**

- `login` — runs an isolated Codex login and saves the resulting auth to the Keychain.
- `app` — switches to a profile and relaunches Codex Desktop.
- `status` — shows auth state for one or all profiles. `--json` emits a JSON array.
- `list` — lists known profiles. `--json` emits a JSON array.
- `path` — prints the Keychain location for a profile.
- `doctor` — prints environment, installed Codex binaries, auth backend, and profile status.
- `keychain-repair` — rewrites saved auth items with current Keychain access settings. Run once if repeated prompts appear after upgrading.

### best-auth

Selects the profile with the most remaining quota and writes its credentials to `--dir`. Designed for scripted account rotation with `codex exec --ephemeral`.

Fetches live usage via `codex app-server` (bounded concurrency of 3) before ranking. Falls back to each profile's cached snapshot when a live fetch fails. Stores fresh snapshots back to the cache.

**Non-interactive behavior.** When stdin is not a terminal (CI, command substitution, cron), or when `--non-interactive` is passed, Keychain reads that would show a modal consent prompt are skipped instead of blocking. A global watchdog exits the process after `--timeout` seconds (default 30) to guarantee termination.

**Basic usage — bare profile ID on stdout:**

```bash
# Use in command substitution
PROFILE=$(codex-profile best-auth --dir /tmp/codex-session)
codex exec --ephemeral --dir /tmp/codex-session -- your-command
```

**JSON output:**

```bash
codex-profile best-auth --dir /tmp/codex-session --json
```

```json
{"candidates":[{"id":"personal","score":21,"snapshotAgeSeconds":47,"tier":"preferred"},{"id":"work","score":18,"snapshotAgeSeconds":14,"tier":"preferred"}],"fetched":true,"score":18,"selected":"work","tier":"preferred"}
```

**Excluding profiles:**

```bash
# Exclude a profile known to be rate-limited
codex-profile best-auth --dir /tmp/codex-session --exclude work
```

**Exit codes:**

| Code | Meaning |
|------|---------|
| 0 | Profile selected and credentials written |
| 1 | Generic failure |
| 2 | No eligible profile (all excluded or exhausted) |
| 3 | No profiles configured |
| 4 | Usage data unavailable (no live fetch succeeded, no cached snapshots) |
| 6 | Keychain interaction required — run `codex-profile best-auth` once from a terminal to grant access |
| 7 | Watchdog timeout |

### exec

Runs any command with `CODEX_HOME` pointed at the best profile's credentials, with automatic rotation on usage limits. This is the one-line replacement for hand-rolled `best-auth` / `mark-exhausted` / `import-auth` loops:

```bash
codex-profile exec -- codex exec --ephemeral -C "$(pwd)" - < prompt.md
```

Per attempt (up to `--max-attempts`, default 3):

1. Selects the profile with the most remaining quota (same logic and exit codes as `best-auth`) into a private temp directory.
2. Runs the command with `CODEX_HOME` pointing there. stdin and stdout pass through untouched; stderr passes through and is also scanned.
3. On success, writes refreshed tokens back to the profile (identity-guarded) and exits 0.
4. If the command failed and its stderr matches a usage-limit error (`rate limit`, `usage limit`, `429`, `quota exceeded`, `too many requests`), the profile is marked exhausted for an hour and the command retries on the next best profile. Any other failure exits immediately with the child's exit code. Detection scans stderr only — a limit message printed exclusively to stdout is not detected, because stdout streams through verbatim.

The live `~/.codex` is never touched, so a running Codex Desktop/CLI session is unaffected. Selection failures use the `best-auth` exit codes (2/3/4/6); a selection watchdog (`--timeout`, default 60s) covers only the selection phase, never the wrapped command.

### import-auth

Writes a refreshed `auth.json` from `--dir` back to the stored credential for `--profile`. Intended as the write-back half of a `best-auth` rotation loop — or just use `exec`, which does the full loop for you.

**Identity guard.** Before overwriting, `import-auth` compares the identity fingerprint of the existing stored credential against the incoming file. If they belong to different accounts the write is refused and the command exits 5. This prevents a credential for one account from silently overwriting a different account's profile.

```bash
codex-profile import-auth --dir /tmp/codex-session --profile work
```

Exit code 5 means the refreshed credential belongs to a different account. All other failures exit 1.

## How It Works

Codex Desktop still runs against its normal `~/.codex/` directory. This project
stores per-profile auth in macOS Keychain and swaps the selected profile into
`~/.codex/auth.json` when you switch.

When you switch profiles, the helper:

1. Quits the running Codex instance
2. Saves the outgoing live auth back to the matching stored profile
3. Restores the selected profile's saved auth to `~/.codex/auth.json`
4. Relaunches Codex normally

For usage data, the app fetches quota via `codex app-server` in a temporary
profile-scoped environment. The same path is used by the CLI's `best-auth`
command when it self-fetches usage before ranking.

## macOS Permissions

The app stores auth tokens in macOS Keychain. On signed releases (DMG or Homebrew), macOS asks for Keychain approval once during initial setup. After that, profile switching should not prompt again.

Local unsigned builds may trigger a Keychain prompt each time a different binary reads or writes saved auth. Install the signed release to avoid repeated prompts.

If upgrading from an older unsigned build, run `codex-profile keychain-repair` once to rewrite saved auth with current access settings.

If a signed build still prompts for Keychain access, open Keychain Access.app, find the `CodexProfileSwitcher` entry, and add `CodexProfileSwitcher.app` under Access Control > "Always allow access by these applications."

## Troubleshooting

Open `Settings...` > `General` for built-in support tools:

- Copy Debug Info copies app state plus recent redacted logs to the clipboard.
- Open Log opens `~/Library/Logs/CodexProfileSwitcher/CodexProfileSwitcher.log`.
- Report Bug opens the GitHub issue form.

Logs redact emails, bearer tokens, cookies, API keys, and OAuth fields before writing. From the terminal, `codex-profile doctor` prints a quick environment and saved-profile check.

## Docs

- [CHANGELOG.md](CHANGELOG.md) — release history
- [AGENTS.md](AGENTS.md) — project structure, build commands, contribution guidelines
- [SECURITY.md](SECURITY.md) — vulnerability reporting
- [docs/architecture.md](docs/architecture.md) — system design overview
- [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md) — development setup and workflow
- [docs/repo-boundaries.md](docs/repo-boundaries.md) — source ownership and generated-path boundaries
- [docs/RELEASING.md](docs/RELEASING.md) — maintainer release process

## Credits

Auth and usage API patterns adapted from [CodexBar](https://github.com/steipete/codexbar) by Peter Steinberger.

## License

MIT
