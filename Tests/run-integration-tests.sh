#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/codex-profile-integration.XXXXXX")"
HELPER="$WORK_DIR/codex-profile"
FAKE_APP="$WORK_DIR/fake-codex-app"
FAKE_CODEX="$WORK_DIR/fake-codex"
LAUNCH_LOG="$WORK_DIR/fake-app-launch.log"
LOGIN_HOME_LOG="$WORK_DIR/fake-codex-login-home.log"
TEST_HOME="$WORK_DIR/home"
AUTH_STORE="$WORK_DIR/auth-store"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

cleanup() {
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

swiftc \
  "$ROOT_DIR/CodexProfileCLI.swift" \
  "$ROOT_DIR/AuthBlob.swift" \
  "$ROOT_DIR/AuthVault.swift" \
  "$ROOT_DIR/KeychainAuthVault.swift" \
  "$ROOT_DIR/FileAuthVault.swift" \
  -framework Foundation \
  -framework Security \
  -o "$HELPER"

printf '%s\n' \
  '#!/usr/bin/env bash' \
  'set -euo pipefail' \
  "printf \"launch:%s\\n\" \"\$*\" >> \"$LAUNCH_LOG\"" \
  > "$FAKE_APP"
chmod +x "$FAKE_APP"

printf '%s\n' \
  '#!/usr/bin/env bash' \
  'set -euo pipefail' \
  'case "${1:-}" in' \
  '  --version)' \
  '    printf "fake-codex 1.0\n"' \
  '    ;;' \
  '  login)' \
  '    printf "%s" "${CODEX_HOME:?}" > "${FAKE_CODEX_LOGIN_HOME_LOG:?}"' \
  '    if [[ "${FAKE_CODEX_LOGIN_WRITE_AUTH:-1}" == "1" ]]; then' \
  '      mkdir -p "$CODEX_HOME"' \
  '      cp "${FAKE_CODEX_LOGIN_AUTH:?}" "$CODEX_HOME/auth.json"' \
  '    fi' \
  '    exit "${FAKE_CODEX_LOGIN_STATUS:-0}"' \
  '    ;;' \
  '  *)' \
  '    printf "unexpected fake codex command: %s\n" "$*" >&2' \
  '    exit 2' \
  '    ;;' \
  'esac' \
  > "$FAKE_CODEX"
chmod +x "$FAKE_CODEX"

reset_home() {
  rm -rf "$TEST_HOME" "$AUTH_STORE"
  mkdir -p "$TEST_HOME/.codex" "$AUTH_STORE"
}

make_api_auth() {
  local path="$1"
  local key="$2"
  local marker="$3"
  printf '{\n  "OPENAI_API_KEY" : "%s",\n  "marker" : "%s"\n}\n' "$key" "$marker" > "$path"
}

save_auth() {
  local profile="$1"
  local path="$2"
  cp "$path" "$AUTH_STORE/$profile.json"
  chmod 600 "$AUTH_STORE/$profile.json"
}

export_auth() {
  local profile="$1"
  local path="$2"
  cp "$AUTH_STORE/$profile.json" "$path"
}

run_helper() {
  CODEX_PROFILE_HOME="$TEST_HOME" \
    CODEX_PROFILE_TEST_AUTH_STORE_DIR="$AUTH_STORE" \
    CODEX_PROFILE_TEST_ASSUME_CODEX_STOPPED=1 \
    CODEX_APP_BIN="$FAKE_APP" \
    CODEX_CLI="$FAKE_CODEX" \
    FAKE_CODEX_LOGIN_HOME_LOG="$LOGIN_HOME_LOG" \
    "$HELPER" "$@"
}

assert_same_file() {
  local actual="$1"
  local expected="$2"
  local message="$3"
  cmp -s "$actual" "$expected" || fail "$message"
}

wait_for_launch_log() {
  local expected="$1"
  for _ in {1..40}; do
    if [[ -f "$LAUNCH_LOG" ]] && grep -Fq "$expected" "$LAUNCH_LOG"; then
      return
    fi
    sleep 0.05
  done
  if [[ -f "$LAUNCH_LOG" ]]; then
    printf 'Launch log contents:\n' >&2
    sed -n '1,20p' "$LAUNCH_LOG" >&2
  fi
  fail "fake Codex app launch was not recorded"
}

test_switch_preserves_outgoing_auth() {
  reset_home
  : > "$LAUNCH_LOG"
  local workspace="$WORK_DIR/workspace-switch"
  mkdir -p "$workspace"
  workspace="$(cd "$workspace" && pwd -P)"

  local saved_a="$WORK_DIR/saved-a.json"
  local live_a="$WORK_DIR/live-a.json"
  local saved_b="$WORK_DIR/saved-b.json"
  local exported_a="$WORK_DIR/exported-a.json"
  make_api_auth "$saved_a" "sk-test-switch-a-1111111111111111" "saved-a"
  make_api_auth "$live_a" "sk-test-switch-a-1111111111111111" "live-a"
  make_api_auth "$saved_b" "sk-test-switch-b-2222222222222222" "saved-b"
  save_auth "SwitchA" "$saved_a"
  save_auth "SwitchB" "$saved_b"
  cp "$live_a" "$TEST_HOME/.codex/auth.json"

  run_helper app SwitchB "$workspace" >/dev/null

  assert_same_file "$TEST_HOME/.codex/auth.json" "$saved_b" "selected profile auth was not restored to live auth"
  export_auth "SwitchA" "$exported_a"
  assert_same_file "$exported_a" "$live_a" "outgoing live auth was not saved back to the matching profile"
  grep -Fq '"activeProfile" : "SwitchB"' "$TEST_HOME/.codex-switcher/config.json" \
    || fail "active profile was not updated after switch"
  wait_for_launch_log "workspace-switch"
}

test_switch_refuses_unmanaged_live_auth() {
  reset_home
  local saved_a="$WORK_DIR/unmanaged-a.json"
  local saved_b="$WORK_DIR/unmanaged-b.json"
  local live_unknown="$WORK_DIR/live-unknown.json"
  local exported_a="$WORK_DIR/exported-unmanaged-a.json"
  make_api_auth "$saved_a" "sk-test-unmanaged-a-1111111111" "saved-a"
  make_api_auth "$saved_b" "sk-test-unmanaged-b-2222222222" "saved-b"
  make_api_auth "$live_unknown" "sk-test-unmanaged-c-3333333333" "live-unknown"
  save_auth "UnmanagedA" "$saved_a"
  save_auth "UnmanagedB" "$saved_b"
  cp "$live_unknown" "$TEST_HOME/.codex/auth.json"

  if run_helper app UnmanagedB "$WORK_DIR" >/dev/null 2>"$WORK_DIR/unmanaged.err"; then
    fail "switch succeeded even though live auth did not match any saved profile"
  fi

  assert_same_file "$TEST_HOME/.codex/auth.json" "$live_unknown" "unmanaged live auth was modified"
  export_auth "UnmanagedA" "$exported_a"
  assert_same_file "$exported_a" "$saved_a" "saved auth changed after refused unmanaged switch"
}

test_switch_refuses_ambiguous_live_auth() {
  reset_home
  local duplicate_a="$WORK_DIR/duplicate-a.json"
  local saved_b="$WORK_DIR/duplicate-b.json"
  local exported_a="$WORK_DIR/exported-duplicate-a.json"
  make_api_auth "$duplicate_a" "sk-test-duplicate-a-1111111111" "duplicate-a"
  make_api_auth "$saved_b" "sk-test-duplicate-b-2222222222" "duplicate-b"
  save_auth "DuplicateA" "$duplicate_a"
  save_auth "DuplicateClone" "$duplicate_a"
  save_auth "DuplicateB" "$saved_b"
  cp "$duplicate_a" "$TEST_HOME/.codex/auth.json"

  if run_helper app DuplicateB "$WORK_DIR" >/dev/null 2>"$WORK_DIR/duplicate.err"; then
    fail "switch succeeded even though live auth matched multiple saved profiles"
  fi

  assert_same_file "$TEST_HOME/.codex/auth.json" "$duplicate_a" "ambiguous live auth was modified"
  export_auth "DuplicateA" "$exported_a"
  assert_same_file "$exported_a" "$duplicate_a" "saved auth changed after refused ambiguous switch"
}

test_login_uses_isolated_home_and_preserves_live_auth() {
  reset_home
  local live="$WORK_DIR/login-live.json"
  local login="$WORK_DIR/login-result.json"
  local exported="$WORK_DIR/exported-login.json"
  make_api_auth "$live" "sk-test-login-live-1111111111" "live"
  make_api_auth "$login" "sk-test-login-result-2222222222" "login"
  cp "$live" "$TEST_HOME/.codex/auth.json"

  FAKE_CODEX_LOGIN_AUTH="$login" run_helper login LoginProfile >/dev/null

  assert_same_file "$TEST_HOME/.codex/auth.json" "$live" "login modified live Codex auth"
  export_auth "LoginProfile" "$exported"
  assert_same_file "$exported" "$login" "login auth was not saved to the selected profile"
  local isolated_home
  isolated_home="$(cat "$LOGIN_HOME_LOG")"
  case "$isolated_home" in
    */.codex-switcher/tmp/LoginProfile-*) ;;
    *) fail "login did not use an isolated CODEX_HOME under .codex-switcher/tmp (got $isolated_home)" ;;
  esac
}

test_login_fails_when_codex_writes_no_auth() {
  reset_home
  if FAKE_CODEX_LOGIN_WRITE_AUTH=0 run_helper login MissingAuth >/dev/null 2>"$WORK_DIR/missing-auth.err"; then
    fail "login succeeded even though fake codex wrote no auth.json"
  fi
  if [[ -f "$AUTH_STORE/MissingAuth.json" ]]; then
    fail "missing-auth login saved a profile anyway"
  fi
}

test_switch_preserves_outgoing_auth
test_switch_refuses_unmanaged_live_auth
test_switch_refuses_ambiguous_live_auth
test_login_uses_isolated_home_and_preserves_live_auth
test_login_fails_when_codex_writes_no_auth

printf 'Integration tests: all tests passed\n'
