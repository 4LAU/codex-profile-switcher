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
- Xcode Command Line Tools (`xcode-select --install`)
- `python3` on your `PATH` for the `codex-profile` helper
- [Codex desktop app](https://openai.com/codex/) installed

## Install

```bash
git clone https://github.com/4LAU/codex-profile-switcher.git
cd codex-profile-switcher

./build.sh

# Start the app
codex-profile-switcher
```

The binary is installed to `~/.local/bin/codex-profile-switcher`, and the
matching CLI helper is installed to `~/.local/bin/codex-profile`.

If Codex is not installed at `/Applications/Codex.app`, set `CODEX_APP` or
`CODEX_CLI` before using the helper.

## Setting Up Profiles

Each profile needs one login before the app can switch to it. Use the bundled
`codex-profile` helper:

```bash
codex-profile login 1
codex-profile login 2
# add more profiles as needed
```

The helper runs Codex's normal browser login flow in a temporary `CODEX_HOME`
and saves the resulting auth file to `~/.codex-switcher/auth/<profile>.json`.
After that, switching does not require logging in again.

If your workspace enables Codex device code authentication, you can still pass
device-auth options through the helper manually. The app uses the normal CLI login
flow because it works across workspaces without admin changes.

## How It Works

Codex Desktop still runs against its normal `~/.codex/` directory. This project
stores per-profile auth in `~/.codex-switcher/auth/<profile>.json` and swaps the
selected profile into `~/.codex/auth.json` when you switch.

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

## Contributing and Security

- Read [CONTRIBUTING.md](CONTRIBUTING.md) before opening a pull request.
- Read [SECURITY.md](SECURITY.md) before reporting a vulnerability.
- Community expectations are in [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md).

## Credits

Auth and usage API patterns adapted from [CodexBar](https://github.com/steipete/codexbar) by Peter Steinberger.

## License

MIT
