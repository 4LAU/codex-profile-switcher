#!/usr/bin/env bash
set -euo pipefail

SPARKLE_VERSION="2.9.1"
SPARKLE_SHA256="c0dde519fd2a43ddfc6a1eb76aec284d7d888fe281414f9177de3164d98ba4c7"
SPARKLE_URL="https://github.com/sparkle-project/Sparkle/releases/download/${SPARKLE_VERSION}/Sparkle-${SPARKLE_VERSION}.tar.xz"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SPARKLE_DIR="$ROOT_DIR/.build/sparkle"
MARKER="$SPARKLE_DIR/.sparkle-${SPARKLE_VERSION}"

if [[ -f "$MARKER" ]]; then
    echo "Sparkle ${SPARKLE_VERSION} already fetched."
    exit 0
fi

echo "Fetching Sparkle ${SPARKLE_VERSION}..."
mkdir -p "$SPARKLE_DIR"

TMPFILE="$(mktemp "${TMPDIR:-/tmp}/Sparkle-XXXXXX.tar.xz")"
trap 'rm -f "$TMPFILE"' EXIT

curl -fSL --retry 3 -o "$TMPFILE" "$SPARKLE_URL"

ACTUAL_SHA256="$(shasum -a 256 "$TMPFILE" | cut -d' ' -f1)"
if [[ "$ACTUAL_SHA256" != "$SPARKLE_SHA256" ]]; then
    printf 'ERROR: SHA256 mismatch.\n  expected: %s\n  actual:   %s\n' "$SPARKLE_SHA256" "$ACTUAL_SHA256" >&2
    exit 1
fi

rm -rf "$SPARKLE_DIR/Sparkle.framework" "$SPARKLE_DIR/bin"
tar xJf "$TMPFILE" -C "$SPARKLE_DIR"

if [[ ! -d "$SPARKLE_DIR/Sparkle.framework" ]]; then
    echo "ERROR: Sparkle.framework not found after extraction." >&2
    exit 1
fi

touch "$MARKER"
echo "Sparkle ${SPARKLE_VERSION} installed to $SPARKLE_DIR"
