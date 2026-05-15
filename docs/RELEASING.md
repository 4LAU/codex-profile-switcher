# Release Process

This project is open source, but public macOS releases should still use
Developer ID signing and Apple notarization. That is what lets most users open
the app normally and keeps Keychain prompts limited to initial approval instead
of recurring during ordinary profile switching.

## Prerequisites

- A paid Apple Developer account.
- A `Developer ID Application` certificate installed in your login keychain.
- Xcode command line tools.
- Notarization credentials configured in one of these forms:
  - preferred: `xcrun notarytool store-credentials <profile-name>`
  - fallback: Apple ID, team ID, and app-specific password in environment
    variables.

## One-Time Sparkle Key Setup

Generate the EdDSA keypair used to sign Sparkle updates:

```bash
Scripts/setup_sparkle_keys.sh
```

The private key is stored in your macOS Keychain. Export the public key to your shell profile:

```bash
export SPARKLE_ED_PUBLIC_KEY="$(.build/sparkle/bin/generate_keys -p)"
```

This key is required for release builds — `package_app.sh` will fail if `SPARKLE_ED_PUBLIC_KEY` is unset when `CODEX_PROFILE_REQUIRE_SIGNING=1`.

## One-Time Notary Credential Setup

Run this once on the release machine:

```bash
xcrun notarytool store-credentials notarytool \
  --apple-id "you@example.com" \
  --team-id "TEAMID12345" \
  --password "app-specific-password"
```

The release script can then use:

```bash
NOTARY_KEYCHAIN_PROFILE=notarytool
```

## One-Time Homebrew Dispatch Setup

The source repository dispatches a workflow in `4LAU/homebrew-tap` after a
GitHub Release is published. Add a fine-grained token as
`HOMEBREW_TAP_TOKEN` in this repository's GitHub Actions secrets.

The token should only have access to `4LAU/homebrew-tap`, and only needs
Actions read/write permission.

## Build a Public DMG

```bash
APP_IDENTITY="Developer ID Application: Your Name (TEAMID12345)" \
NOTARY_KEYCHAIN_PROFILE=notarytool \
SPARKLE_ED_PUBLIC_KEY="$(.build/sparkle/bin/generate_keys -p)" \
Scripts/release_app.sh
```

The script:

1. Builds `CodexProfileSwitcher.app` with Sparkle embedded.
2. Signs the helper, Sparkle framework components, and app bundle.
3. Creates `CodexProfileSwitcher-<version>.dmg`.
4. Signs the DMG.
5. Uploads the DMG to Apple for notarization.
6. Staples the notarization ticket to the DMG.
7. Runs Gatekeeper verification.
8. Writes a SHA-256 checksum next to the DMG.
9. Generates a Homebrew cask.
10. Updates `appcast.xml` with the new release (EdDSA-signed).

The output is written under `.build/release/`.

## Optional Validated Keychain Access Group

The shared data-protection Keychain entitlement is opt-in until the production
entitlement path has been proven. Normal contributor and ad-hoc builds should
not set these variables.

To build with a validated shared Keychain access group:

1. In Apple Developer Certificates, Identifiers & Profiles, create or update the
   macOS app identifier for the bundle ID and enable the Keychain Sharing
   capability with the intended access group.
2. Generate a macOS provisioning profile for the same distribution identity and
   app identifier, then download it to the release machine.
3. Build with the access group and provisioning profile path:

```bash
APP_IDENTITY="Developer ID Application: Your Name (TEAMID12345)" \
CODEX_PROFILE_KEYCHAIN_ACCESS_GROUP="TEAMID12345.com.example.codex-profile-switcher" \
CODEX_PROFILE_PROVISIONING_PROFILE="/path/to/CodexProfileSwitcher.provisionprofile" \
SPARKLE_ED_PUBLIC_KEY="$(.build/sparkle/bin/generate_keys -p)" \
Scripts/package_app.sh
```

`package_app.sh` verifies that the provisioning profile authorizes the requested
`keychain-access-groups` value, embeds it at
`Contents/embedded.provisionprofile`, signs both the app and helper with
generated entitlements, and runs strict codesign verification plus entitlement
dumps. With `CODEX_PROFILE_REQUIRE_SIGNING=1`, any missing identity, entitlement
file, provisioning profile, or unauthorized access group fails the build instead
of falling back to ad-hoc signing.

Useful release verification commands:

```bash
codesign --verify --strict --verbose=2 CodexProfileSwitcher.app
codesign -d --entitlements :- CodexProfileSwitcher.app
codesign --verify --strict --verbose=2 CodexProfileSwitcher.app/Contents/Helpers/codex-profile
codesign -d --entitlements :- CodexProfileSwitcher.app/Contents/Helpers/codex-profile
security cms -D -i CodexProfileSwitcher.app/Contents/embedded.provisionprofile | \
  plutil -extract Entitlements.keychain-access-groups raw -o - -
```

After the release, commit and push the updated `appcast.xml` so the feed URL
serves the new version:

```bash
git add appcast.xml
git commit -m "docs: update appcast for v<version>"
git push
```

The release also generates a Homebrew cask at
`.build/release/codex-profile-switcher.rb` as a local fallback. The normal
Homebrew tap update is automated after the GitHub Release is published.

## Homebrew Cask

Publish the macOS app through a Homebrew cask once the public DMG is uploaded to
GitHub Releases:

```bash
brew install --cask 4lau/tap/codex-profile-switcher
```

The generated cask assumes:

- the GitHub release tag is `v<version>`
- the release asset is `CodexProfileSwitcher-<version>.dmg`
- the tap repository contains `Casks/codex-profile-switcher.rb`

After the notarized DMG is uploaded to the GitHub Release, publishing that
release triggers `.github/workflows/update-homebrew.yml`. That workflow
dispatches `4LAU/homebrew-tap`'s `update-cask.yml` workflow with:

- `cask=codex-profile-switcher`
- `repository=4LAU/codex-profile-switcher`
- `tag=v<version>`
- `artifact=CodexProfileSwitcher-<version>.dmg`

The tap workflow downloads the public DMG, computes the SHA-256, updates
`Casks/codex-profile-switcher.rb`, commits, and pushes the tap change.

If the automatic dispatch fails, run the tap workflow manually:

```bash
gh workflow run update-cask.yml \
  --repo 4LAU/homebrew-tap \
  --ref main \
  -f cask=codex-profile-switcher \
  -f repository=4LAU/codex-profile-switcher \
  -f tag=v<version> \
  -f artifact=CodexProfileSwitcher-<version>.dmg
```

If the repository, release tag, or tap name differs, override the generator:

```bash
GITHUB_REPOSITORY="owner/codex-profile-switcher" \
TAG_NAME="v0.1.0" \
CASK_OUTPUT_PATH="../homebrew-tap/Casks/codex-profile-switcher.rb" \
Scripts/generate_homebrew_cask.sh
```

## Local Dry Run

This mode is only for checking the DMG creation path. Do not publish the result.

```bash
APP_IDENTITY="Developer ID Application: Your Name (TEAMID12345)" \
CODEX_PROFILE_RELEASE_SKIP_NOTARIZATION=1 \
Scripts/release_app.sh
```

## Keychain Smoke

Before publishing a release, run the signed Keychain smoke against the same
Developer ID identity:

```bash
APP_IDENTITY="Developer ID Application: Your Name (TEAMID12345)" \
Scripts/keychain_signed_smoke.sh
```

For the validated access-group path, include the same
`CODEX_PROFILE_KEYCHAIN_ACCESS_GROUP` and `CODEX_PROFILE_PROVISIONING_PROFILE`
values used for the build. The smoke uses a disposable
`CODEX_PROFILE_KEYCHAIN_SERVICE` value by default and performs a launched helper
Keychain round-trip. Run it manually only; it can trigger interactive macOS
password prompts.

Expected behavior:

- macOS may ask for Keychain approval during the initial profile saves.
- `codex-profile keychain-repair` should complete against the signed helper.
- Repeat profile switches should complete without repeated prompts after
  approval.

Do not add this smoke to CI. It is intentionally manual because it can trigger
interactive macOS password prompts.

## User-Facing Prompt Expectation

For a normal release, users should expect:

1. A standard first-open macOS warning because the app was downloaded from the
   internet.
2. A Keychain prompt when profile auth is first saved or first accessed.
3. No recurring password prompt on every ordinary profile switch after access is
   approved.

Recurring prompts during every switch should be treated as a release-blocking
bug.
