# Token Renewal

## Problem

Codex does not refresh a credential while it is being used successfully. It
reaches for its own refresh after the credential is stale, at roughly eight
days. Several subsystems can then refresh at nearly the same time with the
same single-use refresh token. The first request wins. Later requests present
a spent token.

OAuth refresh-token rotation treats a replay as theft and can revoke the
token chain. The observed result is an interactive sign-in roughly every
eight to ten days. The concurrent-refresh explanation is inferred from that
pattern and upstream reports. No live credential has been observed through
that sequence. A failed refresh writes no replacement credential, so a broken
chain remains broken until an interactive sign-in.

## Decision

Add `codex-profile renew` and run it ahead of Codex's stale-credential point.
The renewal policy marks a credential due after three days without a recorded
refresh. Renewal groups profiles by their exact refresh token. One request is
made for each group.

The command reports one record per selected profile. Records identify the
profile, action, reason, refresh age, and a short credential fingerprint. The
report also counts the HTTP requests made. A rejected credential requires an
interactive login. An unreachable endpoint leaves the stored credential
unchanged.

## Renewal Flow

The command loads configured and stored profile IDs, then parses OAuth
credentials from the vault. API-key profiles, missing auth, and invalid auth
produce skipped records. A selected profile expands to every profile with the
same refresh token.

For each credential group, renewal checks the recorded refresh age. `--force`
overrides that check. A current lease reserves the group from renewal. This
also covers an `exec` run, a `lease` session, and a `best-auth --dir` export.
After a successful request, the command writes the rotated credential back to
each profile in the group and exits.

The app registers a background LaunchAgent through `SMAppService`. The agent
calls the helper once each day and exits. The bundled schedule is 03:00. The
Settings view reports whether the service is enabled, disabled, awaiting
approval, or unavailable. An awaiting-approval state leaves renewal
unscheduled until the user approves the item in Login Items.

## Safety

The shared usage cache lock covers reservation and commit. A group gets one
reservation for the duration of its renewal. Another process sees that
reservation and skips the group, so only one request for that credential can
be in flight.

Before the request, the command proves that every profile in the group still
has the expected refresh token. It stages a replacement for every profile.
Commit checks the reservation, checks every current token again, and verifies
each replacement's identity before saving any replacement. This prevents a
concurrent profile switch or credential write from leaving the group
partially rotated.

The rotated data is also staged in a private recovery area before commit. If
the process stops after the request, a later run can validate the staged data
against the predecessor token and recover it. Staged data is removed after a
successful commit. The live `~/.codex/auth.json` is updated only when it holds
the same identity and an older refresh than a stored copy.

`--dry-run` reads the vault and cache and reports what would happen. It does
not reserve, renew, stage, commit, or record state.

## Verification

Unit tests cover the three-day threshold, missing and future refresh dates,
successful rotation, refresh-token rotation, rejected responses, unreachable
responses, and preservation of existing credentials on failure. CLI
verification must check shared-token grouping, one request per group, lease
exclusion, dry-run side effects, recovery after interruption, concurrent
writers, and the JSON report.

The packaged plist must contain the helper path, `renew` argument, a daily
`StartCalendarInterval`, and `RunAtLoad` set to false. The package script must
build both arm64 and x86_64 by default. The public checks include a clean
documentation grep for private references and a full build and test run.
