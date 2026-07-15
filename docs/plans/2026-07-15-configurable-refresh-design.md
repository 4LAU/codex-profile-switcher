# Configurable Refresh Design

## Problem

Usage data should stay current without interrupting menu interaction. Users need control over the background cadence and whether opening the menu fetches fresh data. A manual refresh must update the open menu in place instead of dismissing it.

## Goals

- Add Manual, 1 minute, 2 minute, 5 minute, and 15 minute refresh intervals. Keep 5 minutes as the default.
- Add a `Refresh when the menu opens` setting, off by default.
- Keep the menu open when Refresh or Command-R starts a fetch.
- Disable the Refresh row while any usage refresh is running, then enable it when the fetch finishes.
- Continue using `UsageProvider` to suppress overlapping work and preserve cached data on failure.

## Non-goals

- Provider-specific schedules
- Notifications or refresh cancellation controls
- Changes to usage fetching, authentication, or cache formats
- A broader menu rewrite
- CodexBar's multi-provider menu coordination system

## Reference

[CodexBar](https://github.com/steipete/CodexBar) uses an app preference for menu-open refresh and a custom AppKit menu row for actions that must not end menu tracking. It is MIT-licensed, as is this repository. This implementation will adapt that interaction pattern to the existing single-menu architecture without copying CodexBar's provider, viewport, or menu-reconciliation machinery.

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

## Errors and edge cases

- Fetch failures keep the existing cached or stale profile state. The Refresh row re-enables after the refresh task completes.
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
9. Run `make check` and `git diff --check`.

## Execution Signals

### Component to file-surface map

| Component | File surface |
| --- | --- |
| Refresh preference model | Create `Sources/CodexProfileSwitcherApp/RefreshPreferences.swift` |
| Persistent menu action | Create `Sources/CodexProfileSwitcherApp/PersistentRefreshMenuItem.swift` |
| Refresh lifecycle and menu wiring | Modify `Sources/CodexProfileSwitcherApp/AppDelegate.swift` |
| General settings UI | Modify `Sources/CodexProfileSwitcherApp/SettingsViews.swift` |
| User documentation | Modify `README.md` |

SwiftPM includes new files by target directory, so `Package.swift` and generated artifacts do not change.

### Dependency edges

- General settings and `AppDelegate` depend on the preference model.
- `AppDelegate` depends on the persistent menu types.
- Documentation depends on the final setting names and behavior.
- The two new files are independent of each other, but their wiring in `AppDelegate` should happen after both exist.

### Irreversible or destructive steps

None. The change writes two reversible `UserDefaults` preferences. It does not mutate profile data, auth data, cache formats, external services, or real user records.

### External dependencies

None. CodexBar is a source and behavior reference, not a build dependency.

### Estimated span

Single session. The implementation touches five files and has no migration or rollout dependency.

## Post-Implementation

Run `staffcheck` after implementation and fix confirmed findings. This plan is not load-bearing: it is reversible, does not touch auth, migrations, money, or a public contract, affects no more than five implementation files, and uses an established AppKit pattern. A cross-vendor challenge review is not required.

Do not run `simplify` unless requested. No manual setup, secrets, migrations, or service configuration will be required from the user.
