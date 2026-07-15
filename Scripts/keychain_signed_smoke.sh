#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_BUNDLE="${APP_BUNDLE:-$ROOT_DIR/CodexProfileSwitcher.app}"
REPACKAGED_APP_BUNDLE="${REPACKAGED_APP_BUNDLE:-}"
APP_BUNDLE_ID="com.4lau.codex-profile-switcher"
HELPER_BUNDLE_ID="com.4lau.codex-profile-switcher.helper"
ACCESS_GROUP="W3ZHLSH96F.com.4lau.codex-profile-switcher.auth-v2"
SMOKE_SERVICE_PREFIX="com.4lau.codex-profile-switcher.auth.smoke."
SERVICE="${CODEX_PROFILE_SMOKE_KEYCHAIN_SERVICE:-$SMOKE_SERVICE_PREFIX$(date +%s).$$}"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/codex-profile-keychain-smoke.XXXXXX")"
TEST_HOME="$WORK_DIR/home"
FAKE_APP="$WORK_DIR/Codex.app"
FAKE_APP_BIN="$FAKE_APP/Contents/MacOS/Codex"
FAKE_BUNDLED_CLI="$FAKE_APP/Contents/Resources/codex"
FAKE_CODEX="$WORK_DIR/fake-codex"
LAUNCH_LOG="$WORK_DIR/fake-app-launch.log"
HELPER="$APP_BUNDLE/Contents/Helpers/CodexProfileHelper.app/Contents/MacOS/codex-profile"
REPACKAGED_HELPER=""
COMMON_ENV=()
cleanup_pending=0

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

cleanup() {
  if [[ "$cleanup_pending" == "1" && -x "$HELPER" ]]; then
    env "${COMMON_ENV[@]}" "$HELPER" signed-smoke-cleanup SmokeA SmokeB >/dev/null 2>&1 || true
  fi
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

plist_value() {
  /usr/libexec/PlistBuddy -c "Print $2" "$1" 2>/dev/null
}

verify_entitlements() {
  local binary="$1"
  local expected_id="$2"
  local name="$3"
  local entitlements="$WORK_DIR/$name.entitlements"

  codesign -d --entitlements :- "$binary" > "$entitlements" 2>/dev/null \
    || fail "could not inspect $name entitlements"
  plutil -lint "$entitlements" >/dev/null || fail "$name entitlements are not a plist"
  [[ "$(plist_value "$entitlements" ':application-identifier')" == "W3ZHLSH96F.$expected_id" ]] \
    || fail "$name has an unexpected application identifier"
  [[ "$(plist_value "$entitlements" ':keychain-access-groups:0')" == "$ACCESS_GROUP" ]] \
    || fail "$name has an unexpected Keychain group"
  if plist_value "$entitlements" ':keychain-access-groups:1' >/dev/null 2>&1; then
    fail "$name has more than one Keychain group"
  fi
}

verify_bundle() {
  local bundle="$1"
  local name="$2"
  local app_binary="$bundle/Contents/MacOS/CodexProfileSwitcher"
  local helper_bundle="$bundle/Contents/Helpers/CodexProfileHelper.app"
  local helper="$helper_bundle/Contents/MacOS/codex-profile"

  [[ -d "$bundle" ]] || fail "$name app bundle does not exist: $bundle"
  [[ -x "$app_binary" && -x "$helper" ]] || fail "$name app bundle is missing an executable"
  codesign --verify --deep --strict --verbose=2 "$bundle"
  codesign --verify --strict --verbose=2 "$helper_bundle"
  codesign -dvv "$app_binary" 2>&1 | grep -Fq 'Authority=Developer ID Application' \
    || fail "$name app is not Developer ID signed"
  codesign -dvv "$helper" 2>&1 | grep -Fq 'Authority=Developer ID Application' \
    || fail "$name helper is not Developer ID signed"
  [[ "$(plist_value "$bundle/Contents/Info.plist" ':CFBundleIdentifier')" == "$APP_BUNDLE_ID" ]] \
    || fail "$name app has an unexpected bundle identifier"
  [[ "$(plist_value "$helper_bundle/Contents/Info.plist" ':CFBundleIdentifier')" == "$HELPER_BUNDLE_ID" ]] \
    || fail "$name helper has an unexpected bundle identifier"
  verify_entitlements "$app_binary" "$APP_BUNDLE_ID" "$name-app"
  verify_entitlements "$helper" "$HELPER_BUNDLE_ID" "$name-helper"
}

run_with_timeout() {
  local seconds="$1"
  shift
  "$@" &
  local pid=$!
  (
    sleep "$seconds"
    if kill -0 "$pid" 2>/dev/null; then
      kill "$pid" 2>/dev/null || true
    fi
  ) &
  local watcher=$!
  if ! wait "$pid"; then
    kill "$watcher" 2>/dev/null || true
    wait "$watcher" 2>/dev/null || true
    fail "command failed or timed out after ${seconds}s"
  fi
  kill "$watcher" 2>/dev/null || true
  wait "$watcher" 2>/dev/null || true
}

make_api_auth() {
  local path="$1"
  local token="$2"
  printf '{\n  "OPENAI_API_KEY" : "%s"\n}\n' "$token" > "$path"
}

assert_same_file() {
  local actual="$1"
  local expected="$2"
  local message="$3"
  cmp -s "$actual" "$expected" || fail "$message"
}

assert_saved_profile() {
  local helper="$1"
  local profile="$2"
  local status_file="$WORK_DIR/$profile.status"

  run_with_timeout 120 env "${COMMON_ENV[@]}" "$helper" status "$profile" > "$status_file"
  grep -Fq "$profile: Saved API key auth" "$status_file" \
    || fail "$profile could not be read by the signed helper"
}

canonical_bundle_path() {
  local bundle="$1"
  [[ -d "$bundle" ]] || return 1
  (cd "$bundle" && pwd -P)
}

[[ "$SERVICE" == "$SMOKE_SERVICE_PREFIX"* && ${#SERVICE} -gt ${#SMOKE_SERVICE_PREFIX} ]] \
  || fail "CODEX_PROFILE_SMOKE_KEYCHAIN_SERVICE must use the disposable smoke-service prefix"
APP_BUNDLE_CANONICAL="$(canonical_bundle_path "$APP_BUNDLE")" \
  || fail "primary app bundle does not exist: $APP_BUNDLE"
if [[ -n "$REPACKAGED_APP_BUNDLE" ]]; then
  REPACKAGED_APP_BUNDLE_CANONICAL="$(canonical_bundle_path "$REPACKAGED_APP_BUNDLE")" \
    || fail "repackaged app bundle does not exist: $REPACKAGED_APP_BUNDLE"
  [[ "$REPACKAGED_APP_BUNDLE_CANONICAL" != "$APP_BUNDLE_CANONICAL" ]] \
    || fail "REPACKAGED_APP_BUNDLE must be a separately rebuilt app"
fi

verify_bundle "$APP_BUNDLE" "primary"
if [[ -n "$REPACKAGED_APP_BUNDLE" ]]; then
  verify_bundle "$REPACKAGED_APP_BUNDLE" "repackaged"
  REPACKAGED_HELPER="$REPACKAGED_APP_BUNDLE/Contents/Helpers/CodexProfileHelper.app/Contents/MacOS/codex-profile"
fi

mkdir -p "$TEST_HOME/.codex" "$(dirname "$FAKE_APP_BIN")" "$(dirname "$FAKE_BUNDLED_CLI")"

cat > "$FAKE_APP_BIN" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf 'launch:%s\n' "$*" >> "${FAKE_APP_LAUNCH_LOG:?}"
SH
chmod +x "$FAKE_APP_BIN"

cat > "$FAKE_BUNDLED_CLI" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in
  app) printf 'launch:%s\n' "$*" >> "${FAKE_APP_LAUNCH_LOG:?}" ;;
  *) exit 2 ;;
esac
SH
chmod +x "$FAKE_BUNDLED_CLI"

cat > "$FAKE_CODEX" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in
  --version) printf 'fake-codex 1.0\n' ;;
  login)
    mkdir -p "${CODEX_HOME:?}"
    cp "${FAKE_CODEX_LOGIN_AUTH:?}" "$CODEX_HOME/auth.json"
    ;;
  *) exit 2 ;;
esac
SH
chmod +x "$FAKE_CODEX"

AUTH_A="$WORK_DIR/a.json"
AUTH_B="$WORK_DIR/b.json"
make_api_auth "$AUTH_A" "smoke-token-a"
make_api_auth "$AUTH_B" "smoke-token-b"

printf 'Using disposable Keychain service: %s\n' "$SERVICE"
printf 'macOS may ask once to allow the signed app and helper to use this disposable record.\n'

COMMON_ENV=(
  CODEX_PROFILE_HOME="$TEST_HOME"
  CODEX_PROFILE_SIGNED_SMOKE=1
  CODEX_PROFILE_DATA_PROTECTION_KEYCHAIN_SERVICE="$SERVICE"
  CODEX_PROFILE_TEST_ASSUME_CODEX_STOPPED=1
  CODEX_APP="$FAKE_APP"
  CODEX_APP_BIN="$FAKE_APP_BIN"
  CODEX_CLI="$FAKE_CODEX"
  FAKE_APP_LAUNCH_LOG="$LAUNCH_LOG"
)
cleanup_pending=1

run_with_timeout 120 env "${COMMON_ENV[@]}" FAKE_CODEX_LOGIN_AUTH="$AUTH_A" "$HELPER" login SmokeA >/dev/null
run_with_timeout 120 env "${COMMON_ENV[@]}" FAKE_CODEX_LOGIN_AUTH="$AUTH_B" "$HELPER" login SmokeB >/dev/null
assert_saved_profile "$HELPER" SmokeA
assert_saved_profile "$HELPER" SmokeB

cp "$AUTH_A" "$TEST_HOME/.codex/auth.json"
run_with_timeout 120 env "${COMMON_ENV[@]}" "$HELPER" app SmokeB "$WORK_DIR" >/dev/null
assert_same_file "$TEST_HOME/.codex/auth.json" "$AUTH_B" "SmokeB was not restored to live auth"
run_with_timeout 120 env "${COMMON_ENV[@]}" "$HELPER" app SmokeA "$WORK_DIR" >/dev/null
assert_same_file "$TEST_HOME/.codex/auth.json" "$AUTH_A" "SmokeA was not restored to live auth"

if [[ -n "$REPACKAGED_HELPER" ]]; then
  assert_saved_profile "$REPACKAGED_HELPER" SmokeA
  assert_saved_profile "$REPACKAGED_HELPER" SmokeB
fi

run_with_timeout 120 env "${COMMON_ENV[@]}" "$HELPER" signed-smoke-cleanup SmokeA SmokeB >/dev/null
cleanup_pending=0

printf 'Signed disposable Keychain smoke passed.\n'
