#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="$(mktemp -d "${TMPDIR:-/tmp}/codex-profile-swift-tests.XXXXXX")"
trap 'rm -rf "$BUILD_DIR"' EXIT

swiftc \
  "$ROOT_DIR/AuthBlob.swift" \
  "$ROOT_DIR/Tests/Swift/AuthBlobTests.swift" \
  -o "$BUILD_DIR/AuthBlobTests"

"$BUILD_DIR/AuthBlobTests"

swiftc \
  -D TESTING \
  "$ROOT_DIR/CodexProfileSwitcher.swift" \
  "$ROOT_DIR/AuthBlob.swift" \
  "$ROOT_DIR/AuthVault.swift" \
  "$ROOT_DIR/KeychainAuthVault.swift" \
  "$ROOT_DIR/Tests/Swift/LogRedactorTests.swift" \
  -framework Cocoa \
  -framework SwiftUI \
  -framework Security \
  -parse-as-library \
  -o "$BUILD_DIR/LogRedactorTests"

"$BUILD_DIR/LogRedactorTests"

swiftc \
  -D TESTING \
  "$ROOT_DIR/CodexProfileSwitcher.swift" \
  "$ROOT_DIR/AuthBlob.swift" \
  "$ROOT_DIR/AuthVault.swift" \
  "$ROOT_DIR/KeychainAuthVault.swift" \
  "$ROOT_DIR/FileAuthVault.swift" \
  "$ROOT_DIR/Tests/Swift/ProfileStoreEnvironmentTests.swift" \
  -framework Cocoa \
  -framework SwiftUI \
  -framework Security \
  -parse-as-library \
  -o "$BUILD_DIR/ProfileStoreEnvironmentTests"

"$BUILD_DIR/ProfileStoreEnvironmentTests"

swiftc \
  -D TESTING \
  "$ROOT_DIR/CodexProfileSwitcher.swift" \
  "$ROOT_DIR/AuthBlob.swift" \
  "$ROOT_DIR/AuthVault.swift" \
  "$ROOT_DIR/KeychainAuthVault.swift" \
  "$ROOT_DIR/Tests/Swift/CLIUsageFetcherTests.swift" \
  -framework Cocoa \
  -framework SwiftUI \
  -framework Security \
  -parse-as-library \
  -o "$BUILD_DIR/CLIUsageFetcherTests"

"$BUILD_DIR/CLIUsageFetcherTests"
