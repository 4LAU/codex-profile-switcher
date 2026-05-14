#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

echo "Setting up Sparkle EdDSA signing keys..."
echo ""
echo "This generates an ed25519 keypair for signing Sparkle updates."
echo "The private key will be stored in your macOS Keychain."
echo "The public key must be added to SPARKLE_ED_PUBLIC_KEY in your environment."
echo ""

"$ROOT_DIR/Scripts/fetch_sparkle.sh"
SPARKLE_DIR="$ROOT_DIR/.build/sparkle"

# generate_keys stores the private key in the login keychain
# and prints the public key to stdout
"$SPARKLE_DIR/bin/generate_keys"

echo ""
echo "Add this public key to your shell profile:"
echo "  export SPARKLE_ED_PUBLIC_KEY=\"\$($SPARKLE_DIR/bin/generate_keys -p)\""
