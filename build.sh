#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SWIFT_SOURCES=(
  "$SCRIPT_DIR/CodexProfileSwitcher.swift"
  "$SCRIPT_DIR/AuthBlob.swift"
  "$SCRIPT_DIR/AuthVault.swift"
  "$SCRIPT_DIR/KeychainAuthVault.swift"
)
HELPER_SRC="$SCRIPT_DIR/CodexProfileCLI.swift"
HELPER_SOURCES=(
  "$SCRIPT_DIR/CodexProfileCLI.swift"
  "$SCRIPT_DIR/AuthBlob.swift"
  "$SCRIPT_DIR/AuthVault.swift"
  "$SCRIPT_DIR/KeychainAuthVault.swift"
  "$SCRIPT_DIR/FileAuthVault.swift"
)
ICON_SRC="$SCRIPT_DIR/assets/codex-profile-switcher-menu-icon.png"
ICON_EMPTY_SRC="$SCRIPT_DIR/assets/codex-profile-switcher-menu-icon-empty.png"
OUT="${1:-$HOME/.local/bin/codex-profile-switcher}"
OUT_DIR="$(dirname "$OUT")"
HELPER_OUT="$OUT_DIR/codex-profile"
ICON_OUT="$OUT_DIR/codex-profile-switcher-menu-icon.png"
ICON_EMPTY_OUT="$OUT_DIR/codex-profile-switcher-menu-icon-empty.png"
MODULE_CACHE="${CODEX_PROFILE_SWIFT_MODULE_CACHE:-${TMPDIR:-/tmp}/codex-profile-switcher-module-cache}"

mkdir -p "$OUT_DIR"
mkdir -p "$MODULE_CACHE"
OUT_TMP="$(mktemp "$OUT_DIR/.codex-profile-switcher.XXXXXX")"
HELPER_TMP="$(mktemp "$OUT_DIR/.codex-profile.XXXXXX")"
trap 'rm -f "$OUT_TMP" "$HELPER_TMP"' EXIT

echo "Building CodexProfileSwitcher..."
swiftc -O \
  -o "$OUT_TMP" \
  "${SWIFT_SOURCES[@]}" \
  -framework Cocoa \
  -framework SwiftUI \
  -framework Security \
  -parse-as-library \
  -module-cache-path "$MODULE_CACHE"

chmod +x "$OUT_TMP"
codesign -s - --force "$OUT_TMP"
mv -f "$OUT_TMP" "$OUT"

if [[ -f "$HELPER_SRC" ]]; then
  echo "Building helper..."
  swiftc -O \
    -o "$HELPER_TMP" \
    "${HELPER_SOURCES[@]}" \
    -framework Foundation \
    -framework Security \
    -module-cache-path "$MODULE_CACHE"
  chmod +x "$HELPER_TMP"
  codesign -s - --force "$HELPER_TMP"
  mv -f "$HELPER_TMP" "$HELPER_OUT"
  echo "Installed helper: $HELPER_OUT"
else
  echo "Warning: helper not found at $HELPER_SRC" >&2
fi

if [[ -f "$ICON_SRC" ]]; then
  cp "$ICON_SRC" "$ICON_OUT"
  echo "Installed icon: $ICON_OUT"
else
  echo "Warning: icon not found at $ICON_SRC" >&2
fi

if [[ -f "$ICON_EMPTY_SRC" ]]; then
  cp "$ICON_EMPTY_SRC" "$ICON_EMPTY_OUT"
  echo "Installed empty icon: $ICON_EMPTY_OUT"
else
  echo "Warning: empty icon not found at $ICON_EMPTY_SRC" >&2
fi

echo "Built: $OUT"
trap - EXIT
