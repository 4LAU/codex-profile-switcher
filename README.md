# codex-profile-switcher

A macOS menu bar app for managing multiple OpenAI Codex profiles. Switch between accounts with one click and see usage limits at a glance.

## Features

- Manage up to 8 Codex profiles with custom labels
- See 5-hour and weekly usage limits for all profiles
- One-click profile switching (quits and relaunches Codex)
- Automatic OAuth token refresh for inactive profiles
- Cached usage data so the menu is never empty
- Launch at Login support

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

# Install the CLI helper
cp bin/codex-profile ~/.local/bin/
chmod +x ~/.local/bin/codex-profile

# Run
codex-profile-switcher
```

The binary is installed to `~/.local/bin/codex-profile-switcher`.

## Setting Up Profiles

Each profile needs a one-time setup before it can be switched from the menu bar.
Use the included `codex-profile` CLI helper:

```bash
codex-profile login 1
codex-profile login 2
# ... through 8
```

This uses Codex's normal supported browser login flow with an isolated `CODEX_HOME`
for each profile. After a profile is set up, switching profiles does not require
logging in or out of accounts; the app relaunches Codex with that profile's saved
credentials.

If your workspace enables Codex device code authentication, you can still pass
device-auth options through the helper manually. The app uses the normal CLI login
flow because it works across workspaces without admin changes.

## How It Works

Each profile gets an isolated `~/.codex-<N>/` directory via the `CODEX_HOME` environment variable. When you click a profile in the menu bar, the app calls `codex-profile app <N>` which:

1. Quits the running Codex instance
2. Relaunches Codex with `CODEX_HOME` pointing to the selected profile

Usage data is fetched from the OpenAI usage API. Tokens for inactive profiles are refreshed automatically so usage data stays current.

## Credits

Auth and usage API patterns adapted from [CodexBar](https://github.com/steipete/codexbar) by Peter Steinberger.

## License

MIT
