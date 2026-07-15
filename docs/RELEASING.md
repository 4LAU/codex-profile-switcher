# Release Process

This project is open source, but public macOS releases should still use
Developer ID signing and Apple notarization. The release also embeds the
existing Developer ID provisioning profile required for Data Protection
Keychain storage.

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

Run this once on the release machine. Preferred: an App Store Connect API key
(`.p8` file, key ID, and issuer ID from
[App Store Connect → Users and Access → Integrations → App Store Connect API](https://appstoreconnect.apple.com/access/integrations/api)):

```bash
xcrun notarytool store-credentials <profile-name> \
  --key "AuthKey_XXXXXXXXXX.p8" \
  --key-id "XXXXXXXXXX" \
  --issuer "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
```

Fallback (Apple is phasing app-specific passwords out for notarization):

```bash
xcrun notarytool store-credentials <profile-name> \
  --apple-id "you@example.com" \
  --team-id "TEAMID12345" \
  --password "app-specific-password"
```

Either way, the release script then uses:

```bash
NOTARY_KEYCHAIN_PROFILE=<profile-name>
```

## One-Time Homebrew Dispatch Setup

The source repository dispatches a workflow in `4LAU/homebrew-tap` after a
GitHub Release is published. The dispatch token is gated behind a protected
GitHub environment so it is only exposed to release runs:

1. Create a tag ruleset that restricts creation, update, and deletion of
   `v*` tags to repository admins (Settings → Rules → Rulesets).
2. Create an environment named `release` (Settings → Environments) and limit
   its deployment branches and tags to the `v*` tag pattern plus the `main`
   branch. `main` is required because the manual `workflow_dispatch` fallback
   runs on the main branch ref.
3. Create a fine-grained personal access token with access to only
   `4LAU/homebrew-tap` and Actions read/write permission. Add it as an
   **environment secret** named `HOMEBREW_TAP_TOKEN` under the `release`
   environment — not as a repository-level secret.

The `update-cask` job in `.github/workflows/update-homebrew.yml` declares
`environment: release`, which is what makes GitHub apply the gating above
before handing the token to a run.

## Build a Public DMG

```bash
APP_IDENTITY="Developer ID Application: Your Name (TEAMID12345)" \
NOTARY_KEYCHAIN_PROFILE=<profile-name> \
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

For the official bundle ID, the signed smoke performs a disposable
Data Protection Keychain round-trip through the bundled helper. It creates and
removes its own temporary records; it does not touch saved user credentials.

Expected behavior:

- The signed helper saves, reads, switches, and removes only disposable smoke
  credentials.
- A separately rebuilt signed bundle can read the same disposable credentials.
- Cleanup completes before the script reports success.

Do not add this smoke to CI. It writes temporary credentials to the local
Keychain and must run only against a signed release candidate.

## User-Facing Prompt Expectation

For a normal release, users should expect:

1. A standard first-open macOS warning because the app was downloaded from the
   internet.
2. No Keychain password prompt for ordinary profile setup, reads, or switches.
3. A reviewed migration screen after upgrading from an older ACL-based release.

Any Keychain password prompt during ordinary switching is release-blocking.
