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
trap 'rm -f "$OUT_TMP" "$HELPER_TMP"' EXIT

log "Building CodexProfileSwitcher..."
swift build -c release --product CodexProfileSwitcher --scratch-path "$BUILD_DIR"
BIN_DIR="$(swift build -c release --scratch-path "$BUILD_DIR" --show-bin-path)"
cp "$BIN_DIR/CodexProfileSwitcher" "$OUT_TMP"

chmod +x "$OUT_TMP"
codesign "${CODESIGN_ARGS[@]}" "$OUT_TMP"
verify_signature "$OUT_TMP"
mv -f "$OUT_TMP" "$OUT"

log "Building helper..."
swift build -c release --product codex-profile --scratch-path "$BUILD_DIR"
cp "$BIN_DIR/codex-profile" "$HELPER_TMP"
chmod +x "$HELPER_TMP"
codesign "${CODESIGN_ARGS[@]}" "$HELPER_TMP"
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
