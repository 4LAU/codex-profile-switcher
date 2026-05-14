#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ -f "$ROOT_DIR/version.env" ]]; then
  source "$ROOT_DIR/version.env"
fi
VERSION="${VERSION:-${MARKETING_VERSION:-0.1.0}}"
RELEASE_DIR="${RELEASE_DIR:-$ROOT_DIR/.build/release}"
APP_BUNDLE="${APP_BUNDLE:-$ROOT_DIR/CodexProfileSwitcher.app}"
STAGING_DIR="$RELEASE_DIR/dmg-staging"
VOLUME_NAME="${VOLUME_NAME:-Codex Profile Switcher}"
DMG_PATH="${DMG_PATH:-$RELEASE_DIR/CodexProfileSwitcher-$VERSION.dmg}"
CHECKSUM_PATH="$DMG_PATH.sha256"
CASK_OUTPUT_PATH="${CASK_OUTPUT_PATH:-$RELEASE_DIR/codex-profile-switcher.rb}"

log() {
  printf '%s\n' "$*"
}

fail() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

has_signing_identity() {
  local identity="${1:-}"
  [[ -n "$identity" ]] || return 1
  security find-identity -p codesigning -v 2>/dev/null | grep -F "\"$identity\"" >/dev/null 2>&1
}

notary_args=()
resolve_notary_args() {
  if [[ -n "${NOTARY_KEYCHAIN_PROFILE:-}" ]]; then
    notary_args=(--keychain-profile "$NOTARY_KEYCHAIN_PROFILE")
    return
  fi

  if [[ -n "${APPLE_ID:-}" && -n "${APPLE_TEAM_ID:-}" && -n "${APP_SPECIFIC_PASSWORD:-}" ]]; then
    notary_args=(
      --apple-id "$APPLE_ID"
      --team-id "$APPLE_TEAM_ID"
      --password "$APP_SPECIFIC_PASSWORD"
    )
    return
  fi

  if [[ "${CODEX_PROFILE_RELEASE_SKIP_NOTARIZATION:-0}" == "1" ]]; then
    log "WARN: skipping notarization. This DMG is not suitable for public release."
    return
  fi

  fail "notarization credentials are required. Set NOTARY_KEYCHAIN_PROFILE, or APPLE_ID + APPLE_TEAM_ID + APP_SPECIFIC_PASSWORD."
}

[[ -n "${APP_IDENTITY:-}" ]] || fail "APP_IDENTITY is required for release builds."
has_signing_identity "$APP_IDENTITY" || fail "APP_IDENTITY was not found in the codesigning keychain: $APP_IDENTITY"

command -v hdiutil >/dev/null 2>&1 || fail "hdiutil is required."
command -v codesign >/dev/null 2>&1 || fail "codesign is required."
command -v spctl >/dev/null 2>&1 || fail "spctl is required."
command -v xcrun >/dev/null 2>&1 || fail "xcrun is required."

resolve_notary_args

mkdir -p "$RELEASE_DIR"

log "Building and signing app bundle..."
CODEX_PROFILE_REQUIRE_SIGNING=1 \
  APP_IDENTITY="$APP_IDENTITY" \
  APP_BUNDLE="$APP_BUNDLE" \
  "$ROOT_DIR/Scripts/package_app.sh"

log "Verifying signed app bundle..."
codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"

log "Creating DMG staging folder..."
rm -rf "$STAGING_DIR"
mkdir -p "$STAGING_DIR"
cp -R "$APP_BUNDLE" "$STAGING_DIR/"
ln -s /Applications "$STAGING_DIR/Applications"

rm -f "$DMG_PATH" "$CHECKSUM_PATH"
log "Creating DMG: $DMG_PATH"
hdiutil create \
  -volname "$VOLUME_NAME" \
  -srcfolder "$STAGING_DIR" \
  -format UDZO \
  -ov \
  "$DMG_PATH" >/dev/null

log "Signing DMG..."
codesign --force --timestamp --sign "$APP_IDENTITY" "$DMG_PATH"
codesign --verify --strict --verbose=2 "$DMG_PATH"

if [[ "${CODEX_PROFILE_RELEASE_SKIP_NOTARIZATION:-0}" != "1" ]]; then
  log "Submitting DMG for notarization..."
  xcrun notarytool submit "$DMG_PATH" "${notary_args[@]}" --wait

  log "Stapling notarization ticket..."
  xcrun stapler staple "$DMG_PATH"
  xcrun stapler validate "$DMG_PATH"

  log "Verifying Gatekeeper assessment..."
  spctl --assess --type open --context context:primary-signature --verbose "$DMG_PATH"
else
  log "Skipping notarization, stapling, and Gatekeeper release assessment."
fi

shasum -a 256 "$DMG_PATH" > "$CHECKSUM_PATH"

log "Generating Homebrew cask..."
VERSION="$VERSION" \
  RELEASE_DIR="$RELEASE_DIR" \
  DMG_PATH="$DMG_PATH" \
  CHECKSUM_PATH="$CHECKSUM_PATH" \
  CASK_OUTPUT_PATH="$CASK_OUTPUT_PATH" \
  "$ROOT_DIR/Scripts/generate_homebrew_cask.sh"

log "Generating Sparkle appcast..."
SPARKLE_DIR="$ROOT_DIR/.build/sparkle"
"$ROOT_DIR/Scripts/fetch_sparkle.sh"

# Create a working directory for generate_appcast with just this DMG
APPCAST_WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/appcast-XXXXXX")"
trap 'rm -rf "$APPCAST_WORK_DIR"' EXIT
cp "$DMG_PATH" "$APPCAST_WORK_DIR/"

# generate_appcast reads the EdDSA private key from macOS Keychain by default
# (service: https://sparkle-project.org, account: ed25519)
# If an existing appcast.xml exists, copy it so generate_appcast can update it
if [[ -f "$ROOT_DIR/appcast.xml" ]]; then
  cp "$ROOT_DIR/appcast.xml" "$APPCAST_WORK_DIR/appcast.xml"
fi

"$SPARKLE_DIR/bin/generate_appcast" \
  --download-url-prefix "https://github.com/4LAU/codex-profile-switcher/releases/download/v${VERSION}/" \
  "$APPCAST_WORK_DIR"

cp "$APPCAST_WORK_DIR/appcast.xml" "$ROOT_DIR/appcast.xml"
log "Updated appcast.xml"

log "Created release artifacts:"
log "  $DMG_PATH"
log "  $CHECKSUM_PATH"
log "  $CASK_OUTPUT_PATH"
log "  $ROOT_DIR/appcast.xml"
