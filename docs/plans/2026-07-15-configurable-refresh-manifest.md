# Program Manifest: Configurable Refresh and Fresh Usage

---

# REGION 1: FROZEN BASELINE

> Nothing above the `END FROZEN BASELINE` marker changes after approval. Corrections and scope changes go in the dated log below.

- **Program:** Configurable Refresh and Fresh Usage
- **Date created:** 2026-07-15
- **Objective:** Add user-controlled refresh timing, keep manual refreshes inside the open menu, and make displayed Codex usage current and visibly cached when a fetch fails.
- **Program branch:** `program/configurable-refresh`
- **Base branch:** `main`
- **base_sha:** `5b4362c1304c9fc91b722fa7d066850cabc9c1bc`

## In-Scope Inventory

| # | Item | Type | Wave | Risk | Blast radius | Expected count |
|---|------|------|------|------|--------------|----------------|
| 1 | `docs/plans/2026-07-15-configurable-refresh-manifest.md` | program record | Phase 0 | low | A bad inventory could omit work or validation | — |
| 2 | `Sources/CodexProfileCore/Usage/CodexRPCClient.swift` | source | 1 | medium | Affects Codex usage fetches in both the menu app and CLI | — |
| 3 | `Sources/CodexProfileSwitcherApp/RefreshPreferences.swift` | new source | 2 | low | Controls timer cadence and menu-open refresh behavior | — |
| 4 | `Sources/CodexProfileSwitcherApp/PersistentRefreshMenuItem.swift` | new source | 2 | medium | Controls click, Command-R, hover, accessibility, and menu tracking | — |
| 5 | `Sources/CodexProfileSwitcherApp/AppDelegate.swift` | source | 2 | medium | Coordinates every refresh entry point, timer, menu rebuild, and Settings callback | — |
| 6 | `Sources/CodexProfileSwitcherApp/SettingsViews.swift` | source | 2 | low | Changes General Settings and the `SettingsActions` handoff | — |
| 7 | `Sources/CodexProfileSwitcherApp/MenuViews.swift` | source | 2 | low | Changes how stale profile snapshots are labeled | — |
| 8 | `README.md` | docs | 3 | low | Documents user-visible behavior and CodexBar attribution | — |
| 9 | `THIRD_PARTY_NOTICES.md` | new legal notice | 3 | low | Retains CodexBar's MIT notice for adapted source | — |
| 10 | `docs/plans/2026-07-15-configurable-refresh-design.md` | design record | 3 | low | Records audited details that were missing from the original design | — |

## Blast-Radius Findings

- `CodexCLIResolver` currently widens `PATH` only while locating `codex`. The child receives the original environment, so a Homebrew launcher using `#!/usr/bin/env node` can be found and then fail before JSON-RPC starts.
- Standard error is drained and discarded. The replacement must keep a short, thread-safe tail, wait for final bytes at EOF, and redact it before it enters an error or log.
- `UsageProvider` already prevents overlap, preserves cached snapshots, and reports completion. It does not need a code change.
- `AppDelegate` has ten direct refresh call sites. They must share one helper or the persistent row can show the wrong enabled state.
- CodexBar's custom refresh row depends on explicit menu-highlight forwarding. Copying only the view would miss native hover and keyboard highlight behavior.
- Cached snapshots are stale on startup until the first successful fetch. The `Cached` label should appear then as well as after a failed refresh.
- SwiftPM discovers new files in existing target directories. `Package.swift` and generated files do not change.
- Verification follows the repository-wide policy: no new test files. The failure modes are visible and can be checked with hermetic fake launchers plus the running app. Existing suites still run at every gate.

## Out of Scope

- `Sources/CodexProfileSwitcherApp/UsageProvider.swift`, `ProfileStore.swift`, and `ProfileModels.swift`: the existing overlap and stale-state behavior is sufficient.
- `Package.swift`, lockfiles, generated files, cache formats, profile configuration, authentication, and Keychain data.
- Provider-specific schedules, notifications, refresh cancellation, and a wider menu rewrite.
- CodexBar's 30-minute and Adaptive intervals, provider system, viewport coordination, and multi-provider refresh loop.
- New automated test files. Gates use the existing suite, hermetic one-off probes, and direct AppKit checks.
- The unrelated `docs/keychain-migration-plan.html` working-tree file and every branch or worktree belonging to the keychain migration program.

## Wave Plan

| Wave | Contents | Risk | Reversible? | Gate criteria |
|------|----------|------|-------------|---------------|
| 1 | Repair child environment and bounded, redacted stderr diagnostics in `CodexRPCClient.swift` | medium | yes | Rebuild first; a hermetic fake CLI launched with stripped `PATH` proves interpreter lookup and redacted early-exit diagnostics; existing focused tests, `make check`, and `git diff --check` pass |
| 2 | Add preferences, persistent refresh row, refresh lifecycle wiring, General Settings controls, and cached-state label | medium | yes | Rebuild first; existing focused tests and `make check` pass; direct checks cover all interval choices, persistence, menu-open off/on, click and exact Command-R tracking, disabled/highlight/accessibility states, in-place data updates, cached label, and Finder-style launch with a stripped inherited `PATH` |
| 3 | Docs closeout: update README and design record; add CodexBar MIT notice; reap every worktree recorded below | low | yes | Docs match shipped labels and defaults; full `make check` and `git diff --check` pass; all recorded program worktrees are gone |

Before Wave 3, run one program-wide `staffcheck` and then `codex-challenge` in `REVIEW_ONLY` mode against `branch:5b4362c1304c9fc91b722fa7d066850cabc9c1bc`. Apply only reproduced and accepted findings, then rerun affected checks.

No wave mutates or deletes user data, so no backup or destructive inventory approval is required. All write tasks are serialized and will have no `[parallel-group]` markers.

**Baseline approved by L:** 2026-07-15

<!-- ===================== END FROZEN BASELINE ===================== -->

---

# REGION 2: AMENDMENT + GATE LOG

> Append dated `AMENDMENT`, `GATE RESULT`, `ESCALATION`, or `WAVE START` entries here. Scope changes and gate clearance require L's approval.

### 2026-07-15: AMENDMENT REQUEST

- **Change:** Add `docs/plans/2026-07-15-configurable-refresh-execution.md` as the durable plan and execution log for Waves 1 through 3.
- **Reason:** Each code-writing wave must have a committed task plan and execution log. The Phase 0 inventory omitted that required program record.
- **Product scope:** Unchanged.
- **Approved by L:** pending.

### 2026-07-15: AMENDMENT APPROVAL

- **Approved change:** Add `docs/plans/2026-07-15-configurable-refresh-execution.md` as the durable plan and execution log for Waves 1 through 3.
- **Approved by L:** 2026-07-15.
- **Logged by:** orchestrator.

### 2026-07-15: WAVE START

- **Wave:** 1.
- **Worktree path:** `/Users/aaron/Code/codex-profile-switcher-3002-worktree3`.
- **Plan branch:** `plan/configurable-refresh-wave-1`.
- **Base branch:** `program/configurable-refresh`.
- **Dev-server port:** none.
- **Logged by:** orchestrator.

### 2026-07-15: GATE RESULT

- **Gate:** Wave 1 to Wave 2.
- **Result:** PASS.
- **Merged commit:** `44d8bde` on `program/configurable-refresh`.
- **Evidence:** The pre-change stripped-`PATH` probe failed with `codex app-server closed stdout`; the same probe at Wave 1 head succeeded with `primary=17`. Boundary probes for bearer, `sk-`, authorization-header, and JSON-token forms exposed no credential fragments. On the merged program branch, `./build.sh`, all 53 Swift tests, integration tests, the production build check, and `git diff --check` passed.
- **Reviews:** Spec, quality, and final whole-wave reviews approved commit `a32877d` with no open findings.
- **Approved by L:** pending.
- **Logged by:** orchestrator.

### 2026-07-15: GATE APPROVAL

- **Gate:** Wave 1 to Wave 2.
- **Result:** APPROVED.
- **Approved by L:** 2026-07-15.
- **Logged by:** orchestrator.

### 2026-07-15: WAVE START

- **Wave:** 2.
- **Worktree path:** `/Users/aaron/Code/codex-profile-switcher-3002-worktree3`.
- **Plan branch:** `plan/configurable-refresh-wave-2`.
- **Base branch:** `program/configurable-refresh`.
- **Dev-server port:** none.
- **Logged by:** orchestrator.

### 2026-07-15: ESCALATION

- **Wave:** 2, halted before Task 4 dispatch.
- **Worktree path:** `/Users/aaron/Code/codex-profile-switcher-3002-worktree3`.
- **Plan branch:** `plan/configurable-refresh-wave-2`.
- **Last approved task:** Task 2 at `cf19627`.
- **Unapproved task commits preserved:** Task 3 through `676b382`.
- **Finding:** `UsageProvider.cancelRefreshes()` lets a cancelled refresh finish after its replacement starts. The cancelled task can clear the replacement's running state and emit completion early, which re-enables the persistent row and permits overlapping work.
- **Evidence:** Task 3 quality review reproduced the race from the `clearSavedAuth` control flow. `./build.sh`, `make check`, and `git diff --check` still pass because the race is not covered by the existing suites.
- **Action:** Stop new writes, preserve the worktree, and request a one-file scope amendment.
- **Logged by:** orchestrator.

### 2026-07-15: AMENDMENT REQUEST

- **Change:** Add `Sources/CodexProfileSwitcherApp/UsageProvider.swift` to Wave 2 as inventory item 11, superseding the frozen out-of-scope statement for this file only.
- **Expected count:** 1 source file.
- **Reason:** Add refresh-generation ownership so only the current task may clear `isRefreshing`, release its task reference, flush completion state, or call `onRefreshComplete`. This closes the cancel-and-restart race without changing auth, cache, profile, or fetch behavior.
- **Plan change after approval:** Insert a serialized Task 3A before the cached-label task, then repeat Task 3 quality review over the combined lifecycle change.
- **Product scope:** Unchanged. This is required to make the approved no-overlap and disabled-for-the-full-refresh behavior true.
- **Approved by L:** pending.
- **Logged by:** orchestrator.
