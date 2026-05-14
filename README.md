# codex-profile-switcher

Tiny macOS 14+ menu bar app that manages **multiple OpenAI Codex accounts** and shows per-profile usage. Switch profiles without logging in again, track 5-hour and weekly limits with reset countdowns. Auth stored in macOS Keychain. No Dock icon, no main window, just a menu bar dropdown.

[![Latest release](https://img.shields.io/github/v/release/4LAU/codex-profile-switcher?style=flat-square&color=0a0a0c)](https://github.com/4LAU/codex-profile-switcher/releases/latest)
[![macOS 14+](https://img.shields.io/badge/macOS-14%2B-0a0a0c?style=flat-square)](https://github.com/4LAU/codex-profile-switcher/releases/latest)
[![Homebrew](https://img.shields.io/badge/brew-4lau%2Ftap%2Fcodex--profile--switcher-orange?style=flat-square)](https://github.com/4LAU/homebrew-tap)
[![License: MIT](https://img.shields.io/badge/license-MIT-6e5aff?style=flat-square)](LICENSE)

<img src="assets/screenshot-menu.png" width="300" alt="Codex Profile Switcher menu bar dropdown showing profiles with usage bars">

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

Building from source requires Xcode Command Line Tools (`xcode-select --install`).

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

## How It Works

Codex Desktop still runs against its normal `~/.codex/` directory. This project
stores per-profile auth in macOS Keychain and swaps the selected profile into
`~/.codex/auth.json` when you switch.

When you switch profiles, the helper:

1. Quits the running Codex instance
2. Saves the outgoing live auth back to the matching stored profile
3. Restores the selected profile's saved auth to `~/.codex/auth.json`
4. Relaunches Codex normally

For usage data, the app tries the OAuth-backed usage API first. If that fails,
it can fall back to `codex app-server` in a temporary profile-scoped environment.
Inactive OAuth profiles are refreshed automatically so saved usage data stays
current.

## macOS Permissions

The app stores auth tokens in macOS Keychain. On signed releases (DMG or Homebrew), macOS asks for Keychain approval once during initial setup. After that, profile switching should not prompt again.

Local unsigned builds may trigger a Keychain prompt each time a different binary reads or writes saved auth. Install the signed release to avoid repeated prompts.

If upgrading from an older unsigned build, run `codex-profile keychain-repair` once to rewrite saved auth with current access settings.

## Troubleshooting

Open `Settings...` > `General` for built-in support tools:

- **Copy Debug Info** copies app state plus recent redacted logs to the clipboard.
- **Open Log** opens `~/Library/Logs/CodexProfileSwitcher/CodexProfileSwitcher.log`.
- **Report Bug** opens the GitHub issue form.

Logs redact emails, bearer tokens, cookies, API keys, and OAuth fields before writing. From the terminal, `codex-profile doctor` prints a quick environment and saved-profile check.

## Contributing and Security

- Read [AGENTS.md](AGENTS.md) for project structure, build commands, and contribution guidelines.
- Read [SECURITY.md](SECURITY.md) before reporting a vulnerability.

## Credits

Auth and usage API patterns adapted from [CodexBar](https://github.com/steipete/codexbar) by Peter Steinberger.

## License

MIT
