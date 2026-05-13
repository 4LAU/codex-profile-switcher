# codex-profile-switcher

A macOS menu bar app for managing multiple OpenAI Codex profiles. Switch between accounts with one click and see usage limits at a glance.

## Features

- Manage up to 8 Codex profiles with custom labels
- See 5-hour and weekly usage limits for all profiles
- See Codex credit balance when the usage API reports it
- One-click profile switching (quits and relaunches Codex)
- Automatic OAuth token refresh for inactive profiles
- Cached usage data so the menu is never empty
- Launch at Login support
- Redacted local debug logs with one-click bug report info

## Requirements

- macOS 14+
- Xcode Command Line Tools (`xcode-select --install`)
- [Codex desktop app](https://openai.com/codex) installed

## Install

```bash
git clone https://github.com/aaronlau/codex-profile-switcher.git
cd codex-profile-switcher

# Build
chmod +x build.sh
./build.sh

# Run
codex-profile-switcher
```

The binary is installed to `~/.local/bin/codex-profile-switcher`, and the
matching CLI helper is installed to `~/.local/bin/codex-profile`.

## Setting Up Profiles

Each profile needs a one-time setup before it can be switched from the menu bar.
Use the included `codex-profile` CLI helper:

```bash
codex-profile login 1
codex-profile login 2
# ... through 8
```

This uses Codex's normal supported browser login flow in a temporary isolated
`CODEX_HOME`, then saves only that profile's auth file into
`~/.codex-switcher/auth/`. After a profile is set up, switching profiles does not
require logging in or out of accounts; the app swaps the selected profile's saved
auth into Codex's normal `~/.codex/auth.json` slot and relaunches Codex.

If your workspace enables Codex device code authentication, you can still pass
device-auth options through the helper manually. The app uses the normal CLI login
flow because it works across workspaces without admin changes.

## How It Works

Codex Desktop always runs against its normal `~/.codex/` directory, so sessions,
projects, plugins, and local app state stay shared. Each profile stores durable
auth at `~/.codex-switcher/auth/<N>.json`. When you click a profile in the menu
bar, the app calls `codex-profile app <N>` which:

1. Quits the running Codex instance
2. Snapshots the outgoing live auth back to the matching saved profile
3. Restores the selected profile's saved auth to `~/.codex/auth.json`
4. Relaunches Codex normally, without a `CODEX_HOME` override

Usage data is fetched in app `auto` mode by trying the OpenAI OAuth usage API first. If that path is unauthorized or the saved refresh token is expired, revoked, reused, or missing required tokens, the app falls back to `codex app-server` in a temporary profile-scoped `CODEX_HOME` before surfacing a re-login warning. Tokens for inactive profiles are refreshed automatically so usage data stays current.

## Debugging and Bug Reports

Open Settings → General for support tools:

- **Copy Debug Info** copies app state plus recent redacted logs to the clipboard.
- **Open Log** opens `~/Library/Logs/CodexProfileSwitcher/CodexProfileSwitcher.log`.
- **Report Bug** opens the GitHub issue form.

The log redacts emails, bearer tokens, cookies, OpenAI API keys, and OAuth token fields before writing.

## Credits

Auth and usage API patterns adapted from [CodexBar](https://github.com/steipete/codexbar) by Peter Steinberger.

## License

MIT
