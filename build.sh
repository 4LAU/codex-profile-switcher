#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ICON_SRC="$SCRIPT_DIR/assets/codex-profile-switcher-menu-icon.png"
ICON_EMPTY_SRC="$SCRIPT_DIR/assets/codex-profile-switcher-menu-icon-empty.png"
OUT="${1:-$HOME/.local/bin/codex-profile-switcher}"
OUT_DIR="$(dirname "$OUT")"
HELPER_OUT="$OUT_DIR/codex-profile"
ICON_OUT="$OUT_DIR/codex-profile-switcher-menu-icon.png"
ICON_EMPTY_OUT="$OUT_DIR/codex-profile-switcher-menu-icon-empty.png"
BUILD_DIR="${CODEX_PROFILE_BUILD_DIR:-$SCRIPT_DIR/.build/dev}"

if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app ]]; then
  export DEVELOPER_DIR=/Applications/Xcode.app
fi

mkdir -p "$OUT_DIR"
mkdir -p "$BUILD_DIR"
OUT_TMP="$(mktemp "$OUT_DIR/.codex-profile-switcher.XXXXXX")"
HELPER_TMP="$(mktemp "$OUT_DIR/.codex-profile.XXXXXX")"
trap 'rm -f "$OUT_TMP" "$HELPER_TMP"' EXIT

echo "Building CodexProfileSwitcher..."
swift build -c release --product CodexProfileSwitcher --scratch-path "$BUILD_DIR"
BIN_DIR="$(swift build -c release --scratch-path "$BUILD_DIR" --show-bin-path)"
cp "$BIN_DIR/CodexProfileSwitcher" "$OUT_TMP"

chmod +x "$OUT_TMP"
codesign -s - --force "$OUT_TMP"
mv -f "$OUT_TMP" "$OUT"

echo "Building helper..."
swift build -c release --product codex-profile --scratch-path "$BUILD_DIR"
cp "$BIN_DIR/codex-profile" "$HELPER_TMP"
chmod +x "$HELPER_TMP"
codesign -s - --force "$HELPER_TMP"
mv -f "$HELPER_TMP" "$HELPER_OUT"
echo "Installed helper: $HELPER_OUT"

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
