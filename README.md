# codex-profile-switcher

A macOS menu bar app for switching between OpenAI Codex accounts and checking usage without leaving the menu bar.

## Features

- Manage multiple saved Codex profiles with custom labels
- See 5-hour and weekly usage for each saved profile
- Show credit balance when Codex exposes it
- Switch accounts without logging in every time
- Refresh inactive OAuth profiles so usage data stays usable
- Keep the last known usage snapshot in the menu
- Launch at login
- Copy redacted debug info, open the log file, and jump to the GitHub issue form

## Requirements

- macOS 14+
- [Codex desktop app](https://openai.com/codex/) installed

## Install

### GitHub Releases

Download the latest signed and notarized DMG from
[GitHub Releases](https://github.com/4LAU/codex-profile-switcher/releases), open
it, and drag `CodexProfileSwitcher.app` to Applications.

### Homebrew

After the first public DMG is published and the Homebrew tap is updated:

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

The bundle is written to `CodexProfileSwitcher.app`, with the app executable in
`Contents/MacOS` and the `codex-profile` helper in `Contents/Helpers`. When
`APP_IDENTITY` is unset or unavailable, the package script falls back to ad-hoc
signing.

Maintainer releases should use the DMG release flow in [RELEASE.md](RELEASE.md).
That path requires Developer ID signing and Apple notarization, and it generates
the Homebrew cask file for a tap.

## Setting Up Profiles

Each profile needs one login before the app can switch to it. Use the bundled
`codex-profile` helper:

```bash
codex-profile login 1
codex-profile login 2
# add more profiles as needed
```

The helper runs Codex's normal browser login flow in a temporary `CODEX_HOME`
and saves the resulting auth blob in macOS Keychain. After that, switching does
not require logging in again.

If you installed from the DMG manually and `codex-profile` is not on your PATH,
you can also start login from the menu bar app by selecting a profile that is
not set up yet.

If your workspace enables Codex device code authentication, you can still pass
device-auth options through the helper manually. The app uses the normal CLI login
flow because it works across workspaces without admin changes.

## How It Works

Codex Desktop still runs against its normal `~/.codex/` directory. This project
stores per-profile auth in macOS Keychain and swaps the selected profile into
`~/.codex/auth.json` when you switch. Existing saved auth from
`~/.codex-switcher/auth/*.json` is migrated into Keychain on startup and the
legacy disk auth directory is removed only after successful verification.

Local unsigned builds may trigger a macOS Keychain access prompt when the app or
helper reads or writes saved profile auth. Public signed releases store items
with current Keychain accessibility settings and automatically rewrite older
items that were created with per-binary access rules.

When you switch profiles, the helper:

1. Quits the running Codex instance
2. Saves the outgoing live auth back to the matching stored profile
3. Restores the selected profile's saved auth to `~/.codex/auth.json`
4. Relaunches Codex normally

For usage data, the app tries the OAuth-backed usage API first. If that fails for
a profile, it can fall back to `codex app-server` in a temporary profile-scoped
environment before showing a re-login warning. Inactive OAuth profiles are
refreshed automatically so saved usage data does not go stale as quickly.

## Debugging and Bug Reports

Open `Settings...` → `General` for built-in support tools:

- **Copy Debug Info** copies app state plus recent redacted logs to the clipboard.
- **Open Log** opens `~/Library/Logs/CodexProfileSwitcher/CodexProfileSwitcher.log`.
- **Report Bug** opens the GitHub issue form.

The log redacts emails, bearer tokens, cookies, OpenAI API keys, and OAuth token
fields before writing. From the terminal, `codex-profile doctor` also prints a
small environment and saved-profile check.

If you used an older build that created Keychain items with per-binary access
rules, install the signed release and run `codex-profile keychain-repair` once
to rewrite saved auth with the current Keychain access settings.

For manual Keychain validation of the signed bundle, run
`Scripts/keychain_signed_smoke.sh`. It uses fake Codex binaries, a temporary
home, and a disposable Keychain service. It is intentionally not part of
`make check` because macOS may show interactive Keychain prompts.

For isolated manual runs, both the app and helper honor `CODEX_PROFILE_HOME`
and `CODEX_PROFILE_KEYCHAIN_SERVICE`.

On a public signed and notarized release, macOS may still ask for Keychain
approval during initial setup. After approval, normal profile switching should
not repeatedly ask for your password.

## Contributing and Security

- Read [CONTRIBUTING.md](CONTRIBUTING.md) before opening a pull request.
- Read [SECURITY.md](SECURITY.md) before reporting a vulnerability.
- Community expectations are in [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md).

## Credits

Auth and usage API patterns adapted from [CodexBar](https://github.com/steipete/codexbar) by Peter Steinberger.

## License

MIT
