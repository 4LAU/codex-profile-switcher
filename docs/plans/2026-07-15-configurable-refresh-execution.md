# Configurable Refresh Execution Plan

This file holds the task plans and execution logs for the waves defined in the frozen manifest. Later wave sections are added only after the preceding gate is approved.

## Wave 1: Restore Fresh Codex Usage

### Task 1: Use one launch environment and report useful early exits

Modify only `Sources/CodexProfileCore/Usage/CodexRPCClient.swift`.

Implement these requirements:

- Build the child environment from the same effective `PATH` used to locate `codex`.
- Preserve caller-provided path entries first, append the existing Homebrew and system fallbacks, and remove duplicates without changing order.
- Apply that environment to every `CLIUsageFetcher` launch, including a valid `CODEX_CLI` override.
- Keep a small, bounded tail of standard error inside `CodexRPCClient` instead of discarding it.
- Make concurrent stderr writes and error reads safe. Account for stdout closing before the final stderr bytes arrive.
- When app-server closes stdout before replying, include a useful stderr excerpt if one exists.
- Pass the excerpt through `LogRedactor` before it enters `CodexRPCError` or any log.
- Keep existing timeout, shutdown, auth, cache, and JSON-RPC behavior unchanged.
- Do not add or modify test files. Verification uses a temporary fake launcher and the repository's existing suites.

Before editing, rebuild with `./build.sh` and capture a failing hermetic probe that launches a script through `/usr/bin/env` with a stripped `PATH`. After editing:

1. Rebuild with `./build.sh`.
2. Repeat the hermetic probe and show that the interpreter is found through the effective child path.
3. Run a fake helper that writes a sample secret to stderr and exits before JSON-RPC. Show that the error is useful, bounded, and redacted.
4. Run the existing focused Swift tests that cover Codex rate-limit decoding and log redaction.
5. Run `make check` and `git diff --check`.

Keep temporary probe files outside the repository and delete them after the observations are captured.

### Task completion conditions

- Only the assigned source file changes, apart from this execution log.
- The implementation worker reports `DONE` or `DONE_WITH_CONCERNS` and lists changed files.
- A separate spec review confirms every requirement above.
- A separate quality review finds no unresolved correctness, concurrency, privacy, or maintainability issue.
- The task commit is merged back to `program/configurable-refresh` before the Wave 1 gate runs.

## Execution Log

- **PLAN START 2026-07-15:** base `program/configurable-refresh`; base_sha `9a3aae15b99dfa2ef6d649f3dc4db324e0d10a4f`; branch `plan/configurable-refresh-wave-1`; worktree `/Users/aaron/Code/codex-profile-switcher-3002-worktree3`; port none.

## Wave 2: Configurable, In-Place Refresh

All tasks are serialized. Do not add `[parallel-group]` markers, test files, or files outside the frozen inventory.

### Task 1: Store refresh preferences

Create only `Sources/CodexProfileSwitcherApp/RefreshPreferences.swift`.

Implement these requirements:

- Define the refresh interval choices Manual, 1 minute, 2 minutes, 5 minutes, and 15 minutes.
- Give each choice a stable persisted value, a display title, and an optional timer interval. Manual has no timer.
- Store the selected interval in `UserDefaults`, defaulting to 5 minutes when no valid value exists.
- Store `Refresh when the menu opens` in `UserDefaults`, defaulting to off.
- Publish preference changes so the app and an already-open Settings window stay in sync.
- Keep the type confined to the app target. Do not add provider-specific scheduling or migration machinery.

Before editing, rebuild with `./build.sh`. After editing, rebuild again and run a one-off Swift probe or the smallest executable app seam that demonstrates all five choices, the 5-minute fallback, persistence, and the off default. Run `git diff --check`.

### Task 2: Add the persistent refresh menu row

Create only `Sources/CodexProfileSwitcherApp/PersistentRefreshMenuItem.swift`.

Adapt CodexBar's native AppKit pattern at audited commit `c61e01e774c449b06324a1cc260af7c77cf17d47` for this app:

- Add an `NSMenu` subclass that recognizes only exact Command-R while menu tracking is active. Extra modifiers must not trigger refresh.
- Add a custom refresh menu item and view that call a supplied refresh closure without ending menu tracking.
- Match a normal macOS menu row: refresh symbol, title, Command-R hint, hover and keyboard highlight, enabled and disabled appearance, and accessibility role, label, help, and enabled state.
- Expose the smallest API needed for `AppDelegate` to update enabled state and forward `menu(_:willHighlight:)` changes.
- Keep the implementation independent of profile and usage-provider types.

Before editing, rebuild with `./build.sh`. After editing, rebuild again and run a small AppKit probe that demonstrates click and exact Command-R invoke the closure without cancelling tracking, Command-Shift-R does not, disabled state blocks activation, highlight state changes, and the accessibility values are present. Run `git diff --check`.

### Task 3: Wire every refresh path and add General Settings controls

Modify only `Sources/CodexProfileSwitcherApp/AppDelegate.swift` and `Sources/CodexProfileSwitcherApp/SettingsViews.swift`.

Implement these requirements:

- Construct the status menu with the persistent menu class and replace the existing Refresh `NSMenuItem` with the persistent refresh row.
- Keep a weak reference to the current refresh row. Forward `menu(_:willHighlight:)` so its custom view receives native menu highlight changes.
- Route all existing usage-refresh entry points through one helper. The helper must keep the row disabled for the full active refresh and prevent overlapping work, then let `UsageProvider.onRefreshComplete` re-enable it and rebuild the open menu in place.
- Manual Refresh and exact Command-R force a refresh and leave the menu open. Preserve the existing behavior of actions that intentionally close the menu, including Settings and profile switching.
- Respect the stored interval. Manual disables the timer; the other choices schedule their exact minute value. Rebuild the timer as soon as Settings changes the interval.
- On menu open, always sync and render current data first. Start the forced refresh and the existing stale-data retry only when `Refresh when the menu opens` is enabled. Its default is off.
- Keep launch, app activation, wake, login, profile switch, clear-auth, and other existing refresh semantics intact, including which paths force a fetch.
- Extend `SettingsActions` with the callback needed to reschedule refresh behavior. Pass the same shared preferences object into `SettingsView` and `GeneralTab`.
- In General Settings, insert a `REFRESHING` section between Startup and Support. Add a native picker labeled `Refresh interval` with Manual, 1 min, 2 min, 5 min, and 15 min, plus a `Refresh when the menu opens` toggle. When Manual is selected, show the concise hint that automatic background refresh is off and manual refresh remains available from the menu or Command-R.
- Keep the visual treatment consistent with the existing settings window and the supplied CodexBar reference. Do not redesign the window or change its size unless the controls cannot fit.

Before editing, rebuild with `./build.sh`. After editing, rebuild again. Launch the dev app with isolated profile and Keychain-service environment values and directly check: every picker choice, persisted settings after reopening the window, timer removal for Manual, immediate timer rescheduling, menu-open off and on, disabled refresh while active, click and exact Command-R keeping the menu open, in-place profile updates after completion, and Settings still closing the menu. Run the existing focused Swift tests, `make check`, and `git diff --check`.

### Task 4: Mark cached usage in the menu

Modify only `Sources/CodexProfileSwitcherApp/MenuViews.swift`.

Implement these requirements:

- When a profile status is `.stale`, show a compact amber `Cached` label in the profile header.
- Keep the existing usage bars when a stale snapshot exists and `No data yet` when it does not.
- Use the existing header space. Do not add a row or change card height.
- Make the label disappear as soon as the status returns to `.available`.
- Preserve the existing plan and credit metadata.

Before editing, rebuild with `./build.sh`. After editing, rebuild again and use an isolated SwiftUI/AppKit preview or running-app state to show stale-with-snapshot, stale-without-snapshot, and available states. Run `git diff --check`.

### Task 3A: Keep cancelled refreshes from completing replacements

Modify only `Sources/CodexProfileSwitcherApp/UsageProvider.swift`.

Implement refresh-generation ownership so a cancelled task that finishes late cannot clear the running state or task reference of a newer refresh, flush its completion state, or call `onRefreshComplete` for that newer refresh. Preserve profile fetching, cancellation, cache, auth, and concurrency-limit behavior.

Verify with a bounded one-off probe that starts refresh A, cancels it, starts refresh B, and lets A unwind after B begins. The observation must show that B remains the sole current refresh and only B emits completion. Do not add a test file.

### Compressed remaining review

Tasks 3A and 4 run in one serialized implementation pass and remain separate commits. After both land, one spec reviewer checks Tasks 3, 3A, and 4 together, followed by one quality reviewer over the same combined range. Run one final `./build.sh`, the focused existing suites, `make check`, all direct Wave 2 probes, and `git diff --check` before the Wave 2 merge.

### Wave 2 completion conditions

- Each task is committed separately on the Wave 2 plan branch.
- After each task, a separate spec reviewer confirms the task matches its requirements, followed by a separate quality reviewer with no open findings.
- A final reviewer checks the whole Wave 2 diff for refresh lifecycle, menu tracking, preference persistence, accessibility, and stale-state correctness.
- The merged program branch passes `./build.sh`, the existing focused tests, `make check`, `git diff --check`, and the direct checks named in the manifest gate.
