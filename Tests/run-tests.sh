#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

"$ROOT_DIR/Tests/run-swift-tests.sh"
"$ROOT_DIR/Tests/run-integration-tests.sh"

printf 'All tests passed.\n'
