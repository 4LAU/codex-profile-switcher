# Configurable Refresh Design

## Problem

Usage data should stay current without interrupting menu interaction. Users need control over the background cadence and whether opening the menu fetches fresh data. A manual refresh must update the open menu in place instead of dismissing it. Failed refreshes must not look current.

## Goals

- Add Manual, 1 minute, 2 minute, 5 minute, and 15 minute refresh intervals. Keep 5 minutes as the default.
- Add a `Refresh when the menu opens` setting, off by default.
- Keep the menu open when Refresh or Command-R starts a fetch.
- Disable the Refresh row while any usage refresh is running, then enable it when the fetch finishes.
- Continue using `UsageProvider` to suppress overlapping work and preserve cached data on failure.
- Make Codex usage fetching work when the packaged app is launched without a Homebrew-aware `PATH`.
- Mark cached usage as cached when a refresh fails.

## Non-goals

- Provider-specific schedules
- Notifications or refresh cancellation controls
- Changes to usage fetching, authentication, or cache formats
- A broader menu rewrite
- CodexBar's multi-provider menu coordination system

## Reference

[CodexBar](https://github.com/steipete/CodexBar) uses an app preference for menu-open refresh and a custom AppKit menu row for actions that must not end menu tracking. It is MIT-licensed, as is this repository. This implementation will adapt that interaction pattern to the existing single-menu architecture without copying CodexBar's provider, viewport, or menu-reconciliation machinery.

The [Codex app-server documentation](https://github.com/openai/codex/blob/main/codex-rs/app-server/README.md#7-rate-limits-chatgpt) defines `usedPercent` as usage consumed within the quota window. The app should continue displaying that value as used, not invert it.

## Diagnosed stale usage

The percentages in the reported menu were old cached values. The cache had stopped advancing while the app log recorded `codex app-server closed stdout` for every profile on every timer and manual attempt.

The current Codex app bundle no longer contains the CLI at the path this app checks first, so resolution falls back to Homebrew. The packaged profile switcher was launched without a `PATH` entry for Homebrew. `CodexCLIResolver` constructs a broader path to locate `/opt/homebrew/bin/codex`, but `CodexRPCClient` starts that file with the app's original environment. The installed file is a Node launcher with `#!/usr/bin/env node`. Without `/opt/homebrew/bin` in the child environment, `env` cannot find `node`, so the process exits before the JSON-RPC handshake. Running the same launcher with a system-only path reproduces `env: node: No such file or directory`.

The fetcher also drains and discards the helper's standard error. The user-facing failure becomes the less useful `codex app-server closed stdout`, which hid the missing-Node cause. `UsageProvider` correctly falls back to the cached snapshot, but `ProfileCardView` renders stale and available snapshots the same way. The moving reset countdown made the old values look live.

## Preferences

Add `RefreshPreferences.swift` in the app target. It will define a `RefreshInterval` enum and a small `RefreshPreferences` value type backed by `UserDefaults`.

`RefreshInterval` will expose the five supported choices and an optional timer duration:

| Choice | Timer duration |
| --- | ---: |
| Manual | None |
| 1 minute | 60 seconds |
| 2 minutes | 120 seconds |
| 5 minutes | 300 seconds |
| 15 minutes | 900 seconds |

The stored interval defaults to 5 minutes. An unknown raw value also falls back to 5 minutes. `refreshWhenMenuOpens` defaults to `false`. These settings belong in `UserDefaults` because they control this app instance rather than profile identity or portable auth configuration.

The General tab will gain a `REFRESHING` section between Startup and Support. It will contain an interval picker and the menu-open toggle. Choosing an interval will call a settings action supplied by `AppDelegate`, which invalidates the old timer and applies the new cadence immediately. The toggle needs no callback because `menuWillOpen` reads the stored value each time.

Manual mode disables only the repeating timer. Launch, app activation, system wake, profile switching, explicit Refresh, and an enabled menu-open refresh continue to use their existing paths.

## Persistent refresh action

Add `PersistentRefreshMenuItem.swift` in the app target. It will contain two focused AppKit types:

1. `PersistentActionMenu`, an `NSMenu` subclass that intercepts Command-R while tracking and invokes a refresh closure without closing.
2. `PersistentRefreshMenuView`, an `NSView` used as an `NSMenuItem` custom view.

The refresh view will render the current `arrow.clockwise` symbol and `Refresh` label with native menu spacing and colors. It will accept the first click, provide a button accessibility role and label, and expose `setEnabled(_:)`. Disabled state removes highlighting, dims the icon and label, and ignores mouse and accessibility activation. The implementation will borrow the proven behavior from CodexBar's persistent refresh row, trimmed to this app's needs.

`AppDelegate` will create `PersistentActionMenu` instead of a plain `NSMenu`. The menu and row will share the same refresh closure. The custom `NSMenuItem` keeps its title and tooltip for menu semantics, while its view handles pointer activation. Settings and Quit remain ordinary items and keep their normal closing behavior.

`AppDelegate` will weakly retain the current refresh view. Rebuilding an open menu replaces that reference with the new row. This avoids retaining a removed menu item and keeps disabled state accurate after live data changes.

## Refresh flow

All calls from `AppDelegate` will go through a small `requestUsageRefresh(force:)` helper:

1. Call the existing `UsageProvider.refreshAll(force:)` method.
2. Read `usageProvider.isRefreshing` after the call.
3. Enable or disable the current refresh row to match that state.

No changes are needed in `UsageProvider`. Its existing `isRefreshing` guard coalesces manual, timer, lifecycle, and menu-open requests.

`menuWillOpen` will sync the active profile and build the menu before starting network work. If `refreshWhenMenuOpens` is enabled, it will request a forced refresh and schedule the existing short retry. If the setting is off, it will do neither. The forced request gives the setting its literal meaning: each menu opening asks for current usage unless another refresh is already running.

The repeating timer will use the selected duration. Changing the picker calls `startPeriodicRefreshTimer()` immediately. That method always invalidates the previous timer first. Manual mode then returns without creating another timer.

A manual click or Command-R calls `requestUsageRefresh(force: true)`. Because the callback runs inside the custom view or menu override, AppKit keeps tracking the menu. The row disables synchronously. When `onRefreshComplete` fires, `AppDelegate` updates the status icon and rebuilds the open menu with current snapshots. The newly created Refresh row is enabled because `isRefreshing` is false.

If the user closes the menu during a fetch, the fetch continues. The status icon still updates on completion, and the next opening builds from the latest stored state.

## Codex helper environment

`CodexCLIResolver` will expose one child-environment builder based on the same effective path it uses for executable discovery. `CLIUsageFetcher.fetch` will use that environment before starting `CodexRPCClient`. This keeps the resolved `codex` launcher and its interpreter on the same path. Existing environment entries come first, followed by the app's known Homebrew and system fallbacks, with duplicates removed.

This applies whether `codex` is a native binary, a script, or an explicit `CODEX_CLI` override. Native binaries are unaffected. Script launchers can find their interpreter and sibling tools.

`CodexRPCClient` will retain only a short bounded tail of standard error. If the child closes stdout before a response, the error will include an excerpt when one exists. The buffer must stay bounded, and the excerpt must pass through `LogRedactor` before it enters an error or log message.

## Cached-state presentation

`ProfileCardView` will distinguish `.stale` from `.available` without adding another row to every profile card. A stale card will show a compact amber `Cached` label in its header while continuing to show the last good bars and reset dates. A successful fetch removes the label. `Re-login needed` keeps its current warning treatment.

The app will not erase cached values on a transient failure. Cached data is still useful for comparison, but the label makes its age and reliability clear. Debug Info continues to carry the detailed last error and cache age.

## Errors and edge cases

- Fetch failures keep the existing cached or stale profile state. The Refresh row re-enables after the refresh task completes.
- A stale snapshot shows `Cached`; it cannot be mistaken for a successful live refresh.
- A script-based Codex launcher receives the same effective path used to discover it.
- A helper that exits before replying reports a bounded, redacted standard-error excerpt when available.
- Opening the menu during a timer refresh does not start duplicate work. The open menu still updates when that refresh completes.
- Clicking a disabled row or pressing Command-R while refreshing does nothing.
- Selecting Manual while a refresh is running stops future timer ticks but does not cancel the current fetch.
- Changing from Manual to a timed interval starts a fresh timer period from the settings change. It does not force an immediate fetch.
- Unknown persisted interval values fall back to 5 minutes.
- The menu-open retry is active only when menu-open refresh is enabled and is cancelled when the menu closes.

## Verification

Rebuild first with `./build.sh`, then run the loose menu bar app.

1. Confirm a fresh install shows 5 minutes and leaves `Refresh when the menu opens` off.
2. Change each interval and confirm the selection survives closing and reopening Settings. Relaunch once to confirm persistence.
3. Select Manual and confirm no periodic timer is created through app logs or debugger inspection. Confirm manual, launch, activation, and wake refresh paths still work.
4. Leave menu-open refresh off, open the menu repeatedly, and confirm no menu-open fetch is logged.
5. Enable it, reopen the menu, and confirm one forced fetch starts while the menu remains usable.
6. Click Refresh and press Command-R in separate runs. Confirm the menu stays open, the row disables during the fetch, visible rates update, and the row enables afterward.
7. Trigger a second manual or menu-open refresh while one is active and confirm only one fetch runs.
8. Close the menu during a refresh, wait for completion, and confirm the status icon and next menu opening show the result.
9. Launch the packaged app from Finder or Login Items with no Homebrew path in its inherited environment. Confirm the Homebrew Codex launcher fetches current rates.
10. Force the helper to launch with a missing interpreter. Confirm the error names the missing program without exposing credentials, and the menu marks prior values as `Cached`.
11. Compare one active account against Codex: the menu's used percentage must equal `100 - usage remaining` for the same window and reset date.
12. Run the focused Codex rate-limit tests, `make check`, and `git diff --check`.

## Execution Signals

### Component to file-surface map

| Component | File surface |
| --- | --- |
| Refresh preference model | Create `Sources/CodexProfileSwitcherApp/RefreshPreferences.swift` |
| Persistent menu action | Create `Sources/CodexProfileSwitcherApp/PersistentRefreshMenuItem.swift` |
| Refresh lifecycle and menu wiring | Modify `Sources/CodexProfileSwitcherApp/AppDelegate.swift` |
| General settings UI | Modify `Sources/CodexProfileSwitcherApp/SettingsViews.swift` |
| Codex launcher environment and exit diagnostics | Modify `Sources/CodexProfileCore/Usage/CodexRPCClient.swift` |
| Cached-state presentation | Modify `Sources/CodexProfileSwitcherApp/MenuViews.swift` |
| Fetch environment regression coverage | Modify `Tests/AuthBlobTests/CodexRateLimitsTests.swift` |
| User documentation | Modify `README.md` |

SwiftPM includes new files by target directory, so `Package.swift` and generated artifacts do not change.

### Dependency edges

- General settings and `AppDelegate` depend on the preference model.
- `AppDelegate` depends on the persistent menu types.
- Usage refresh depends on the resolver's child environment.
- Cached-state presentation depends on the existing `.stale` status set by `UsageProvider` after a fetch error.
- Documentation depends on the final setting names and behavior.
- The two new files are independent of each other, but their wiring in `AppDelegate` should happen after both exist.

### Irreversible or destructive steps

None. The change writes two reversible `UserDefaults` preferences. It does not mutate profile data, auth data, cache formats, external services, or real user records.

### External dependencies

No new dependency. CodexBar is a source and behavior reference, not a build dependency. Packaged-app verification uses the Codex CLI already installed on the test Mac.

### Estimated span

Single session. The implementation touches eight files and has no migration or rollout dependency. The preference/menu work and fetch-environment work can be implemented independently before final integration.

## Post-Implementation

Run `staffcheck` after implementation and fix confirmed findings. This plan is load-bearing because its file surface is greater than five files. After staffcheck stabilizes the diff, run `codex-challenge` once in implementation review mode against the full branch diff with `REVIEW_ONLY: true`. Apply only accepted findings, reproduce each failure, run affected verification, audit the final delta, and commit fixes that pass.

Do not run `simplify` unless requested. No manual setup, secrets, migrations, or service configuration will be required from the user.
