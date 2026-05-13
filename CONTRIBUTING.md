# Contributing

Thanks for contributing to `codex-profile-switcher`.

## Before You Start

- Open an issue before large changes so the direction is agreed first.
- Keep pull requests focused. Small, reviewable changes get merged faster.
- If behavior changes, update `README.md`.

## Development

Requirements:

- macOS 14+
- Xcode Command Line Tools
- Codex desktop app installed at the default path, or overridden with environment variables described in `README.md`

Build locally:

```bash
./build.sh
```

Run the installed app:

```bash
codex-profile-switcher
```

## Change Guidelines

- Preserve existing user data under `~/.codex/` and `~/.codex-switcher/`.
- Do not commit credentials, auth files, logs, or local machine-specific artifacts.
- Prefer minimal dependencies. This project currently builds with system Swift and shell tooling only.
- Keep macOS behavior native and predictable. Menu bar interactions should stay fast and low-friction.

## Pull Requests

Before opening a pull request:

- build the app with `./build.sh`
- sanity-check profile switching and menu rendering if your change affects them
- update documentation when user-visible behavior changes

By submitting a contribution, you agree that your work will be licensed under the repository's MIT license.
