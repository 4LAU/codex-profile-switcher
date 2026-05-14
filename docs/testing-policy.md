# Testing Policy

Test what fails silently. Delete everything else.

Every test in this repo must answer:

> Without this test, a change could ship that [X] and nobody would know until Codex launched with the wrong account, usage went stale or misleading, or saved auth was silently corrupted.

If you cannot finish that sentence, delete the test.

## Core Rule

Tests own silent account, auth, usage, and credential-safety failures.

For this project, the risky failures are:

- overwriting `~/.codex/auth.json` with the wrong profile
- failing to preserve the outgoing live account during a switch
- misidentifying which saved profile matches live auth
- showing usage that belongs to the wrong account
- claiming a profile is healthy when it needs re-login
- leaking tokens, cookies, auth codes, API keys, or email addresses into logs/debug output

Those are the bugs tests exist to catch.

## Three-Gate Check

Before writing or keeping a test, ask:

1. Would this failure be obvious in normal use?
2. Does Swift, Foundation, Security, or the OS already enforce it?
3. Is the same behavior already covered by a stronger integration test?

If the answer is `yes` to any of these, do not write the test.

Delete tests for:

- menu layout, labels, colors, icons, or alert copy
- "does not crash" rendering checks
- helper command failures where the user already gets a clear non-zero exit and no state transition occurs
- resolver preference checks duplicated by a real login/switch integration test
- Codable or JSON shape checks whose failure would stop the operation visibly
- wiring tests that only prove one method called another
- every variation of the same error string

## Test Levels

Use the lowest level that catches the real silent regression.

### Unit Tests

Use unit tests only for pure logic with silent failure modes:

- auth identity extraction and fingerprinting
- duplicate-profile detection inputs
- preserving real auth fields during refresh normalization
- log redaction
- OAuth/CLI usage classification where the wrong value still looks plausible
- cached-status state transitions

Do not unit-test orchestration. If the behavior crosses files, subprocesses, or saved auth, use integration coverage.

### Integration Tests

Integration tests are the load-bearing floor for this repo.

Use them for:

- profile switching against a temp `HOME`
- live auth copy/restore behavior
- saved auth persistence in a file-backed vault
- isolated `codex login`
- CLI usage fallback using a fake `codex` binary
- keychain migration/repair behavior through the test vault
- workspace launch handoff to the fake Codex app

Integration tests must be hermetic:

- use `CODEX_PROFILE_HOME`
- use `CODEX_PROFILE_TEST_AUTH_STORE_DIR`
- use fake `codex` and fake `Codex.app` binaries
- never read or write the real macOS Keychain
- never touch the real `~/.codex` or `~/.codex-switcher`
- never hit the network

### End-to-End Tests

End-to-end tests are justified only for full user journeys where a silent failure crosses boundaries.

Required flows:

1. Profile switch preserves outgoing auth and restores selected auth.
2. Switch refuses unmanaged live auth instead of overwriting it.
3. Ambiguous live auth never picks the wrong saved profile silently.
4. Initial login stores auth in the selected saved profile without touching live auth.
5. Re-auth for the active profile updates saved and live auth together.
6. Usage refresh falls back from OAuth to CLI correctly.
7. Usage refresh marks re-login needed when both auth paths require auth.
8. Logs and debug output stay redacted end to end.

Do not use E2E tests to cover every branch. Use them to prove the app and helper preserve the account-safety invariants together.

## Fixture Rules

Use real-shaped auth files and CLI responses.

- Keep fixtures minimal but structurally real.
- Prefer inline fixtures for tiny auth blobs.
- Add `Tests/Fixtures/` only when a fixture is reused or too large to read inline.
- Document unusual fixtures such as duplicate identities or revoked refresh tokens.

Synthetic placeholders are fine for pure redaction tests. They are not enough for auth identity or usage parsing tests.

## Mock Discipline

Mock only true external boundaries:

- network fetches
- subprocess binaries
- macOS app launch boundary
- the auth vault when testing migration failure behavior

Do not mock:

- auth parsing
- profile matching
- redaction logic
- cache/config persistence
- the switch helper's internal steps

If a test mocks multiple internal layers, it is a wiring test. Delete or rewrite it as an integration test.

## Flake Policy

Flaky tests are deleted or rewritten. Do not add retries.

Fix the harness instead:

- own the temp filesystem
- own the fake binaries
- own the clock input where needed
- wait on explicit process or file signals, not arbitrary sleeps

## Current High-Value Coverage

Keep coverage centered on these invariants:

- switching saves the outgoing live auth before restoring the target profile
- unmanaged or ambiguous live auth cannot be silently overwritten
- active duplicate profiles are disambiguated by configured active profile
- isolated login writes only to the selected saved profile
- auth migration/repair preserves saved auth and does not mark success after failure
- usage fetched through the CLI receives the selected auth and copied Codex config
- redaction removes credentials and PII before logs/debug output can expose them

Everything else is a delete candidate.
