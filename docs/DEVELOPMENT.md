# Development

## Prerequisites

- macOS 14+
- Xcode Command Line Tools (`xcode-select --install`)
- [Codex Desktop](https://openai.com/codex/) installed (or `CODEX_APP` / `CODEX_CLI` overrides)

## Build

```bash
# Dev build (installs to ~/.local/bin/)
./build.sh

# App bundle (for signing/packaging)
Scripts/package_app.sh
```

## Test

```bash
make test              # all tests
make test-unit         # Swift unit tests
make test-integration  # shell integration tests
make check             # tests + build
```

Integration tests are hermetic: temporary home directory, fake Codex binaries, file-backed auth vault. They never touch the real macOS Keychain.

## Run

```bash
codex-profile-switcher    # menu bar app
codex-profile --help      # CLI helper
```

Both binaries install to `~/.local/bin/` by default. Pass a path to `./build.sh` to change the output location.

## Environment Overrides

| Variable | Purpose |
|---|---|
| `CODEX_PROFILE_HOME` | Config directory (default: `~/.codex-switcher`) |
| `CODEX_PROFILE_KEYCHAIN_SERVICE` | Keychain service name (default: `com.4lau.codex-profile-switcher.auth`) |
| `CODEX_APP` | Path to Codex.app (default: `/Applications/Codex.app`) |
| `CODEX_CLI` | Path to Codex CLI binary |
