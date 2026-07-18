# Development

## Prerequisites

- macOS 14+
- Xcode.app. The test runner uses SwiftPM and Swift Testing; the scripts set `DEVELOPER_DIR=/Applications/Xcode.app` when available.
- [ChatGPT](https://openai.com/codex/) with Codex Desktop installed (or `CODEX_APP` / `CODEX_CLI` overrides)

## Build

```bash
# Dev build (installs to ~/.local/bin/)
./build.sh

# App bundle (for signing/packaging)
Scripts/package_app.sh
```

`build.sh` creates loose development binaries that do not access the macOS
Keychain. Run the loose menu app with `CODEX_PROFILE_HOME` or
`CODEX_PROFILE_TEST_HOME` set to a directory other than your normal home:

```bash
CODEX_PROFILE_HOME="$HOME/.codex-profile-dev" codex-profile-switcher
```

These variables set an isolated home root. The app creates `.codex-switcher`
and `.codex` inside it, so this example stores its config at
`~/.codex-profile-dev/.codex-switcher/config.json` and keeps its Codex data
under `~/.codex-profile-dev/.codex/`.

A loose build cannot open the production profile home or manage its Launch at
Login setting. Without an isolated home, it hands startup to the signed app in
`/Applications` so saved profiles are not mistaken for missing data. Use
`Scripts/package_app.sh` when you need a signed `.app` bundle, Keychain-backed
profiles, Sparkle integration, or release-like Gatekeeper behavior.

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

## Sparkle (Auto-Update)

Release builds embed [Sparkle 2.x](https://sparkle-project.org) for in-app update checking. Dev builds (`build.sh`) skip Sparkle entirely — the `#if canImport(Sparkle)` guards compile it out.

```bash
# Fetch the Sparkle framework (required before package_app.sh)
Scripts/fetch_sparkle.sh

# One-time: generate EdDSA signing keys (stored in macOS Keychain)
Scripts/setup_sparkle_keys.sh
```

The public key must be set as `SPARKLE_ED_PUBLIC_KEY` in your environment for release builds. The release script generates `appcast.xml` automatically.

## Environment Overrides

| Variable | Purpose |
|---|---|
| `CODEX_PROFILE_HOME` | Home root for profile-switcher and Codex data. Defaults to the macOS user home; config is stored in `<root>/.codex-switcher/`. |
| `CODEX_PROFILE_TEST_HOME` | Isolated home root for development and test runs. Config is stored in `<root>/.codex-switcher/`. |
| `CODEX_APP` | Optional path to the Codex Desktop app bundle. Without it, the helper finds the installed `com.openai.codex` bundle, including ChatGPT.app and legacy Codex.app. |
| `CODEX_CLI` | Path to Codex CLI binary |
| `CODEX_BUNDLED_CLI` | Optional path to the app's bundled `codex` CLI |
| `SPARKLE_ED_PUBLIC_KEY` | EdDSA public key for Sparkle update verification |

`CODEX_PROFILE_KEYCHAIN_SERVICE` is no longer supported. Signed builds use the
fixed Keychain service `com.4lau.codex-profile-switcher.auth`. The only service
override is `CODEX_PROFILE_DATA_PROTECTION_KEYCHAIN_SERVICE`, which is reserved
for the signed manual smoke script. It works only with
`CODEX_PROFILE_SIGNED_SMOKE=1` and a disposable service beginning
`com.4lau.codex-profile-switcher.auth.smoke.`.
