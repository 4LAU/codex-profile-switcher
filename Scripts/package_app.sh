#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ -f "$ROOT_DIR/version.env" ]]; then
  source "$ROOT_DIR/version.env"
fi
APP_BUNDLE="${APP_BUNDLE:-$ROOT_DIR/CodexProfileSwitcher.app}"
BUILD_DIR="${CODEX_PROFILE_PACKAGE_BUILD_DIR:-$ROOT_DIR/.build/package-app}"
PACKAGE_SCRATCH="$BUILD_DIR/swiftpm"
BUNDLE_ID="${BUNDLE_ID:-com.4lau.codex-profile-switcher}"
OFFICIAL_BUNDLE_ID="com.4lau.codex-profile-switcher"
HELPER_BUNDLE_ID="${HELPER_BUNDLE_ID:-$BUNDLE_ID}"
TEAM_ID="W3ZHLSH96F"
AUTH_GROUP="$TEAM_ID.com.4lau.codex-profile-switcher.auth-v2"
APP_APPLICATION_IDENTIFIER="$TEAM_ID.$OFFICIAL_BUNDLE_ID"
HELPER_APPLICATION_IDENTIFIER="$APP_APPLICATION_IDENTIFIER"
MARKETING_VERSION="${MARKETING_VERSION:-0.1.0}"
BUILD_NUMBER="${BUILD_NUMBER:-$(git -C "$ROOT_DIR" rev-list --count HEAD 2>/dev/null || printf '1')}"
REQUIRE_SIGNING="${CODEX_PROFILE_REQUIRE_SIGNING:-0}"
APP_ENTITLEMENTS_BASE="${CODEX_PROFILE_APP_ENTITLEMENTS:-$ROOT_DIR/CodexProfileSwitcher.entitlements}"
HELPER_ENTITLEMENTS_BASE="${CODEX_PROFILE_HELPER_ENTITLEMENTS:-$ROOT_DIR/CodexProfileHelper.entitlements}"
APP_ENTITLEMENTS_SIGNED="$BUILD_DIR/CodexProfileSwitcher.signed.entitlements"
HELPER_ENTITLEMENTS_SIGNED="$BUILD_DIR/CodexProfileHelper.signed.entitlements"
EMPTY_ENTITLEMENTS="$BUILD_DIR/empty.entitlements"
PROFILE_VALIDATION_DIR=""
APP_PROVISIONING_PROFILE=""

if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app ]]; then
  export DEVELOPER_DIR=/Applications/Xcode.app
fi

log() {
  printf '%s\n' "$*"
}

warn() {
  printf 'WARN: %s\n' "$*" >&2
}

fail() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

plist_value() {
  /usr/libexec/PlistBuddy -c "Print $2" "$1" 2>/dev/null
}

require_plist_scalar() {
  local plist="$1"
  local key="$2"
  local expected="$3"
  local subject="$4"
  local actual

  if ! actual="$(plist_value "$plist" "$key")"; then
    fail "$subject is missing $key."
  fi
  [[ "$actual" == "$expected" ]] || fail "$subject has an unexpected value for $key."
}

require_plist_singleton_array() {
  local plist="$1"
  local key="$2"
  local expected="$3"
  local subject="$4"
  local inventory
  local first_value

  if ! inventory="$(plist_value "$plist" "$key")"; then
    fail "$subject is missing $key."
  fi
  [[ "$inventory" == "Array {"* ]] || fail "$subject must contain an array at $key."
  if ! first_value="$(plist_value "$plist" "$key:0")"; then
    fail "$subject must contain one value at $key."
  fi
  [[ "$first_value" == "$expected" ]] || fail "$subject has an unexpected value at $key."
  if plist_value "$plist" "$key:1" >/dev/null 2>&1; then
    fail "$subject must contain exactly one value at $key."
  fi
}

validate_entitlements_file() {
  local entitlements="$1"
  local expected_application_identifier="$2"
  local subject="$3"

  [[ -r "$entitlements" ]] || fail "$subject file is not readable: $entitlements"
  plutil -lint "$entitlements" >/dev/null || fail "$subject is not a valid plist."
  require_plist_scalar "$entitlements" ":com.apple.application-identifier" "$expected_application_identifier" "$subject"
  require_plist_scalar "$entitlements" ":com.apple.developer.team-identifier" "$TEAM_ID" "$subject"
  require_plist_singleton_array "$entitlements" ":keychain-access-groups" "$AUTH_GROUP" "$subject"
}

profile_allows_access_group() {
  local plist="$1"
  local expected="$2"
  local wildcard="$TEAM_ID.*"
  local group

  group="$(plist_value "$plist" ':Entitlements:keychain-access-groups:0')" || return 1
  [[ "$group" == "$expected" || "$group" == "$wildcard" ]] || return 1
  ! plist_value "$plist" ':Entitlements:keychain-access-groups:1' >/dev/null 2>&1
}

profile_is_unexpired() {
  local plist="$1"
  local expiration
  local expiration_epoch

  expiration="$(plutil -extract ExpirationDate raw -o - "$plist" 2>/dev/null)" || return 1
  expiration_epoch="$(date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "$expiration" '+%s' 2>/dev/null)" || return 1
  (( expiration_epoch > $(date -u '+%s') ))
}

profile_has_signing_certificate() {
  local plist="$1"
  local identity="$2"
  local local_fingerprint
  local profile_fingerprint
  local encoded_certificate
  local index=0

  local_fingerprint="$(security find-certificate -c "$identity" -p 2>/dev/null | openssl x509 -outform DER 2>/dev/null | shasum -a 256 | awk '{print $1}')"
  [[ -n "$local_fingerprint" ]] || return 1
  while encoded_certificate="$(plutil -extract "DeveloperCertificates.$index" raw -o - "$plist" 2>/dev/null)"; do
    profile_fingerprint="$(printf '%s' "$encoded_certificate" | base64 -D | shasum -a 256 | awk '{print $1}')" || return 1
    [[ "$profile_fingerprint" == "$local_fingerprint" ]] && return 0
    index=$((index + 1))
  done
  return 1
}

cleanup_profile_validation() {
  [[ -z "$PROFILE_VALIDATION_DIR" ]] || rm -rf "$PROFILE_VALIDATION_DIR"
}

validate_provisioning_profile() {
  local profile="$1"
  local expected_application_identifier="$2"
  local role="$3"
  local environment_variable="$4"
  local decoded_profile="$PROFILE_VALIDATION_DIR/$role.plist"

  [[ -n "$profile" ]] || fail "$environment_variable is required."
  [[ -f "$profile" && -r "$profile" ]] || fail "$role provisioning profile is not readable: $profile"
  if ! security cms -D -i "$profile" > "$decoded_profile"; then
    fail "could not decode the $role provisioning profile."
  fi
  plutil -lint "$decoded_profile" >/dev/null || fail "$role provisioning profile is not a valid plist."
  require_plist_singleton_array "$decoded_profile" ":ApplicationIdentifierPrefix" "$TEAM_ID" "$role provisioning profile"
  require_plist_singleton_array "$decoded_profile" ":TeamIdentifier" "$TEAM_ID" "$role provisioning profile"
  require_plist_scalar "$decoded_profile" ":Entitlements:com.apple.application-identifier" "$expected_application_identifier" "$role provisioning profile"
  require_plist_scalar "$decoded_profile" ":Entitlements:com.apple.developer.team-identifier" "$TEAM_ID" "$role provisioning profile"
  profile_allows_access_group "$decoded_profile" "$AUTH_GROUP" \
    || fail "$role provisioning profile does not authorize the required Keychain access group."
  profile_is_unexpired "$decoded_profile" \
    || fail "$role provisioning profile is expired or has an invalid expiration date."
  profile_has_signing_certificate "$decoded_profile" "$APP_IDENTITY" \
    || fail "$role provisioning profile does not include the selected signing certificate."
}

discover_provisioning_profile() {
  local expected_application_identifier="$1"
  local candidate
  local decoded_profile
  local search_dirs=(
    "$HOME/Developer/AppleProfiles"
    "$HOME/Library/MobileDevice/Provisioning Profiles"
  )

  for directory in "${search_dirs[@]}"; do
    [[ -d "$directory" ]] || continue
    while IFS= read -r -d '' candidate; do
      decoded_profile="$PROFILE_VALIDATION_DIR/candidate.plist"
      security cms -D -i "$candidate" > "$decoded_profile" 2>/dev/null || continue
      [[ "$(plist_value "$decoded_profile" ':Entitlements:com.apple.application-identifier')" == "$expected_application_identifier" ]] || continue
      [[ "$(plist_value "$decoded_profile" ':Entitlements:com.apple.developer.team-identifier')" == "$TEAM_ID" ]] || continue
      profile_allows_access_group "$decoded_profile" "$AUTH_GROUP" || continue
      profile_is_unexpired "$decoded_profile" || continue
      profile_has_signing_certificate "$decoded_profile" "$APP_IDENTITY" || continue
      printf '%s\n' "$candidate"
      return 0
    done < <(find "$directory" -maxdepth 1 -type f \( -name '*.provisionprofile' -o -name '*.mobileprovision' \) -print0)
  done
  return 1
}

resolve_provisioning_profile() {
  local supplied_profile="$1"
  local expected_application_identifier="$2"
  local environment_variable="$3"
  local discovered_profile

  if [[ -n "$supplied_profile" ]]; then
    printf '%s\n' "$supplied_profile"
    return
  fi
  if discovered_profile="$(discover_provisioning_profile "$expected_application_identifier")"; then
    log "Discovered $environment_variable at $discovered_profile" >&2
    printf '%s\n' "$discovered_profile"
    return
  fi
  fail "$environment_variable is required; no matching profile was found locally."
}

validate_release_profiles() {
  PROFILE_VALIDATION_DIR="$(mktemp -d "${TMPDIR:-/tmp}/codex-profile-release-profiles.XXXXXX")" \
    || fail "could not create a temporary directory for profile validation."
  trap cleanup_profile_validation EXIT
  [[ -n "${APP_IDENTITY:-}" ]] || fail "APP_IDENTITY is required for release profile validation."
  APP_PROVISIONING_PROFILE="$(resolve_provisioning_profile "${CODEX_PROFILE_APP_PROVISIONING_PROFILE:-}" "$APP_APPLICATION_IDENTIFIER" "CODEX_PROFILE_APP_PROVISIONING_PROFILE")"
  validate_provisioning_profile "$APP_PROVISIONING_PROFILE" "$APP_APPLICATION_IDENTIFIER" "APP" "CODEX_PROFILE_APP_PROVISIONING_PROFILE"
}

validate_release_profiles_only=0
case "${1:-}" in
  --validate-release-profiles)
    validate_release_profiles_only=1
    shift
    ;;
  "")
    ;;
  *)
    fail "usage: $0 [--validate-release-profiles]"
    ;;
esac
[[ "$#" == "0" ]] || fail "usage: $0 [--validate-release-profiles]"

if [[ "$validate_release_profiles_only" == "1" ]]; then
  validate_release_profiles
  log "Release provisioning profiles are valid."
  exit 0
fi

if [[ "$REQUIRE_SIGNING" == "1" ]]; then
  [[ "$BUNDLE_ID" == "$OFFICIAL_BUNDLE_ID" ]] || fail "BUNDLE_ID must be $OFFICIAL_BUNDLE_ID for signed release builds."
  [[ "$HELPER_BUNDLE_ID" == "$OFFICIAL_BUNDLE_ID" ]] || fail "HELPER_BUNDLE_ID must be $OFFICIAL_BUNDLE_ID for signed release builds."
  validate_entitlements_file "$APP_ENTITLEMENTS_BASE" "$APP_APPLICATION_IDENTIFIER" "app entitlements"
  validate_entitlements_file "$HELPER_ENTITLEMENTS_BASE" "$HELPER_APPLICATION_IDENTIFIER" "helper entitlements"
  validate_release_profiles
fi

has_signing_identity() {
  local identity="${1:-}"
  [[ -n "$identity" ]] || return 1
  security find-identity -p codesigning -v 2>/dev/null | grep -F "\"$identity\"" >/dev/null 2>&1
}

verify_signature() {
  local target="$1"

  codesign --verify --strict --verbose=2 "$target"
  codesign -d --entitlements :- "$target"
}

verify_signed_entitlements() {
  local target="$1"
  local expected_application_identifier="$2"
  local subject="$3"
  local inspected_entitlements="$BUILD_DIR/$(basename "$target").final.entitlements"

  if ! codesign -d --entitlements :- "$target" > "$inspected_entitlements" 2>/dev/null; then
    fail "could not inspect $subject."
  fi
  validate_entitlements_file "$inspected_entitlements" "$expected_application_identifier" "$subject"
}

codesign_args=()
real_signing=0
if [[ -n "${APP_IDENTITY:-}" ]]; then
  if has_signing_identity "$APP_IDENTITY"; then
    codesign_args=(--force --timestamp --options runtime --sign "$APP_IDENTITY")
    real_signing=1
  elif [[ "$REQUIRE_SIGNING" == "1" ]]; then
    fail "APP_IDENTITY was not found in the codesigning keychain: $APP_IDENTITY"
  else
    warn "APP_IDENTITY was not found in the codesigning keychain; falling back to ad-hoc signing."
    codesign_args=(--force --sign -)
  fi
elif [[ "$REQUIRE_SIGNING" == "1" ]]; then
  fail "APP_IDENTITY is required when CODEX_PROFILE_REQUIRE_SIGNING=1."
else
  codesign_args=(--force --sign -)
fi

if [[ "$BUNDLE_ID" == "$OFFICIAL_BUNDLE_ID" \
  && "$APP_BUNDLE" == "/Applications/CodexProfileSwitcher.app" \
  && "$real_signing" != "1" ]]; then
  fail "installing the official app into /Applications requires APP_IDENTITY and Developer ID signing."
fi

mkdir -p "$BUILD_DIR" "$PACKAGE_SCRATCH"
[[ -f "$APP_ENTITLEMENTS_BASE" ]] || fail "app entitlements file not found: $APP_ENTITLEMENTS_BASE"
[[ -f "$HELPER_ENTITLEMENTS_BASE" ]] || fail "helper entitlements file not found: $HELPER_ENTITLEMENTS_BASE"

if [[ "$REQUIRE_SIGNING" == "1" ]]; then
  cp "$APP_ENTITLEMENTS_BASE" "$APP_ENTITLEMENTS_SIGNED"
  cp "$HELPER_ENTITLEMENTS_BASE" "$HELPER_ENTITLEMENTS_SIGNED"
else
  rm -f "$EMPTY_ENTITLEMENTS"
  plutil -create xml1 "$EMPTY_ENTITLEMENTS"
  cp "$EMPTY_ENTITLEMENTS" "$APP_ENTITLEMENTS_SIGNED"
  cp "$EMPTY_ENTITLEMENTS" "$HELPER_ENTITLEMENTS_SIGNED"
fi
plutil -lint "$APP_ENTITLEMENTS_SIGNED" >/dev/null
plutil -lint "$HELPER_ENTITLEMENTS_SIGNED" >/dev/null

log "Ensuring Sparkle framework is available..."
"$ROOT_DIR/Scripts/fetch_sparkle.sh"
SPARKLE_DIR="$ROOT_DIR/.build/sparkle"

if [[ -z "${SPARKLE_ED_PUBLIC_KEY:-}" ]]; then
  if [[ "$REQUIRE_SIGNING" == "1" ]]; then
    fail "SPARKLE_ED_PUBLIC_KEY is required for signed release builds."
  fi
  warn "SPARKLE_ED_PUBLIC_KEY is not set; Sparkle update verification will not work."
fi

log "Building CodexProfileSwitcher..."
swift build \
  --package-path "$ROOT_DIR" \
  -c release \
  --product CodexProfileSwitcher \
  --scratch-path "$PACKAGE_SCRATCH" \
  -Xswiftc -F -Xswiftc "$SPARKLE_DIR" \
  -Xlinker -F -Xlinker "$SPARKLE_DIR" \
  -Xlinker -framework -Xlinker Sparkle \
  -Xlinker -rpath -Xlinker @executable_path/../Frameworks

log "Building codex-profile helper..."
swift build \
  --package-path "$ROOT_DIR" \
  -c release \
  --product codex-profile \
  --scratch-path "$PACKAGE_SCRATCH"
BIN_DIR="$(swift build --package-path "$ROOT_DIR" -c release --scratch-path "$PACKAGE_SCRATCH" --show-bin-path)"
APP_BINARY="$BIN_DIR/CodexProfileSwitcher"
HELPER_BINARY="$BIN_DIR/codex-profile"
HELPER_APP_BUNDLE="$APP_BUNDLE/Contents/Helpers/CodexProfileHelper.app"
HELPER_APP_EXECUTABLE="$HELPER_APP_BUNDLE/Contents/MacOS/codex-profile"
HELPER_COMPAT_LINK="$APP_BUNDLE/Contents/Helpers/codex-profile"

rm -rf "$APP_BUNDLE"
mkdir -p \
  "$APP_BUNDLE/Contents/MacOS" \
  "$HELPER_APP_BUNDLE/Contents/MacOS" \
  "$APP_BUNDLE/Contents/Resources" \
  "$APP_BUNDLE/Contents/Frameworks"

cp "$APP_BINARY" "$APP_BUNDLE/Contents/MacOS/CodexProfileSwitcher"
cp "$HELPER_BINARY" "$HELPER_APP_EXECUTABLE"
ln -s "CodexProfileHelper.app/Contents/MacOS/codex-profile" "$HELPER_COMPAT_LINK"
chmod +x "$APP_BUNDLE/Contents/MacOS/CodexProfileSwitcher" "$HELPER_APP_EXECUTABLE"

if [[ "$REQUIRE_SIGNING" == "1" ]]; then
  cp "$APP_PROVISIONING_PROFILE" "$APP_BUNDLE/Contents/embedded.provisionprofile"
  cp "$APP_PROVISIONING_PROFILE" "$HELPER_APP_BUNDLE/Contents/embedded.provisionprofile"
fi

log "Embedding Sparkle.framework..."
cp -R "$SPARKLE_DIR/Sparkle.framework" "$APP_BUNDLE/Contents/Frameworks/Sparkle.framework"
for icon in \
  codex-profile-switcher-menu-icon-empty.png \
  AppIcon.icns
do
  if [[ -f "$ROOT_DIR/assets/$icon" ]]; then
    cp "$ROOT_DIR/assets/$icon" "$APP_BUNDLE/Contents/Resources/$icon"
  else
    log "WARN: missing icon asset: assets/$icon"
  fi
done

BUILD_TIMESTAMP="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
GIT_COMMIT="$(git -C "$ROOT_DIR" rev-parse --short HEAD 2>/dev/null || printf 'unknown')"

cat > "$APP_BUNDLE/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>
  <string>CodexProfileSwitcher</string>
  <key>CFBundleDisplayName</key>
  <string>Codex Profile Switcher</string>
  <key>CFBundleIdentifier</key>
  <string>$BUNDLE_ID</string>
  <key>CFBundleExecutable</key>
  <string>CodexProfileSwitcher</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>$MARKETING_VERSION</string>
  <key>CFBundleVersion</key>
  <string>$BUILD_NUMBER</string>
  <key>LSMinimumSystemVersion</key>
  <string>14.0</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>LSUIElement</key>
  <true/>
  <key>CodexProfileSwitcherBuildTimestamp</key>
  <string>$BUILD_TIMESTAMP</string>
  <key>CodexProfileSwitcherGitCommit</key>
  <string>$GIT_COMMIT</string>
  <key>SUFeedURL</key>
  <string>https://raw.githubusercontent.com/4LAU/codex-profile-switcher/main/appcast.xml</string>
  <key>SUEnableAutomaticChecks</key>
  <true/>
  <key>SUScheduledCheckInterval</key>
  <integer>3600</integer>
</dict>
</plist>
PLIST

cat > "$HELPER_APP_BUNDLE/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>
  <string>CodexProfileHelper</string>
  <key>CFBundleDisplayName</key>
  <string>Codex Profile Helper</string>
  <key>CFBundleIdentifier</key>
  <string>$HELPER_BUNDLE_ID</string>
  <key>CFBundleExecutable</key>
  <string>codex-profile</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>$MARKETING_VERSION</string>
  <key>CFBundleVersion</key>
  <string>$BUILD_NUMBER</string>
  <key>LSMinimumSystemVersion</key>
  <string>14.0</string>
  <key>LSUIElement</key>
  <true/>
</dict>
</plist>
PLIST

if [[ -n "${SPARKLE_ED_PUBLIC_KEY:-}" ]]; then
  plutil -insert SUPublicEDKey -string "$SPARKLE_ED_PUBLIC_KEY" "$APP_BUNDLE/Contents/Info.plist"
fi

chmod -R u+w "$APP_BUNDLE"
xattr -cr "$APP_BUNDLE"
find "$APP_BUNDLE" -name '._*' -delete

log "Signing helper..."
codesign "${codesign_args[@]}" --entitlements "$HELPER_ENTITLEMENTS_SIGNED" "$HELPER_APP_BUNDLE"
verify_signature "$HELPER_APP_BUNDLE"
if [[ "$REQUIRE_SIGNING" == "1" ]]; then
  verify_signed_entitlements "$HELPER_APP_BUNDLE" "$HELPER_APPLICATION_IDENTIFIER" "signed helper entitlements"
fi

log "Signing Sparkle framework components..."
if [[ -d "$APP_BUNDLE/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/Installer.xpc" ]]; then
  codesign "${codesign_args[@]}" "$APP_BUNDLE/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/Installer.xpc"
fi
if [[ -d "$APP_BUNDLE/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/Downloader.xpc" ]]; then
  codesign "${codesign_args[@]}" --preserve-metadata=entitlements "$APP_BUNDLE/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/Downloader.xpc"
fi
codesign "${codesign_args[@]}" "$APP_BUNDLE/Contents/Frameworks/Sparkle.framework/Versions/B/Autoupdate"
codesign "${codesign_args[@]}" "$APP_BUNDLE/Contents/Frameworks/Sparkle.framework/Versions/B/Updater.app"
codesign "${codesign_args[@]}" "$APP_BUNDLE/Contents/Frameworks/Sparkle.framework"

log "Signing app..."
codesign "${codesign_args[@]}" --entitlements "$APP_ENTITLEMENTS_SIGNED" "$APP_BUNDLE"
verify_signature "$APP_BUNDLE"
if [[ "$REQUIRE_SIGNING" == "1" ]]; then
  verify_signed_entitlements "$APP_BUNDLE" "$APP_APPLICATION_IDENTIFIER" "signed app entitlements"
fi

log "Created $APP_BUNDLE"
