# Contributing

Thanks for contributing to `codex-profile-switcher`.

## Local Setup

You need:

- macOS 14+
- Xcode Command Line Tools
- `python3` on your `PATH`
- Codex Desktop installed, or a working `CODEX_APP` or `CODEX_CLI` override

Build:

```bash
./build.sh
```

Run:

```bash
codex-profile-switcher
```

The build installs both `codex-profile-switcher` and `codex-profile` into
`~/.local/bin/` by default.

## Project Rules

- Preserve existing user data under `~/.codex/` and `~/.codex-switcher/`.
- Do not commit credentials, auth files, logs, or local machine-specific artifacts.
- Keep dependencies light. The app builds with system Swift, and the helper uses shell plus `python3`.
- Keep macOS behavior native and predictable. Menu bar interactions should stay quick and quiet.

## Pull Requests

Before you open a pull request:

- build the app with `./build.sh`
- sanity-check profile switching and menu rendering if your change affects them
- update documentation when user-visible behavior changes

Open an issue before large changes so the direction is agreed first. Small pull
requests are easier to review and merge.

By submitting a contribution, you agree that your work will be licensed under the repository's MIT license.
