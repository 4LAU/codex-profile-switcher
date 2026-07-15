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
