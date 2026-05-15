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
OFFICIAL_KEYCHAIN_ACCESS_GROUP="W3ZHLSH96F.com.4lau.codex-profile-switcher"
MARKETING_VERSION="${MARKETING_VERSION:-0.1.0}"
BUILD_NUMBER="${BUILD_NUMBER:-$(git -C "$ROOT_DIR" rev-list --count HEAD 2>/dev/null || printf '1')}"
REQUIRE_SIGNING="${CODEX_PROFILE_REQUIRE_SIGNING:-0}"
KEYCHAIN_ACCESS_GROUP="${CODEX_PROFILE_KEYCHAIN_ACCESS_GROUP:-}"
PROVISIONING_PROFILE="${CODEX_PROFILE_PROVISIONING_PROFILE:-}"
APP_ENTITLEMENTS_BASE="${CODEX_PROFILE_APP_ENTITLEMENTS:-$ROOT_DIR/CodexProfileSwitcher.entitlements}"
HELPER_ENTITLEMENTS_BASE="${CODEX_PROFILE_HELPER_ENTITLEMENTS:-$ROOT_DIR/CodexProfileHelper.entitlements}"
APP_ENTITLEMENTS_SIGNED="$BUILD_DIR/CodexProfileSwitcher.signed.entitlements"
HELPER_ENTITLEMENTS_SIGNED="$BUILD_DIR/CodexProfileHelper.signed.entitlements"
APP_SWIFT_FLAGS=()

if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app ]]; then
  export DEVELOPER_DIR=/Applications/Xcode.app
fi

if [[ "${CODEX_PROFILE_ENABLE_KEYCHAIN_PROBE:-0}" == "1" ]]; then
  APP_SWIFT_FLAGS=(-Xswiftc -D -Xswiftc KEYCHAIN_PROBE)
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

has_signing_identity() {
  local identity="${1:-}"
  [[ -n "$identity" ]] || return 1
  security find-identity -p codesigning -v 2>/dev/null | grep -F "\"$identity\"" >/dev/null 2>&1
}

profile_bundle_id() {
  local profile="$1"
  local decoded="$2"

  security cms -D -i "$profile" > "$decoded" 2>/dev/null || return 1
  /usr/libexec/PlistBuddy -c "Print :Entitlements:com.apple.application-identifier" "$decoded" 2>/dev/null \
    | sed 's/^[^.]*\.//'
}

profile_allows_access_group() {
  local profile="$1"
  local access_group="$2"
  local decoded="$3"
  local team_prefix="${access_group%%.*}"
  local wildcard_group="$team_prefix.*"
  local profile_groups

  security cms -D -i "$profile" > "$decoded" 2>/dev/null || return 1
  profile_groups="$(plutil -extract Entitlements.keychain-access-groups json -o - "$decoded" 2>/dev/null)" || return 1
  printf '%s\n' "$profile_groups" | grep -F "\"$access_group\"" >/dev/null 2>&1 \
    || printf '%s\n' "$profile_groups" | grep -F "\"$wildcard_group\"" >/dev/null 2>&1
}

discover_provisioning_profile() {
  local access_group="$1"
  local expected_bundle_id="$2"
  local candidate
  local decoded
  local bundle_id
  local search_dirs=(
    "$HOME/Developer/AppleProfiles"
    "$HOME/Library/MobileDevice/Provisioning Profiles"
  )

  for dir in "${search_dirs[@]}"; do
    [[ -d "$dir" ]] || continue
    while IFS= read -r -d '' candidate; do
      decoded="$(mktemp "$BUILD_DIR/provisioning-discovery.XXXXXX")"
      if profile_allows_access_group "$candidate" "$access_group" "$decoded"; then
        bundle_id="$(profile_bundle_id "$candidate" "$decoded" || true)"
        rm -f "$decoded"
        if [[ "$bundle_id" == "$expected_bundle_id" ]]; then
          printf '%s\n' "$candidate"
          return 0
        fi
      else
        rm -f "$decoded"
      fi
    done < <(find "$dir" -maxdepth 1 -type f \( -name '*.provisionprofile' -o -name '*.mobileprovision' \) -print0)
  done

  return 1
}

write_access_group_entitlements() {
  local base="$1"
  local output="$2"
  local access_group="$3"

  [[ -f "$base" ]] || fail "entitlements file not found: $base"
  cp "$base" "$output"
  /usr/libexec/PlistBuddy -c "Delete :keychain-access-groups" "$output" >/dev/null 2>&1 || true
  /usr/libexec/PlistBuddy -c "Add :keychain-access-groups array" "$output"
  /usr/libexec/PlistBuddy -c "Add :keychain-access-groups:0 string $access_group" "$output"
  plutil -lint "$output" >/dev/null
}

verify_signature() {
  local target="$1"

  codesign --verify --strict --verbose=2 "$target"
  codesign -d --entitlements :- "$target"
}

verify_keychain_entitlement() {
  local target="$1"
  local access_group="$2"
  local entitlements

  entitlements="$(codesign -d --entitlements :- "$target" 2>/dev/null)" \
    || fail "could not read signed entitlements from $target"
  printf '%s\n' "$entitlements" | grep -F "<string>$access_group</string>" >/dev/null \
    || fail "$target is missing required keychain access group: $access_group"
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

cp "$APP_ENTITLEMENTS_BASE" "$APP_ENTITLEMENTS_SIGNED"
cp "$HELPER_ENTITLEMENTS_BASE" "$HELPER_ENTITLEMENTS_SIGNED"
plutil -lint "$APP_ENTITLEMENTS_SIGNED" >/dev/null
plutil -lint "$HELPER_ENTITLEMENTS_SIGNED" >/dev/null

if [[ "$real_signing" == "1" && "$BUNDLE_ID" == "$OFFICIAL_BUNDLE_ID" && -z "$KEYCHAIN_ACCESS_GROUP" ]]; then
  KEYCHAIN_ACCESS_GROUP="$OFFICIAL_KEYCHAIN_ACCESS_GROUP"
  log "Using official keychain access group: $KEYCHAIN_ACCESS_GROUP"
fi

EMBED_PROVISIONING_PROFILE=0
KEYCHAIN_ACCESS_GROUP_REQUIRED=0
if [[ "$real_signing" == "1" && "$BUNDLE_ID" == "$OFFICIAL_BUNDLE_ID" ]]; then
  KEYCHAIN_ACCESS_GROUP_REQUIRED=1
fi
if [[ -n "$KEYCHAIN_ACCESS_GROUP" ]]; then
  PROFILE_DECODED="$(mktemp "$BUILD_DIR/provisioning.XXXXXX")"
  if [[ "${codesign_args[*]}" == *"--sign -"* ]]; then
    if [[ "$REQUIRE_SIGNING" == "1" || "$KEYCHAIN_ACCESS_GROUP_REQUIRED" == "1" ]]; then
      fail "validated keychain access group requested without a real signing identity."
    fi
    warn "validated keychain access group requested without a real signing identity; falling back to legacy ACL storage."
  elif [[ -z "$PROVISIONING_PROFILE" || ! -f "$PROVISIONING_PROFILE" ]]; then
    if discovered_profile="$(discover_provisioning_profile "$KEYCHAIN_ACCESS_GROUP" "$BUNDLE_ID")"; then
      PROVISIONING_PROFILE="$discovered_profile"
      log "Discovered provisioning profile for keychain sharing: $PROVISIONING_PROFILE"
    else
      fail "could not find a provisioning profile for $BUNDLE_ID with keychain access group $KEYCHAIN_ACCESS_GROUP."
    fi
  fi

  if [[ -n "$PROVISIONING_PROFILE" && -f "$PROVISIONING_PROFILE" ]] \
    && ! profile_allows_access_group "$PROVISIONING_PROFILE" "$KEYCHAIN_ACCESS_GROUP" "$PROFILE_DECODED"; then
    if [[ "$REQUIRE_SIGNING" == "1" || "$KEYCHAIN_ACCESS_GROUP_REQUIRED" == "1" ]]; then
      fail "provisioning profile does not authorize keychain access group: $KEYCHAIN_ACCESS_GROUP"
    fi
    warn "provisioning profile does not authorize requested keychain access group; falling back to legacy ACL storage."
  elif [[ -n "$PROVISIONING_PROFILE" && -f "$PROVISIONING_PROFILE" ]]; then
    write_access_group_entitlements "$APP_ENTITLEMENTS_BASE" "$APP_ENTITLEMENTS_SIGNED" "$KEYCHAIN_ACCESS_GROUP"
    write_access_group_entitlements "$HELPER_ENTITLEMENTS_BASE" "$HELPER_ENTITLEMENTS_SIGNED" "$KEYCHAIN_ACCESS_GROUP"
    EMBED_PROVISIONING_PROFILE=1
    log "Signing app and helper with validated keychain access group: $KEYCHAIN_ACCESS_GROUP"
  fi
fi

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
  "${APP_SWIFT_FLAGS[@]}" \
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
  <string>$BUNDLE_ID</string>
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

if [[ "$EMBED_PROVISIONING_PROFILE" == "1" ]]; then
  log "Embedding provisioning profile..."
  cp "$PROVISIONING_PROFILE" "$APP_BUNDLE/Contents/embedded.provisionprofile"
  cp "$PROVISIONING_PROFILE" "$HELPER_APP_BUNDLE/Contents/embedded.provisionprofile"
fi

chmod -R u+w "$APP_BUNDLE"
xattr -cr "$APP_BUNDLE"
find "$APP_BUNDLE" -name '._*' -delete

log "Signing helper..."
codesign "${codesign_args[@]}" --entitlements "$HELPER_ENTITLEMENTS_SIGNED" "$HELPER_APP_BUNDLE"
verify_signature "$HELPER_APP_BUNDLE"
if [[ -n "$KEYCHAIN_ACCESS_GROUP" && "$EMBED_PROVISIONING_PROFILE" == "1" ]]; then
  verify_keychain_entitlement "$HELPER_APP_BUNDLE" "$KEYCHAIN_ACCESS_GROUP"
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
if [[ -n "$KEYCHAIN_ACCESS_GROUP" && "$EMBED_PROVISIONING_PROFILE" == "1" ]]; then
  verify_keychain_entitlement "$APP_BUNDLE" "$KEYCHAIN_ACCESS_GROUP"
fi

log "Created $APP_BUNDLE"
