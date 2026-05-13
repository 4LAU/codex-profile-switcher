#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="${VERSION:-$(sed -n 's/.*static let version = "\(.*\)".*/\1/p' "$ROOT_DIR/CodexProfileSwitcher.swift" | head -n 1)}"
VERSION="${VERSION:-0.1.0}"
RELEASE_DIR="${RELEASE_DIR:-$ROOT_DIR/.build/release}"
DMG_PATH="${DMG_PATH:-$RELEASE_DIR/CodexProfileSwitcher-$VERSION.dmg}"
CHECKSUM_PATH="${CHECKSUM_PATH:-$DMG_PATH.sha256}"
CASK_OUTPUT_PATH="${CASK_OUTPUT_PATH:-$RELEASE_DIR/codex-profile-switcher.rb}"
GITHUB_REPOSITORY="${GITHUB_REPOSITORY:-4LAU/codex-profile-switcher}"
TAG_NAME="${TAG_NAME:-v$VERSION}"
CASK_TOKEN="${CASK_TOKEN:-codex-profile-switcher}"

fail() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

[[ -f "$CHECKSUM_PATH" ]] || fail "checksum file not found: $CHECKSUM_PATH"

SHA256="$(awk '{print $1}' "$CHECKSUM_PATH")"
[[ "$SHA256" =~ ^[0-9a-fA-F]{64}$ ]] || fail "invalid SHA-256 in $CHECKSUM_PATH"

mkdir -p "$(dirname "$CASK_OUTPUT_PATH")"

cat > "$CASK_OUTPUT_PATH" <<CASK
cask "$CASK_TOKEN" do
  version "$VERSION"
  sha256 "$SHA256"

  url "https://github.com/$GITHUB_REPOSITORY/releases/download/$TAG_NAME/CodexProfileSwitcher-#{version}.dmg"
  name "Codex Profile Switcher"
  desc "Switch OpenAI Codex accounts from the macOS menu bar"
  homepage "https://github.com/$GITHUB_REPOSITORY"

  depends_on macos: ">= :sonoma"

  app "CodexProfileSwitcher.app"

  zap trash: [
    "~/Library/Logs/CodexProfileSwitcher",
    "~/Library/Preferences/com.4lau.codex-profile-switcher.plist",
  ]
end
CASK

printf 'Generated Homebrew cask: %s\n' "$CASK_OUTPUT_PATH"
