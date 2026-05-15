#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ICON_EMPTY_SRC="$SCRIPT_DIR/assets/codex-profile-switcher-menu-icon-empty.png"
OUT="${1:-$HOME/.local/bin/codex-profile-switcher}"
OUT_DIR="$(dirname "$OUT")"
HELPER_OUT="$OUT_DIR/codex-profile"
ICON_EMPTY_OUT="$OUT_DIR/codex-profile-switcher-menu-icon-empty.png"
BUILD_DIR="${CODEX_PROFILE_BUILD_DIR:-$SCRIPT_DIR/.build/dev}"
REQUIRE_SIGNING="${CODEX_PROFILE_REQUIRE_SIGNING:-0}"
KEYCHAIN_ACCESS_GROUP="${CODEX_PROFILE_KEYCHAIN_ACCESS_GROUP:-}"
PROVISIONING_PROFILE="${CODEX_PROFILE_PROVISIONING_PROFILE:-}"
APP_ENTITLEMENTS_BASE="${CODEX_PROFILE_APP_ENTITLEMENTS:-$SCRIPT_DIR/CodexProfileSwitcher.entitlements}"
HELPER_ENTITLEMENTS_BASE="${CODEX_PROFILE_HELPER_ENTITLEMENTS:-$SCRIPT_DIR/CodexProfileHelper.entitlements}"

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

if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app ]]; then
  export DEVELOPER_DIR=/Applications/Xcode.app
fi

has_signing_identity() {
  local identity="${1:-}"
  [[ -n "$identity" ]] || return 1
  security find-identity -p codesigning -v 2>/dev/null | grep -F "\"$identity\"" >/dev/null 2>&1
}

profile_allows_access_group() {
  local profile="$1"
  local access_group="$2"
  local decoded="$3"

  security cms -D -i "$profile" > "$decoded" 2>/dev/null || return 1
  /usr/libexec/PlistBuddy -c "Print :Entitlements:keychain-access-groups" "$decoded" 2>/dev/null \
    | grep -F "$access_group" >/dev/null 2>&1
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

SIGN_IDENTITY="${APP_IDENTITY:-}"
if [[ -z "$SIGN_IDENTITY" ]]; then
  SIGN_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
    | grep 'Developer ID Application' \
    | head -1 \
    | sed 's/.*"\(.*\)".*/\1/' || true)"
fi
if [[ -n "$SIGN_IDENTITY" ]]; then
  if ! has_signing_identity "$SIGN_IDENTITY"; then
    if [[ "$REQUIRE_SIGNING" == "1" ]]; then
      fail "APP_IDENTITY was not found in the codesigning keychain: $SIGN_IDENTITY"
    fi
    warn "APP_IDENTITY was not found in the codesigning keychain; using ad-hoc signing."
    SIGN_IDENTITY=""
  fi
fi
if [[ -n "$SIGN_IDENTITY" ]]; then
  CODESIGN_ARGS=(--force --sign "$SIGN_IDENTITY")
  log "Signing with: $SIGN_IDENTITY"
elif [[ "$REQUIRE_SIGNING" == "1" ]]; then
  fail "APP_IDENTITY or a Developer ID Application identity is required when CODEX_PROFILE_REQUIRE_SIGNING=1."
else
  CODESIGN_ARGS=(--force --sign -)
  log "No Developer ID found; using ad-hoc signing"
fi

mkdir -p "$OUT_DIR"
mkdir -p "$BUILD_DIR"
OUT_TMP="$(mktemp "$OUT_DIR/.codex-profile-switcher.XXXXXX")"
HELPER_TMP="$(mktemp "$OUT_DIR/.codex-profile.XXXXXX")"
APP_ENTITLEMENTS_TMP="$BUILD_DIR/CodexProfileSwitcher.dev.entitlements"
HELPER_ENTITLEMENTS_TMP="$BUILD_DIR/CodexProfileHelper.dev.entitlements"
trap 'rm -f "$OUT_TMP" "$HELPER_TMP"' EXIT

APP_CODESIGN_ARGS=("${CODESIGN_ARGS[@]}")
HELPER_CODESIGN_ARGS=("${CODESIGN_ARGS[@]}")
if [[ -n "$KEYCHAIN_ACCESS_GROUP" ]]; then
  PROFILE_DECODED="$(mktemp "$BUILD_DIR/provisioning.XXXXXX.plist")"
  trap 'rm -f "$OUT_TMP" "$HELPER_TMP" "$PROFILE_DECODED"' EXIT
  if [[ -z "$SIGN_IDENTITY" ]]; then
    if [[ "$REQUIRE_SIGNING" == "1" ]]; then
      fail "validated keychain access group requested without a real signing identity."
    fi
    warn "validated keychain access group requested without a real signing identity; using legacy ACL storage."
  elif [[ -z "$PROVISIONING_PROFILE" || ! -f "$PROVISIONING_PROFILE" ]]; then
    if [[ "$REQUIRE_SIGNING" == "1" ]]; then
      fail "CODEX_PROFILE_PROVISIONING_PROFILE is required and must exist when requesting CODEX_PROFILE_KEYCHAIN_ACCESS_GROUP."
    fi
    warn "validated provisioning profile not found; using legacy ACL storage."
  elif ! profile_allows_access_group "$PROVISIONING_PROFILE" "$KEYCHAIN_ACCESS_GROUP" "$PROFILE_DECODED"; then
    if [[ "$REQUIRE_SIGNING" == "1" ]]; then
      fail "provisioning profile does not authorize keychain access group: $KEYCHAIN_ACCESS_GROUP"
    fi
    warn "provisioning profile does not authorize requested keychain access group; using legacy ACL storage."
  else
    write_access_group_entitlements "$APP_ENTITLEMENTS_BASE" "$APP_ENTITLEMENTS_TMP" "$KEYCHAIN_ACCESS_GROUP"
    write_access_group_entitlements "$HELPER_ENTITLEMENTS_BASE" "$HELPER_ENTITLEMENTS_TMP" "$KEYCHAIN_ACCESS_GROUP"
    APP_CODESIGN_ARGS+=("--entitlements" "$APP_ENTITLEMENTS_TMP")
    HELPER_CODESIGN_ARGS+=("--entitlements" "$HELPER_ENTITLEMENTS_TMP")
    log "Signing loose dev binaries with validated keychain access group: $KEYCHAIN_ACCESS_GROUP"
  fi
fi

log "Building CodexProfileSwitcher..."
swift build -c release --product CodexProfileSwitcher --scratch-path "$BUILD_DIR"
BIN_DIR="$(swift build -c release --scratch-path "$BUILD_DIR" --show-bin-path)"
cp "$BIN_DIR/CodexProfileSwitcher" "$OUT_TMP"

chmod +x "$OUT_TMP"
codesign "${APP_CODESIGN_ARGS[@]}" "$OUT_TMP"
verify_signature "$OUT_TMP"
mv -f "$OUT_TMP" "$OUT"

log "Building helper..."
swift build -c release --product codex-profile --scratch-path "$BUILD_DIR"
cp "$BIN_DIR/codex-profile" "$HELPER_TMP"
chmod +x "$HELPER_TMP"
codesign "${HELPER_CODESIGN_ARGS[@]}" "$HELPER_TMP"
verify_signature "$HELPER_TMP"
mv -f "$HELPER_TMP" "$HELPER_OUT"
log "Installed helper: $HELPER_OUT"

if [[ -f "$ICON_EMPTY_SRC" ]]; then
  cp "$ICON_EMPTY_SRC" "$ICON_EMPTY_OUT"
  log "Installed empty icon: $ICON_EMPTY_OUT"
else
  warn "empty icon not found at $ICON_EMPTY_SRC"
fi

log "Built: $OUT"
trap - EXIT
