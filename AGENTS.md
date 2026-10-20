# Repository Guidelines

Public open-source macOS menu bar app (SwiftUI) plus CLI helper that switches Codex auth profiles. `Makefile` has the build/test/check/format targets; `make check` must pass before a PR.

## Traps

- Preserve existing user data under `~/.codex/` and `~/.codex-switcher/`. Auth lives in the macOS Keychain; the app reads `~/.codex-switcher/config.json`.
- Never commit credentials, auth files, logs, local machine artifacts, internal planning docs, or AI tooling config. Keep history clean: no WIP commits on main.
- Sparkle 2.x is the only external dependency, fetched by `Scripts/fetch_sparkle.sh` (not a SwiftPM dependency). Update checks exist only in packaged `.app` builds; the loose dev binary from `./build.sh` has no "Check for Updates...". Smoke-test Sparkle with `/Applications/CodexProfileSwitcher.app`.
- Releases: `Scripts/release_app.sh` updates `appcast.xml`; pushing that file to `main` is what publishes the Sparkle feed. Notarization uses `NOTARY_KEYCHAIN_PROFILE=notary-apikey` (the old `notarytool` profile is defunct).
- The version lives in three places that must stay in sync (CI enforces): `version.env`, `Sources/CodexProfileSwitcherApp/AppInfo.swift`, `Sources/CodexProfileCLI/CodexProfileCLI.swift`.
- SwiftPM source membership is the build source of truth; don't add root Swift files or script-only source lists.
- Always rebuild (`./build.sh`) before testing. The CLI helper installs to `~/.local/bin/codex-profile`.
- Use `CODEX_PROFILE_HOME` and file-backed vaults for isolated runs. Never run anything that touches the real Keychain in automated tests.
- Plans go in `.plans/` (gitignored). Plan docs meant to ship with a feature go in `docs/plans/`.
- Conventional commits; user-visible changes get a CHANGELOG.md Unreleased entry; UI changes need a screenshot in the PR.

## Testing

Global policy applies (`~/.claude/testing-policy.md`): tests only for this repo's 1% list. Verification tools: `make check`, isolated runs via `CODEX_PROFILE_HOME`, `Scripts/keychain_signed_smoke.sh` (manual). Integration tests are hermetic (temp home, fake binaries, file-backed vault).
The 1% list (silent failures): overwriting `~/.codex/auth.json` with the wrong profile, failing to preserve the outgoing live account on a switch, mismatching a saved profile to live auth, usage shown for the wrong account, reporting a profile healthy when it needs re-login, leaking tokens/cookies/emails into logs.
