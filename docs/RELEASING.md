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

After the release, commit and push the updated `appcast.xml` so the feed URL
serves the new version:

```bash
git add appcast.xml
git commit -m "docs: update appcast for v<version>"
git push
```

The release also generates a Homebrew cask at
`.build/release/codex-profile-switcher.rb`. Publish the DMG to a GitHub release
before updating a tap with that cask.

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

After running `Scripts/release_app.sh`, copy or commit the generated cask into
the tap:

```bash
cp .build/release/codex-profile-switcher.rb ../homebrew-tap/Casks/
cd ../homebrew-tap
brew audit --cask --strict Casks/codex-profile-switcher.rb
brew install --cask --verbose ./Casks/codex-profile-switcher.rb
git add Casks/codex-profile-switcher.rb
git commit -m "Update codex-profile-switcher <version>"
git push
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
