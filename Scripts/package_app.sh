#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ -f "$ROOT_DIR/version.env" ]]; then
  source "$ROOT_DIR/version.env"
fi
APP_BUNDLE="${APP_BUNDLE:-$ROOT_DIR/CodexProfileSwitcher.app}"
BUILD_DIR="${CODEX_PROFILE_PACKAGE_BUILD_DIR:-$ROOT_DIR/.build/package-app}"
PACKAGE_SCRATCH="$BUILD_DIR/swiftpm"
BUNDLE_ID="${BUNDLE_ID:-com.4lau.codex-profile-switcher}"
MARKETING_VERSION="${MARKETING_VERSION:-0.1.0}"
BUILD_NUMBER="${BUILD_NUMBER:-$(git -C "$ROOT_DIR" rev-list --count HEAD 2>/dev/null || printf '1')}"

if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app ]]; then
  export DEVELOPER_DIR=/Applications/Xcode.app
fi

log() {
  printf '%s\n' "$*"
}

has_signing_identity() {
  local identity="${1:-}"
  [[ -n "$identity" ]] || return 1
  security find-identity -p codesigning -v 2>/dev/null | grep -F "\"$identity\"" >/dev/null 2>&1
}

codesign_args=()
if [[ -n "${APP_IDENTITY:-}" ]]; then
  if has_signing_identity "$APP_IDENTITY"; then
    codesign_args=(--force --timestamp --options runtime --sign "$APP_IDENTITY")
  elif [[ "${CODEX_PROFILE_REQUIRE_SIGNING:-0}" == "1" ]]; then
    printf 'ERROR: APP_IDENTITY was not found in the codesigning keychain: %s\n' "$APP_IDENTITY" >&2
    exit 1
  else
    log "WARN: APP_IDENTITY was not found in the codesigning keychain; falling back to ad-hoc signing."
    codesign_args=(--force --sign -)
  fi
elif [[ "${CODEX_PROFILE_REQUIRE_SIGNING:-0}" == "1" ]]; then
  printf 'ERROR: APP_IDENTITY is required when CODEX_PROFILE_REQUIRE_SIGNING=1.\n' >&2
  exit 1
else
  codesign_args=(--force --sign -)
fi

mkdir -p "$BUILD_DIR" "$PACKAGE_SCRATCH"

log "Ensuring Sparkle framework is available..."
"$ROOT_DIR/Scripts/fetch_sparkle.sh"
SPARKLE_DIR="$ROOT_DIR/.build/sparkle"

if [[ -z "${SPARKLE_ED_PUBLIC_KEY:-}" ]]; then
  if [[ "${CODEX_PROFILE_REQUIRE_SIGNING:-0}" == "1" ]]; then
    printf 'ERROR: SPARKLE_ED_PUBLIC_KEY is required for signed release builds.\n' >&2
    exit 1
  fi
  log "WARN: SPARKLE_ED_PUBLIC_KEY is not set — Sparkle update verification will not work."
fi

log "Building CodexProfileSwitcher..."
swift build \
  --package-path "$ROOT_DIR" \
  -c release \
  --product CodexProfileSwitcher \
  --scratch-path "$PACKAGE_SCRATCH" \
  -Xswiftc -F -Xswiftc "$SPARKLE_DIR" \
  -Xlinker -F -Xlinker "$SPARKLE_DIR" \
  -Xlinker -framework -Xlinker Sparkle \
  -Xlinker -rpath -Xlinker @executable_path/../Frameworks

log "Building codex-profile helper..."
swift build \
  --package-path "$ROOT_DIR" \
  -c release \
  --product codex-profile \
  --scratch-path "$PACKAGE_SCRATCH"
BIN_DIR="$(swift build --package-path "$ROOT_DIR" -c release --scratch-path "$PACKAGE_SCRATCH" --show-bin-path)"
APP_BINARY="$BIN_DIR/CodexProfileSwitcher"
HELPER_BINARY="$BIN_DIR/codex-profile"

rm -rf "$APP_BUNDLE"
mkdir -p \
  "$APP_BUNDLE/Contents/MacOS" \
  "$APP_BUNDLE/Contents/Helpers" \
  "$APP_BUNDLE/Contents/Resources" \
  "$APP_BUNDLE/Contents/Frameworks"

cp "$APP_BINARY" "$APP_BUNDLE/Contents/MacOS/CodexProfileSwitcher"
cp "$HELPER_BINARY" "$APP_BUNDLE/Contents/Helpers/codex-profile"
chmod +x "$APP_BUNDLE/Contents/MacOS/CodexProfileSwitcher" "$APP_BUNDLE/Contents/Helpers/codex-profile"

log "Embedding Sparkle.framework..."
cp -R "$SPARKLE_DIR/Sparkle.framework" "$APP_BUNDLE/Contents/Frameworks/Sparkle.framework"
rm -rf "$APP_BUNDLE/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices"
rm -f "$APP_BUNDLE/Contents/Frameworks/Sparkle.framework/XPCServices"

for icon in \
  codex-profile-switcher-menu-icon.png \
  codex-profile-switcher-menu-icon-empty.png \
  AppIcon.icns
do
  if [[ -f "$ROOT_DIR/assets/$icon" ]]; then
    cp "$ROOT_DIR/assets/$icon" "$APP_BUNDLE/Contents/Resources/$icon"
  else
    log "WARN: missing icon asset: assets/$icon"
  fi
done

BUILD_TIMESTAMP="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
GIT_COMMIT="$(git -C "$ROOT_DIR" rev-parse --short HEAD 2>/dev/null || printf 'unknown')"

cat > "$APP_BUNDLE/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>
  <string>CodexProfileSwitcher</string>
  <key>CFBundleDisplayName</key>
  <string>Codex Profile Switcher</string>
  <key>CFBundleIdentifier</key>
  <string>$BUNDLE_ID</string>
  <key>CFBundleExecutable</key>
  <string>CodexProfileSwitcher</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>$MARKETING_VERSION</string>
  <key>CFBundleVersion</key>
  <string>$BUILD_NUMBER</string>
  <key>LSMinimumSystemVersion</key>
  <string>14.0</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>LSUIElement</key>
  <true/>
  <key>CodexProfileSwitcherBuildTimestamp</key>
  <string>$BUILD_TIMESTAMP</string>
  <key>CodexProfileSwitcherGitCommit</key>
  <string>$GIT_COMMIT</string>
  <key>SUFeedURL</key>
  <string>https://raw.githubusercontent.com/4LAU/codex-profile-switcher/main/appcast.xml</string>
  <key>SUEnableAutomaticChecks</key>
  <true/>
</dict>
</plist>
PLIST

if [[ -n "${SPARKLE_ED_PUBLIC_KEY:-}" ]]; then
  plutil -insert SUPublicEDKey -string "$SPARKLE_ED_PUBLIC_KEY" "$APP_BUNDLE/Contents/Info.plist"
fi

chmod -R u+w "$APP_BUNDLE"
xattr -cr "$APP_BUNDLE"
find "$APP_BUNDLE" -name '._*' -delete

log "Signing helper..."
codesign "${codesign_args[@]}" "$APP_BUNDLE/Contents/Helpers/codex-profile"

log "Signing Sparkle framework components..."
codesign "${codesign_args[@]}" "$APP_BUNDLE/Contents/Frameworks/Sparkle.framework/Versions/B/Autoupdate"
codesign "${codesign_args[@]}" "$APP_BUNDLE/Contents/Frameworks/Sparkle.framework/Versions/B/Updater.app"
codesign "${codesign_args[@]}" "$APP_BUNDLE/Contents/Frameworks/Sparkle.framework"

log "Signing app..."
codesign "${codesign_args[@]}" --entitlements "$ROOT_DIR/CodexProfileSwitcher.entitlements" "$APP_BUNDLE"
codesign --verify --strict --verbose=2 "$APP_BUNDLE" >/dev/null

log "Created $APP_BUNDLE"
