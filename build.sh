#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC="$SCRIPT_DIR/CodexProfileSwitcher.swift"
OUT="${1:-$HOME/.local/bin/codex-profile-switcher}"

mkdir -p "$(dirname "$OUT")"

echo "Building CodexProfileSwitcher..."
swiftc -O \
  -o "$OUT" \
  "$SRC" \
  -framework Cocoa \
  -framework SwiftUI \
  -parse-as-library

echo "Built: $OUT"
