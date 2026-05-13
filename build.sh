#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC="$SCRIPT_DIR/CodexProfileSwitcher.swift"
HELPER_SRC="$SCRIPT_DIR/bin/codex-profile"
OUT="${1:-$HOME/.local/bin/codex-profile-switcher}"
OUT_DIR="$(dirname "$OUT")"
HELPER_OUT="$OUT_DIR/codex-profile"
MODULE_CACHE="${CODEX_PROFILE_SWIFT_MODULE_CACHE:-${TMPDIR:-/tmp}/codex-profile-switcher-module-cache}"

mkdir -p "$OUT_DIR"
mkdir -p "$MODULE_CACHE"
OUT_TMP="$(mktemp "$OUT_DIR/.codex-profile-switcher.XXXXXX")"
trap 'rm -f "$OUT_TMP"' EXIT

echo "Building CodexProfileSwitcher..."
swiftc -O \
  -o "$OUT_TMP" \
  "$SRC" \
  -framework Cocoa \
  -framework SwiftUI \
  -parse-as-library \
  -module-cache-path "$MODULE_CACHE"

chmod +x "$OUT_TMP"
mv -f "$OUT_TMP" "$OUT"
trap - EXIT

if [[ -f "$HELPER_SRC" ]]; then
  cp "$HELPER_SRC" "$HELPER_OUT"
  chmod +x "$HELPER_OUT"
  echo "Installed helper: $HELPER_OUT"
else
  echo "Warning: helper not found at $HELPER_SRC" >&2
fi

echo "Built: $OUT"
