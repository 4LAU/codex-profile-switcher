# Contributing

Thanks for contributing to `codex-profile-switcher`.

## Local Setup

You need:

- macOS 14+
- Xcode Command Line Tools
- Codex Desktop installed, or a working `CODEX_APP` or `CODEX_CLI` override

Build:

```bash
./build.sh
```

Run tests:

```bash
make test-unit
make check
```

The integration tests are hermetic: they use a temporary home directory, fake
Codex binaries, and a file-backed auth vault. Do not add automated tests that
read or write the real macOS Keychain. Real Keychain checks should stay manual
and use a stable signed build, because rebuilding ad-hoc binaries can make
macOS ask for Keychain access again.

Run:

```bash
codex-profile-switcher
```

The build installs both `codex-profile-switcher` and `codex-profile` into
`~/.local/bin/` by default.

## Project Rules

- Preserve existing user data under `~/.codex/` and `~/.codex-switcher/`.
- Do not commit credentials, auth files, logs, or local machine-specific artifacts.
- Keep dependencies light. The app and helper build with system Swift and Apple frameworks.
- Keep macOS behavior native and predictable. Menu bar interactions should stay quick and quiet.

## Pull Requests

Before you open a pull request:

- run `make check`
- sanity-check profile switching and menu rendering if your change affects them
- update documentation when user-visible behavior changes

Open an issue before large changes so the direction is agreed first. Small pull
requests are easier to review and merge.

By submitting a contribution, you agree that your work will be licensed under the repository's MIT license.
