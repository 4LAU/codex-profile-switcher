# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/).

## 0.5.19 -- 2026-08-21

### Added

- `codex-profile renew` renews stored credentials before Codex would, together with a daily background agent that runs it at 03:00 and a Settings row reporting whether that agent is scheduled. Codex refreshes a credential only once it has already gone stale, and several parts of the system can then refresh concurrently carrying the same single-use refresh token. Accounts left unused for roughly eight days have been observed losing their login and needing a fresh `codex-profile login`. A replayed refresh token being read as reuse is the most likely explanation, but that has not been confirmed against the server, so treat it as inferred. Renewing early, once per credential rather than once per profile, keeps a credential from reaching that state.
- Renewal is serialized by a reservation, so two runs cannot refresh the same credential at once, and a run that cannot read `cache.json` refuses rather than overwriting the reservations it cannot see. `--dry-run` reports what would happen without making a request or writing anything. A single token request is capped well below the run deadline, so one unresponsive endpoint fails only its own credential instead of ending the run and stranding a reservation.

### Fixed

- Release packaging now builds the app and helper for arm64 and x86_64 by default. Releases since 0.5.16 had built only for arm64 unless an environment variable was exported, so they did not run on Intel Macs.

### Deprecated

- `best-auth --dir` remains supported with its existing behaviour, exit codes, and stdout, and now records a 24-hour lease for the exported credential. It prints a deprecation notice on stderr and points new scripts to `lease begin`; it will be removed in a future release.

## 0.5.18 -- 2026-08-05

### Fixed

- The account status row in Settings no longer shifts down on the profile that is currently active. The row aligned its contents by centre rather than by text baseline, so adding the smaller "(active)" label moved the baseline and pushed the row and everything below it out of line.

### Removed

- `AuthCredentials.needsRefresh` and the unused `refreshExpired`, `refreshReused` and `refreshRevoked` error cases. Nothing called them. The property carried an eight-day staleness constant that read as live policy while having no effect on anything.

## 0.5.17 -- 2026-08-01

### Fixed

- `lease begin` now re-selects another account when a concurrent run claims the one it picked, instead of failing. Workers started at the same instant all read an empty lease map and chose the same best account, so every worker but one was rejected and callers fell back to a slower lane despite most accounts being free.

## 0.5.16 -- 2026-07-25

### Fixed

- Account status now updates automatically in Settings after reauthentication finishes.

## 0.5.15 -- 2026-07-18

### Fixed

- ChatGPT relaunch now opens the exact selected app path, preventing an obsolete Codex.app with the same identity from intercepting launch or causing a false failure.

## 0.5.14 -- 2026-07-17

### Fixed

- Profile switching now waits for the ChatGPT or Codex desktop process to reopen. A background app-server no longer counts as a successful relaunch.
- Loose or stale builds validate and hand off to the signed app in `/Applications` before reading saved profiles. This prevents intact accounts from appearing to need login again.

## 0.5.13 -- 2026-07-17

### Changed

- Launch at Login now uses macOS Service Management instead of a saved path to one build. Existing signed installations safely migrate the old login item after the replacement is enabled.

### Fixed

- Profile switching now finds Codex Desktop by its `com.openai.codex` bundle identity, including the current ChatGPT.app layout. It stops the running desktop and app-server before changing authentication, preserves the last workspace on relaunch, validates the bundled CLI first, and reports the actual launch error when relaunching fails.
- Unsigned development builds can no longer open production profile data. If an old login item starts one, it hands control to the signed app without changing saved profiles, preventing repeated crash alerts and misleading re-login warnings.

## 0.5.7 -- 2026-07-15

### Fixed

- Legacy Keychain migration now reads protected records one at a time instead of issuing a single batch request that macOS rejects.

## 0.5.6 -- 2026-07-15

### Fixed

- Keychain migration now shows its actual safe error instead of a generic retry message.

## 0.5.5 -- 2026-07-15

### Fixed

- The app and bundled helper now report the same version as the signed package.

## 0.5.4 -- 2026-07-15

### Fixed

- Saved profile credentials now use the macOS Data Protection Keychain instead of per-account access-control lists. New saves and ordinary profile switches no longer create a password prompt for every account after an app update.
- Older Keychain copies can be moved only from Settings > General after reviewing the exact accounts that will be affected. The app never performs that cleanup automatically.
- The refresh schedule and menu-open refresh setting remain available alongside the new migration controls.

## 0.5.1 -- 2026-07-14

### Fixed

- Usage rows now use the duration reported by Codex instead of assuming the first window is always five hours and the second is weekly. A missing window is no longer displayed as `0%`.

### Documentation

- README and `docs/architecture.md` now cover the `lease begin|swap|end|gc` command, the `import-auth --non-interactive`/`--timeout` flags, and the cross-process cache lock. The `codex-profile --help` synopsis also gained the previously missing `lease swap` and `lease end` lines.

## 0.5.0 -- 2026-06-24

### Added

- New `codex-profile lease begin|swap|end|gc` command: reserves the best-quota profile and seeds a private throwaway `CODEX_HOME` for a long-lived (warm) Codex session, recording a TTL reservation in the cache so two concurrent runs never select the same account. `lease swap <token>` hot-rotates the credential to a fresh account inside the same home (the session's `sessions/` is untouched) when the current account hits a usage limit; `lease end <token>` writes the refreshed credential back and tears the lease down (idempotent and trap-safe); `lease gc` reclaims expired or orphaned lease homes. `begin`/`swap` accept `--exclude`, `--ttl`, `--timeout`, `--json`, `--non-interactive`; exit codes match `best-auth`.
- `import-auth` gains `--non-interactive` and `--timeout <seconds>`: in non-interactive mode it skips the interactive Keychain-repair step (which could otherwise hang a headless process on a modal consent prompt), arms a watchdog, and reads the existing credential through the fail-closed vault. This is the headless-safe write-back path used by `lease end`.

### Fixed

- Lease credential-safety under concurrency hardened. Every read-modify-write of the shared usage cache (lease `begin`/`swap`/`end`/`gc`, `mark-exhausted`, usage-snapshot writes, and the menu app's cache save) now runs inside a cross-process advisory lock, so a concurrent writer can no longer drop a just-committed lease in the gap between its own disk read and atomic write. `lease swap` now writes the current account's (possibly refreshed) credential back to its profile *before* overwriting the home with the new account, so a token rotated during the warm session is never lost. `lease gc` attempts write-back before deleting an expired lease home and preserves the home only when a real credential would be lost (an identity-mismatched home or a vault save error), reclaiming homes with nothing recoverable; its orphan sweep now protects every recorded lease token, not just active ones, so a deliberately-preserved failed-writeback home is never swept after its TTL lapses. `lease begin` re-checks under the lock that the selected profile is not reserved by another run (or holding a credential pending recovery), and `lease swap` refuses to re-add a lease that was ended or reclaimed mid-swap (no resurrection of an ended lease) and writes the new account's credential straight back if it cannot rebind the lease after overwriting the home (so the rotated credential is never stranded). `lease end` now exits non-zero when a write-back fails recoverably (credential recovery still pending) while keeping the idempotent "no active lease" case at exit 0, so automation can tell a clean teardown from a stranded credential.
- Unsigned dev builds no longer advance the shared Keychain auth-storage bookkeeping in `config.json`. Because that file is shared across builds, an unsigned build using the file dev vault could mark the auth-storage version as migrated/repaired -- and even migrate or delete the legacy auth store -- causing a later signed release to skip its real Keychain migration and find no saved auth. Keychain migration, repair, and legacy cleanup now run only when the Keychain backend is active.
- The menu app now pins the `codex-profile` helper it launches to its own auth backend. Previously the app and the delegated helper each picked Keychain vs. file dev vault from their own signing identity, so an unsigned app delegating to a signed helper (or vice versa) could write a login to one store while the app read the other. The app now passes its backend explicitly (`CODEX_PROFILE_FILE_AUTH_STORE_DIR` / `CODEX_PROFILE_FORCE_KEYCHAIN`) so both always agree.

## 0.4.1 -- 2026-06-11

### Changed

- Unsigned (ad-hoc) builds of the app and CLI no longer touch the macOS Keychain. Every rebuild of an unsigned binary has a new code identity, which made macOS show a consent prompt per saved profile after each rebuild. Unsigned builds now automatically use a separate file-based dev vault at `~/.codex-switcher/dev-auth-store` with a one-line notice; signed builds (releases, `make install-cli`) keep using the Keychain unchanged.

## 0.4.0 -- 2026-06-11

### Added

- New `codex-profile exec -- <command> [args...]` command: runs any command with `CODEX_HOME` pointed at the best profile's credentials and automatically rotates to the next best profile when the command fails with a usage-limit error (`--max-attempts`, default 3). The exhausted profile is marked unavailable for an hour, refreshed tokens are written back to the profile afterwards, and the live `~/.codex` is never touched. stdin/stdout pass through untouched; the child's exit code is passed through on non-retryable failures.

## 0.3.0 -- 2026-06-10

### Added

- `best-auth` now fetches live usage (Codex app-server, bounded concurrency) before ranking, instead of relying on the menu bar app's cached usage file. When the app isn't running it no longer silently picks alphabetically off a stale/empty cache. Per-profile fetch failures fall back to the cached snapshot, and fresh snapshots are merged back into the cache.
- `best-auth --json` emits a stable machine-readable report (`selected`, `tier`, `score`, `candidates[]`, `fetched`). `status --json` and `list --json` emit structured output too. Default (non-JSON) `best-auth` output is unchanged: the bare selected profile ID.
- `best-auth` now has documented, stable exit codes: 0 selected, 2 no eligible profile, 3 no profiles configured, 4 usage data unavailable, 6 keychain interaction required, 7 watchdog timeout.

### Changed

- Usage polling now uses Codex's app-server exclusively; removes the reverse-engineered usage API client and OAuth refresh-on-poll.
- `best-auth` and `import-auth` are now official supported commands. `import-auth` exits 5 only on an identity mismatch (a refreshed credential belonging to a different account) and 1 for other failures.

### Fixed

- Fixed false "re-auth needed" status for profiles with valid tokens (bare `401`/`403` substrings false-positived on unrelated error messages such as port numbers).
- Fixed `best-auth` reporting a different tier/score from what was used for selection when a rate-limit reset boundary was crossed between the ranking and report steps.
- Fixed a potential data race between background usage refreshes and profile state.
- `best-auth` no longer hangs forever in non-interactive shells (CI, command substitution, background tasks). When stdin is not a terminal (or `--non-interactive` is passed), a Keychain read that needs interactive consent now exits with a clear message (code 6) instead of blocking on a modal prompt with no UI. A global watchdog (`--timeout`, default 30s, exit 7) guarantees the command always terminates.

## 0.2.1 -- 2026-06-04

### Fixed

- Reduced Keychain password prompts from 36 to 12 (one per profile, one-time after binary change) by eliminating redundant reads during save and refresh
- ACL repair now retries on next launch if any profiles were denied — previously a partial failure was treated as complete
- Added crash-window recovery files so credentials survive a process kill during repair
- CLI auto-repair runs before auth-reading commands (`best-auth`, `status`, `import-auth`, `login`, `app`) — no longer requires explicit `keychain-repair`

## 0.2.0 -- 2026-06-02

### Changed

- Switched from data protection Keychain to legacy ACL Keychain — `swift build` now produces a fully working binary without entitlements or provisioning profiles
- Removed `migrate` CLI command and all migration machinery

### Removed

- Data protection Keychain backend (`DataProtectionKeychainAuthVault`)
- Dual-backend migration wrapper (`MigratingAuthVault`)
- Provisioning profile discovery and embedding in `package_app.sh`
- "Migration needed" profile status in the UI

### Breaking

- Existing profiles stored in the data protection Keychain are no longer accessible — re-login each profile with `codex-profile login <name>`

## 0.1.12 -- 2026-05-30

### Added

- `best-auth` CLI command — selects the least-used configured profile and exports its credentials to a temp directory for `codex exec --ephemeral`
- `mark-exhausted` CLI command — flags a profile as rate-limited so `best-auth` skips it
- `import-auth` CLI command — imports refreshed credentials back from a temp directory with identity verification

### Fixed

- GUI app now preserves CLI-written exhaustion overrides when saving the usage cache
- Profile removal and auth clearing now clean up exhaustion overrides

## 0.1.11 -- 2026-05-29

### Added

- Show "Update to vX.Y.Z — restart now?" inline in the menu when a new version is downloaded, instead of requiring a manual check

## 0.1.10 -- 2026-05-29

### Fixed

- Fix "Unable to find Electron app" error when relaunching Codex Desktop after a profile switch (compatibility with Codex CLI 0.134+)

## 0.1.9 -- 2026-05-21

### Changed

- Reduce polite quit window from 15s to 5s before escalating to SIGTERM, making profile switches faster

## 0.1.8 -- 2026-05-21

### Fixed

- Fix crash when profile switch fails: error alert was shown on a background thread instead of the main thread
- Fix profile switch failing when Codex's app-server lingers after quit: escalate from polite quit to SIGTERM then SIGKILL

## 0.1.7 -- 2026-05-15

### Fixed

- Bring Sparkle update check windows to the front from the menu bar app

## 0.1.6 -- 2026-05-15

### Fixed

- Fix false duplicate-account detection for separate OpenAI users that share an account/workspace context
- Improve login failure messages in Settings and keep error toasts visible longer

### Added

- In-app update checking via Sparkle 2.9.1 — DMG users are notified when a new version is available
- "Check for Updates..." menu item in the status bar menu
- Appcast generation in the release pipeline for automatic update feeds

## 0.1.5 -- 2026-05-14

### Fixed

- Fix new profile defaulting to "Profile 1" instead of the next number when added from Settings

## 0.1.4 -- 2026-05-14

### Fixed

- Fix Keychain ACL discovery when CLI helper runs inside the app bundle (e.g. via Homebrew symlink) so both binaries are trusted without prompting

## 0.1.3 -- 2026-05-14

### Fixed

- Pre-authorize both the app and CLI helper in Keychain item access control lists

## 0.1.2 -- 2026-05-14

### Added

- App icon (stacked Codex visors on dark squircle)
- "Why" section in README
- Docs index in README linking architecture, development, and release guides
- Keychain Access.app troubleshooting tip for signed builds

### Changed

- Rewrite README: concise intro, Privacy section, macOS Permissions, condensed Troubleshooting
- Shorten Launch at Login description in Settings

### Removed

- CODE_OF_CONDUCT.md (unnecessary for single-maintainer utility)

## 0.1.1 -- 2026-05-14

### Fixed

- Eliminate Keychain password prompts on first launch before any account is set up
- Close remaining Keychain access leaks when all profiles are unset (menu open, sync)
- Fix pipe data truncation in CLI process output reading
- Fix incorrect "Use Re-auth" instruction for profiles that have never been set up

### Changed

- Redesign Settings Profiles tab with Apple-native master-detail layout (sidebar + detail panel)
- Auto-save profile labels on focus loss, Return, tab switch, and window close (no Save button)
- Add standard keyboard shortcuts: Cmd+Q, Cmd+H, Cmd+Option+H, Cmd+M
- Extract shared pipe-drain helper and use static ISO8601 formatters

## 0.1.0 -- 2026-05-13

### Added

- macOS menu bar app for switching between multiple Codex profiles
- 5-hour and weekly usage tracking per profile with progress bars
- Credit balance display when available
- Profile labels with custom naming
- OAuth token refresh for inactive profiles
- Launch at login support
- `codex-profile` CLI helper for login, logout, status, and diagnostics
- macOS Keychain storage for profile auth
- Log redaction for emails, bearer tokens, cookies, API keys, and OAuth fields
- Copy Debug Info, Open Log, and Report Bug from Settings
- Developer ID signed and Apple-notarized DMG distribution
- Homebrew cask via `brew install --cask 4lau/tap/codex-profile-switcher`
- Build-from-source support with `./build.sh`
