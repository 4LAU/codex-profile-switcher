#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_BUNDLE="${APP_BUNDLE:-$ROOT_DIR/CodexProfileSwitcher.app}"
APP_BIN="$APP_BUNDLE/Contents/MacOS/CodexProfileSwitcher"
HELPER="$APP_BUNDLE/Contents/Helpers/codex-profile"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/codex-profile-keychain-smoke.XXXXXX")"
TEST_HOME="$WORK_DIR/home"
FAKE_APP="$WORK_DIR/fake-codex-app"
FAKE_CODEX="$WORK_DIR/fake-codex"
LAUNCH_LOG="$WORK_DIR/fake-app-launch.log"
SERVICE="${CODEX_PROFILE_SMOKE_KEYCHAIN_SERVICE:-com.4lau.codex-profile-switcher.smoke.$(date +%s).$$}"
LEGACY_ACL_SERVICE="$SERVICE.legacy-acl"

cleanup() {
  local service
  for service in "$SERVICE" "$LEGACY_ACL_SERVICE"; do
    security delete-generic-password -s "$service" >/dev/null 2>&1 || true
    while security delete-generic-password -s "$service" >/dev/null 2>&1; do :; done
  done
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
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
    fail "command failed or timed out after ${seconds}s: $*"
  fi
  kill "$watcher" 2>/dev/null || true
  wait "$watcher" 2>/dev/null || true
}

make_api_auth() {
  local path="$1"
  local key="$2"
  local marker="$3"
  printf '{\n  "OPENAI_API_KEY" : "%s",\n  "marker" : "%s"\n}\n' "$key" "$marker" > "$path"
}

assert_same_file() {
  local actual="$1"
  local expected="$2"
  local message="$3"
  cmp -s "$actual" "$expected" || fail "$message"
}

"$ROOT_DIR/Scripts/package_app.sh"
[[ -x "$APP_BIN" ]] || fail "packaged app binary missing at $APP_BIN"
[[ -x "$HELPER" ]] || fail "packaged helper missing at $HELPER"

mkdir -p "$TEST_HOME/.codex"

cat > "$FAKE_APP" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf "launch:%s\n" "$*" >> "${FAKE_APP_LAUNCH_LOG:?}"
SH
chmod +x "$FAKE_APP"

cat > "$FAKE_CODEX" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in
  --version)
    printf "fake-codex 1.0\n"
    ;;
  login)
    mkdir -p "${CODEX_HOME:?}"
    cp "${FAKE_CODEX_LOGIN_AUTH:?}" "$CODEX_HOME/auth.json"
    ;;
  *)
    printf "unexpected fake codex command: %s\n" "$*" >&2
    exit 2
    ;;
esac
SH
chmod +x "$FAKE_CODEX"

AUTH_A="$WORK_DIR/a.json"
AUTH_B="$WORK_DIR/b.json"
make_api_auth "$AUTH_A" "sk-test-smoke-a-1111111111111111" "smoke-a"
make_api_auth "$AUTH_B" "sk-test-smoke-b-2222222222222222" "smoke-b"

printf 'Using disposable Keychain service: %s\n' "$SERVICE"
printf 'If macOS prompts, approve access for the signed app/helper. Repeat switches should complete without additional prompts.\n'

COMMON_ENV=(
  CODEX_PROFILE_HOME="$TEST_HOME"
  CODEX_PROFILE_KEYCHAIN_SERVICE="$SERVICE"
  CODEX_PROFILE_TEST_ASSUME_CODEX_STOPPED=1
  CODEX_APP_BIN="$FAKE_APP"
  CODEX_CLI="$FAKE_CODEX"
  FAKE_APP_LAUNCH_LOG="$LAUNCH_LOG"
)

run_helper() {
  run_with_timeout 120 env "${COMMON_ENV[@]}" "$@"
}

run_legacy_acl_interop() {
  local test_home="$WORK_DIR/legacy-acl-home"
  local test_auth="$WORK_DIR/legacy-acl-auth.json"
  local status_file="$WORK_DIR/legacy-acl.status"

  printf '==> Legacy ACL interop: helper write -> helper read\n'
  mkdir -p "$test_home/.codex"
  make_api_auth "$test_auth" "sk-test-smoke-helper-write-3333333333333333" "helper-write"

  run_with_timeout 120 env "${COMMON_ENV[@]}" \
    CODEX_PROFILE_HOME="$test_home" \
    CODEX_PROFILE_KEYCHAIN_SERVICE="$LEGACY_ACL_SERVICE" \
    FAKE_CODEX_LOGIN_AUTH="$test_auth" \
    "$HELPER" login HelperWrites >/dev/null

  run_with_timeout 120 env "${COMMON_ENV[@]}" \
    CODEX_PROFILE_HOME="$test_home" \
    CODEX_PROFILE_KEYCHAIN_SERVICE="$LEGACY_ACL_SERVICE" \
    "$HELPER" status HelperWrites > "$status_file"
  grep -Fq "HelperWrites: Saved API key auth" "$status_file" \
    || fail "helper could not read back its legacy ACL Keychain write"

  security delete-generic-password -s "$LEGACY_ACL_SERVICE" -a "HelperWrites" >/dev/null 2>&1 || true
  printf '==> Legacy ACL interop: cleanup done\n'
}

run_helper FAKE_CODEX_LOGIN_AUTH="$AUTH_A" "$HELPER" login SmokeA >/dev/null
run_helper FAKE_CODEX_LOGIN_AUTH="$AUTH_B" "$HELPER" login SmokeB >/dev/null
run_helper "$HELPER" keychain-repair >/dev/null

cp "$AUTH_A" "$TEST_HOME/.codex/auth.json"

run_helper "$HELPER" app SmokeB "$WORK_DIR" >/dev/null
assert_same_file "$TEST_HOME/.codex/auth.json" "$AUTH_B" "SmokeB was not restored to live auth"

run_helper "$HELPER" app SmokeA "$WORK_DIR" >/dev/null
assert_same_file "$TEST_HOME/.codex/auth.json" "$AUTH_A" "SmokeA was not restored to live auth"

run_helper "$HELPER" app SmokeB "$WORK_DIR" >/dev/null
assert_same_file "$TEST_HOME/.codex/auth.json" "$AUTH_B" "repeat SmokeB switch did not restore live auth"

run_legacy_acl_interop

printf 'Signed Keychain smoke passed. Launch log: %s\n' "$LAUNCH_LOG"
