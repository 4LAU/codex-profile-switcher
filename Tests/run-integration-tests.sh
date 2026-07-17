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
BUILD_DIR="$WORK_DIR/build"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

cleanup() {
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app ]]; then
  export DEVELOPER_DIR=/Applications/Xcode.app
fi

swift build \
  --package-path "$ROOT_DIR" \
  -c release \
  --product codex-profile \
  --scratch-path "$BUILD_DIR" \
  >/dev/null
BIN_DIR="$(swift build --package-path "$ROOT_DIR" -c release --scratch-path "$BUILD_DIR" --show-bin-path)"
cp "$BIN_DIR/codex-profile" "$HELPER"
chmod +x "$HELPER"

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

make_oauth_auth() {
  local path="$1"
  local access_token="$2"
  local refresh_token="$3"
  local account_id="$4"
  printf '{\n  "tokens" : {\n    "access_token" : "%s",\n    "refresh_token" : "%s",\n    "account_id" : "%s"\n  }\n}\n' "$access_token" "$refresh_token" "$account_id" > "$path"
}

make_token_only_auth() {
  local path="$1"
  local access_token="$2"
  local refresh_token="$3"
  printf '{\n  "tokens" : {\n    "access_token" : "%s",\n    "refresh_token" : "%s"\n  }\n}\n' "$access_token" "$refresh_token" > "$path"
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
    CODEX_BUNDLED_CLI="$FAKE_APP" \
    CODEX_CLI="$FAKE_CODEX" \
    FAKE_CODEX_LOGIN_HOME_LOG="$LOGIN_HOME_LOG" \
    "$HELPER" "$@"
}

# Like run_helper but WITHOUT CODEX_PROFILE_TEST_AUTH_STORE_DIR, exercising the
# real vault-selection path (unsigned test binary -> file dev vault).
run_helper_dev() {
  CODEX_PROFILE_HOME="$TEST_HOME" \
    CODEX_PROFILE_TEST_ASSUME_CODEX_STOPPED=1 \
    CODEX_BUNDLED_CLI="$FAKE_APP" \
    CODEX_CLI="$FAKE_CODEX" \
    FAKE_CODEX_LOGIN_HOME_LOG="$LOGIN_HOME_LOG" \
    "$HELPER" "$@"
}

run_helper_with_app() {
  local app_bin="$1"
  shift
  CODEX_PROFILE_HOME="$TEST_HOME" \
    CODEX_PROFILE_TEST_AUTH_STORE_DIR="$AUTH_STORE" \
    CODEX_PROFILE_TEST_ASSUME_CODEX_STOPPED=1 \
    CODEX_BUNDLED_CLI="$app_bin" \
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

test_switch_current_chatgpt_layout_stops_running_desktop() {
  reset_home
  : > "$LAUNCH_LOG"
  local app="$WORK_DIR/ChatGPT.app"
  local desktop="$app/Contents/MacOS/ChatGPT"
  local bundled="$app/Contents/Resources/codex"
  local pid_file="$WORK_DIR/chatgpt.pid"
  local stopped="$WORK_DIR/chatgpt.stopped"
  local workspace_log="$WORK_DIR/chatgpt-workspace.log"
  local event_log="$WORK_DIR/chatgpt-events.log"
  local workspace="$WORK_DIR"
  workspace="$(cd "$workspace" && pwd -P)"
  workspace="${workspace#/private}"
  mkdir -p "$(dirname "$desktop")" "$(dirname "$bundled")"
  cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.openai.codex</string>
<key>CFBundleExecutable</key><string>ChatGPT</string>
</dict></plist>
PLIST
  cat > "$desktop" <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
pid_file="$1"
stopped="$2"
event_log="$3"
trap 'printf stopped > "$stopped"; printf "stop\\n" >> "$event_log"; exit 0' TERM INT
printf '%s' "$$" > "$pid_file"
while true; do sleep 0.05; done
SCRIPT
  chmod +x "$desktop"
  cat > "$bundled" <<SCRIPT
#!/usr/bin/env bash
set -euo pipefail
printf 'launch:%s\n' "\$*" >> "$LAUNCH_LOG"
if [[ "\${1:-}" == app ]]; then
  printf '%s' "\${2:-}" > "$workspace_log"
  "$desktop" "$pid_file" "$stopped" "$event_log" &
fi
SCRIPT
  chmod +x "$bundled"

  local saved_a="$WORK_DIR/chatgpt-saved-a.json"
  local live_a="$WORK_DIR/chatgpt-live-a.json"
  local saved_b="$WORK_DIR/chatgpt-saved-b.json"
  make_api_auth "$saved_a" "sk-test-chatgpt-a-1111111111111111" "saved-a"
  make_api_auth "$live_a" "sk-test-chatgpt-a-1111111111111111" "live-a"
  make_api_auth "$saved_b" "sk-test-chatgpt-b-2222222222222222" "saved-b"
  save_auth "ChatGPTA" "$saved_a"
  save_auth "ChatGPTB" "$saved_b"
  cp "$live_a" "$TEST_HOME/.codex/auth.json"
  (
    while ! cmp -s "$TEST_HOME/.codex/auth.json" "$saved_b"; do sleep 0.01; done
    printf 'auth\n' >> "$event_log"
  ) &
  local watcher_pid=$!
  "$desktop" "$pid_file" "$stopped" "$event_log" &
  for _ in {1..40}; do [[ -f "$pid_file" ]] && break; sleep 0.05; done
  [[ -f "$pid_file" ]] || fail "fake ChatGPT desktop did not start"

  CODEX_PROFILE_HOME="$TEST_HOME" \
    CODEX_PROFILE_TEST_AUTH_STORE_DIR="$AUTH_STORE" \
    CODEX_APP="$app" \
    CODEX_BUNDLED_CLI="$bundled" \
    CODEX_PROFILE_TEST_DESKTOP_PID_FILE="$pid_file" \
    CODEX_CLI="$FAKE_CODEX" \
    CODEX_PROFILE_QUIT_ATTEMPTS=20 \
    CODEX_PROFILE_QUIT_SLEEP=0.05 \
    FAKE_CODEX_LOGIN_HOME_LOG="$LOGIN_HOME_LOG" \
    "$HELPER" app ChatGPTB "$workspace" >/dev/null

  [[ -f "$stopped" ]] || fail "running ChatGPT desktop was not stopped before switch"
  assert_same_file "$TEST_HOME/.codex/auth.json" "$saved_b" "selected ChatGPT profile auth was not restored"
  wait_for_launch_log "launch:app" || fail "ChatGPT app was not relaunched"
  for _ in {1..40}; do [[ -f "$workspace_log" ]] && break; sleep 0.05; done
  [[ "$(<"$workspace_log")" == "$workspace" ]] || fail "ChatGPT app was relaunched without the workspace"
  kill "$watcher_pid" 2>/dev/null || true
  wait "$watcher_pid" 2>/dev/null || true
  [[ "$(tr -d '\n' < "$event_log")" == stopauth ]] || fail "auth changed before ChatGPT stopped"
  kill "$(<"$pid_file")" 2>/dev/null || true
}

test_switch_invalid_desktop_installation_preserves_state() {
  reset_home
  local app="$WORK_DIR/invalid-chatgpt.app"
  local bundled="$app/Contents/Resources/codex"
  mkdir -p "$(dirname "$bundled")"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$bundled"
  chmod +x "$bundled"
  local saved_a="$WORK_DIR/invalid-saved-a.json"
  local live_a="$WORK_DIR/invalid-live-a.json"
  local saved_b="$WORK_DIR/invalid-saved-b.json"
  local original_config="$WORK_DIR/invalid-config.json"
  make_api_auth "$saved_a" "sk-test-invalid-a-1111111111111111" "saved-a"
  make_api_auth "$live_a" "sk-test-invalid-a-1111111111111111" "live-a"
  make_api_auth "$saved_b" "sk-test-invalid-b-2222222222222222" "saved-b"
  save_auth "InvalidA" "$saved_a"
  save_auth "InvalidB" "$saved_b"
  cp "$live_a" "$TEST_HOME/.codex/auth.json"
  mkdir -p "$TEST_HOME/.codex-switcher"
  cat > "$TEST_HOME/.codex-switcher/config.json" <<'JSON'
{"activeProfile":"InvalidA","profiles":[{"id":"InvalidA"},{"id":"InvalidB"}]}
JSON
  cp "$TEST_HOME/.codex-switcher/config.json" "$original_config"

  if CODEX_PROFILE_HOME="$TEST_HOME" \
    CODEX_PROFILE_TEST_AUTH_STORE_DIR="$AUTH_STORE" \
    CODEX_APP="$app" \
    CODEX_CLI="$FAKE_CODEX" \
    "$HELPER" app InvalidB "$WORK_DIR" >/dev/null 2>"$WORK_DIR/invalid-installation.err"; then
    fail "switch succeeded with an invalid ChatGPT installation"
  fi
  assert_same_file "$TEST_HOME/.codex/auth.json" "$live_a" "invalid installation changed live auth"
  assert_same_file "$TEST_HOME/.codex-switcher/config.json" "$original_config" "invalid installation changed active profile"
}

test_switch_rolls_back_after_auth_write_failure() {
  reset_home
  local saved_target="$WORK_DIR/auth-failure-target.json"
  local original_config="$WORK_DIR/auth-failure-config.json"
  make_api_auth "$saved_target" "sk-test-auth-failure-target-1111111111" "target"
  save_auth "Target" "$saved_target"
  mkdir -p "$TEST_HOME/.codex-switcher"
  printf '{\n  "activeProfile" : "Original",\n  "authStorageVersion" : 3,\n  "profiles" : [\n    {"id" : "Original", "label" : "Original"},\n    {"id" : "Target", "label" : "Target"}\n  ]\n}\n' \
    > "$TEST_HOME/.codex-switcher/config.json"
  cp "$TEST_HOME/.codex-switcher/config.json" "$original_config"
  chmod 500 "$TEST_HOME/.codex"

  if run_helper app Target "$WORK_DIR" >/dev/null 2>"$WORK_DIR/auth-failure.err"; then
    chmod 700 "$TEST_HOME/.codex"
    fail "switch succeeded even though live auth could not be written"
  fi

  chmod 700 "$TEST_HOME/.codex"
  [[ ! -f "$TEST_HOME/.codex/auth.json" ]] || fail "auth write failure left a live auth file behind"
  assert_same_file "$TEST_HOME/.codex-switcher/config.json" "$original_config" \
    "auth write failure did not preserve original config"
}

test_switch_rolls_back_after_config_write_failure() {
  reset_home
  local saved_active="$WORK_DIR/config-failure-active.json"
  local saved_target="$WORK_DIR/config-failure-target.json"
  local original_config="$WORK_DIR/config-failure-config.json"
  make_api_auth "$saved_active" "sk-test-config-failure-active-1111111111" "active"
  make_api_auth "$saved_target" "sk-test-config-failure-target-2222222222" "target"
  save_auth "Active" "$saved_active"
  save_auth "Target" "$saved_target"
  cp "$saved_active" "$TEST_HOME/.codex/auth.json"
  mkdir -p "$TEST_HOME/.codex-switcher"
  printf '{\n  "activeProfile" : "Active",\n  "authStorageVersion" : 3,\n  "profiles" : [\n    {"id" : "Active", "label" : "Active"},\n    {"id" : "Target", "label" : "Target"}\n  ]\n}\n' \
    > "$TEST_HOME/.codex-switcher/config.json"
  cp "$TEST_HOME/.codex-switcher/config.json" "$original_config"
  chmod 500 "$TEST_HOME/.codex-switcher"

  if run_helper app Target "$WORK_DIR" >/dev/null 2>"$WORK_DIR/config-failure.err"; then
    chmod 700 "$TEST_HOME/.codex-switcher"
    fail "switch succeeded even though config could not be written"
  fi

  chmod 700 "$TEST_HOME/.codex-switcher"
  assert_same_file "$TEST_HOME/.codex/auth.json" "$saved_active" \
    "config write failure did not restore original live auth"
  assert_same_file "$TEST_HOME/.codex-switcher/config.json" "$original_config" \
    "config write failure did not preserve original config"
}

test_switch_does_not_roll_back_after_launch_failure() {
  reset_home
  local bad_app="$WORK_DIR/bad-codex-app"
  local saved_active="$WORK_DIR/launch-failure-active.json"
  local saved_target="$WORK_DIR/launch-failure-target.json"
  printf 'not a runnable Mach-O or script\n' > "$bad_app"
  chmod +x "$bad_app"
  make_api_auth "$saved_active" "sk-test-launch-failure-active-1111111111" "active"
  make_api_auth "$saved_target" "sk-test-launch-failure-target-2222222222" "target"
  save_auth "Active" "$saved_active"
  save_auth "Target" "$saved_target"
  cp "$saved_active" "$TEST_HOME/.codex/auth.json"
  mkdir -p "$TEST_HOME/.codex-switcher"
  printf '{\n  "activeProfile" : "Active",\n  "authStorageVersion" : 3,\n  "profiles" : [\n    {"id" : "Active", "label" : "Active"},\n    {"id" : "Target", "label" : "Target"}\n  ]\n}\n' \
    > "$TEST_HOME/.codex-switcher/config.json"

  if run_helper_with_app "$bad_app" app Target "$WORK_DIR" >/dev/null 2>"$WORK_DIR/launch-failure.err"; then
    fail "switch command succeeded even though Codex app launch failed"
  fi

  assert_same_file "$TEST_HOME/.codex/auth.json" "$saved_target" \
    "launch failure rolled back committed live auth"
  grep -Fq '"activeProfile" : "Target"' "$TEST_HOME/.codex-switcher/config.json" \
    || fail "launch failure rolled back committed active profile"
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

test_switch_refuses_unreadable_live_auth() {
  reset_home
  local saved_a="$WORK_DIR/unreadable-a.json"
  local saved_b="$WORK_DIR/unreadable-b.json"
  local exported_a="$WORK_DIR/exported-unreadable-a.json"
  make_api_auth "$saved_a" "sk-test-unreadable-a-1111111111" "saved-a"
  make_api_auth "$saved_b" "sk-test-unreadable-b-2222222222" "saved-b"
  save_auth "UnreadableA" "$saved_a"
  save_auth "UnreadableB" "$saved_b"
  cp "$saved_a" "$TEST_HOME/.codex/auth.json"
  chmod 000 "$TEST_HOME/.codex/auth.json"

  if run_helper app UnreadableB "$WORK_DIR" >/dev/null 2>"$WORK_DIR/unreadable.err"; then
    chmod 600 "$TEST_HOME/.codex/auth.json"
    fail "switch succeeded even though live auth could not be read"
  fi

  chmod 600 "$TEST_HOME/.codex/auth.json"
  assert_same_file "$TEST_HOME/.codex/auth.json" "$saved_a" "unreadable live auth was modified"
  export_auth "UnreadableA" "$exported_a"
  assert_same_file "$exported_a" "$saved_a" "saved auth changed after unreadable live auth"
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

test_switch_uses_active_profile_to_disambiguate_live_auth() {
  reset_home
  local duplicate_a="$WORK_DIR/preferred-duplicate-a.json"
  local live_duplicate="$WORK_DIR/preferred-live.json"
  local saved_b="$WORK_DIR/preferred-b.json"
  local exported_a="$WORK_DIR/exported-preferred-a.json"
  local exported_clone="$WORK_DIR/exported-preferred-clone.json"
  make_api_auth "$duplicate_a" "sk-test-preferred-a-1111111111" "duplicate-a"
  make_api_auth "$live_duplicate" "sk-test-preferred-a-1111111111" "live-duplicate"
  make_api_auth "$saved_b" "sk-test-preferred-b-2222222222" "saved-b"
  save_auth "PreferredA" "$duplicate_a"
  save_auth "PreferredClone" "$duplicate_a"
  save_auth "PreferredB" "$saved_b"
  cp "$live_duplicate" "$TEST_HOME/.codex/auth.json"
  mkdir -p "$TEST_HOME/.codex-switcher"
  printf '{\n  "activeProfile" : "PreferredClone",\n  "authStorageVersion" : 3,\n  "profiles" : [\n    {"id" : "PreferredA", "label" : "Preferred A"},\n    {"id" : "PreferredClone", "label" : "Preferred Clone"},\n    {"id" : "PreferredB", "label" : "Preferred B"}\n  ]\n}\n' \
    > "$TEST_HOME/.codex-switcher/config.json"

  run_helper app PreferredB "$WORK_DIR" >/dev/null

  assert_same_file "$TEST_HOME/.codex/auth.json" "$saved_b" "selected profile auth was not restored after disambiguated switch"
  grep -Fq '"authStorageVersion" : 3' "$TEST_HOME/.codex-switcher/config.json" \
    || fail "profile switch unexpectedly changed authStorageVersion"
  export_auth "PreferredA" "$exported_a"
  export_auth "PreferredClone" "$exported_clone"
  assert_same_file "$exported_a" "$duplicate_a" "non-active duplicate was overwritten during disambiguated switch"
  assert_same_file "$exported_clone" "$live_duplicate" "active duplicate was not used as outgoing profile"
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

test_login_rejects_duplicate_auth_and_preserves_target_auth() {
  reset_home
  local existing="$WORK_DIR/login-duplicate-existing.json"
  local target_original="$WORK_DIR/login-duplicate-target-original.json"
  local exported_target="$WORK_DIR/exported-login-duplicate-target.json"
  make_api_auth "$existing" "sk-test-login-duplicate-existing-1111111111" "existing"
  make_api_auth "$target_original" "sk-test-login-duplicate-target-2222222222" "target-original"
  save_auth "Existing" "$existing"
  save_auth "Target" "$target_original"
  mkdir -p "$TEST_HOME/.codex-switcher"
  printf '{\n  "activeProfile" : "Target",\n  "authStorageVersion" : 3,\n  "profiles" : [\n    {"id" : "Existing", "label" : "Existing Account"},\n    {"id" : "Target", "label" : "Target"}\n  ]\n}\n' \
    > "$TEST_HOME/.codex-switcher/config.json"

  if FAKE_CODEX_LOGIN_AUTH="$existing" run_helper login Target >/dev/null 2>"$WORK_DIR/login-duplicate.err"; then
    fail "duplicate login unexpectedly succeeded"
  fi

  export_auth "Target" "$exported_target"
  assert_same_file "$exported_target" "$target_original" \
    "duplicate login overwrote the target profile auth"
}

test_file_vault_login_preserves_incomplete_legacy_disk_migration() {
  reset_home
  local legacy_auth="$WORK_DIR/legacy-disk-auth.json"
  local login="$WORK_DIR/file-vault-login.json"
  local legacy_store="$TEST_HOME/.codex-switcher/auth/Legacy.json"
  make_api_auth "$legacy_auth" "sk-test-legacy-disk-1111111111" "legacy-disk"
  make_api_auth "$login" "sk-test-file-vault-login-2222222222" "file-vault-login"
  mkdir -p "$(dirname "$legacy_store")"
  cp "$legacy_auth" "$legacy_store"

  FAKE_CODEX_LOGIN_AUTH="$login" run_helper_dev login FileVaultLogin >/dev/null

  [[ -f "$legacy_store" ]] || fail "file-vault login removed the legacy disk auth source"
  assert_same_file "$legacy_store" "$legacy_auth" \
    "file-vault login changed the legacy disk auth source"
  [[ -f "$TEST_HOME/.codex-switcher/config.json" ]] \
    || fail "file-vault login did not create its profile config"
  if grep -Fq '"authStorageVersion"' "$TEST_HOME/.codex-switcher/config.json"; then
    fail "file-vault login incorrectly marked legacy disk auth migration complete"
  fi
}

test_keychain_repair_reports_no_migration_yet() {
  reset_home
  local saved_a="$WORK_DIR/repair-a.json"
  local saved_b="$WORK_DIR/repair-b.json"
  local original_config="$WORK_DIR/repair-config.json"
  local original_auth_store="$WORK_DIR/repair-auth-store"
  local exported_a="$WORK_DIR/exported-repair-a.json"
  local exported_b="$WORK_DIR/exported-repair-b.json"
  make_api_auth "$saved_a" "sk-test-repair-a-1111111111" "repair-a"
  make_api_auth "$saved_b" "sk-test-repair-b-2222222222" "repair-b"
  save_auth "RepairA" "$saved_a"
  save_auth "RepairB" "$saved_b"
  mkdir -p "$TEST_HOME/.codex-switcher"
  printf '{\n  "activeProfile" : "RepairA",\n  "authStorageVersion" : 2,\n  "profiles" : [\n    {"id" : "RepairA", "label" : "Repair A"},\n    {"id" : "RepairB", "label" : "Repair B"}\n  ]\n}\n' \
    > "$TEST_HOME/.codex-switcher/config.json"
  cp "$TEST_HOME/.codex-switcher/config.json" "$original_config"
  cp -R "$AUTH_STORE" "$original_auth_store"

  if run_helper keychain-repair >/dev/null 2>"$WORK_DIR/keychain-repair.err"; then
    fail "keychain-repair unexpectedly performed a migration"
  fi

  grep -Fq "Open Settings > General and choose" "$WORK_DIR/keychain-repair.err" \
    || fail "keychain-repair did not direct users to Settings"
  assert_same_file "$TEST_HOME/.codex-switcher/config.json" "$original_config" \
    "keychain-repair changed migration bookkeeping"
  diff -qr "$AUTH_STORE" "$original_auth_store" >/dev/null \
    || fail "keychain-repair changed file-vault data"
  export_auth "RepairA" "$exported_a"
  export_auth "RepairB" "$exported_b"
  assert_same_file "$exported_a" "$saved_a" "keychain-repair modified RepairA auth"
  assert_same_file "$exported_b" "$saved_b" "keychain-repair modified RepairB auth"
}

test_best_auth_exports_lowest_usage_configured_profile() {
  reset_home
  local saved_a="$WORK_DIR/best-a.json"
  local saved_b="$WORK_DIR/best-b.json"
  local out_dir="$WORK_DIR/best-out"
  make_api_auth "$saved_a" "sk-test-best-a-1111111111" "best-a"
  make_api_auth "$saved_b" "sk-test-best-b-2222222222" "best-b"
  save_auth "BestA" "$saved_a"
  save_auth "BestB" "$saved_b"
  save_auth "Unconfigured" "$saved_b"
  printf 'model = "gpt-test"\n' > "$TEST_HOME/.codex/config.toml"
  mkdir -p "$TEST_HOME/.codex-switcher"
  cat > "$TEST_HOME/.codex-switcher/config.json" <<'JSON'
{
  "activeProfile" : "BestA",
  "profiles" : [
    {"id" : "BestA", "label" : "Best A"},
    {"id" : "BestB", "label" : "Best B"}
  ]
}
JSON
  cat > "$TEST_HOME/.codex-switcher/cache.json" <<'JSON'
{
  "snapshots" : {
    "BestA" : {
      "planType" : "team",
      "creditsRemaining" : null,
      "primaryUsedPercent" : 90,
      "primaryResetAt" : "2030-01-01T00:00:00Z",
      "secondaryUsedPercent" : 90,
      "secondaryResetAt" : "2030-01-01T00:00:00Z",
      "fetchedAt" : "2026-05-30T12:00:00Z"
    },
    "BestB" : {
      "planType" : "team",
      "creditsRemaining" : null,
      "primaryUsedPercent" : 10,
      "primaryResetAt" : "2030-01-01T00:00:00Z",
      "secondaryUsedPercent" : 10,
      "secondaryResetAt" : "2030-01-01T00:00:00Z",
      "fetchedAt" : "2026-05-30T12:00:00Z"
    },
    "Unconfigured" : {
      "planType" : "team",
      "creditsRemaining" : null,
      "primaryUsedPercent" : 0,
      "primaryResetAt" : "2030-01-01T00:00:00Z",
      "secondaryUsedPercent" : 0,
      "secondaryResetAt" : "2030-01-01T00:00:00Z",
      "fetchedAt" : "2026-05-30T12:00:00Z"
    }
  }
}
JSON
  mkdir -p "$out_dir"
  chmod 777 "$out_dir"

  local selected
  selected="$(run_helper best-auth --dir "$out_dir")"

  [[ "$selected" == "BestB" ]] || fail "best-auth selected $selected instead of BestB"
  assert_same_file "$out_dir/auth.json" "$saved_b" "best-auth exported wrong auth"
  grep -Fq 'model = "gpt-test"' "$out_dir/config.toml" \
    || fail "best-auth did not copy Codex config.toml"
  [[ "$(stat -f '%Lp' "$out_dir")" == "700" ]] \
    || fail "best-auth did not make existing output dir private"
  [[ "$(stat -f '%Lp' "$out_dir/auth.json")" == "600" ]] \
    || fail "best-auth did not write auth.json with 0600 permissions"

  rm -f "$TEST_HOME/.codex/config.toml"
  printf 'stale config\n' > "$out_dir/config.toml"
  selected="$(run_helper best-auth --dir "$out_dir")"
  [[ "$selected" == "BestB" ]] || fail "best-auth selected $selected on reused dir"
  [[ ! -f "$out_dir/config.toml" ]] \
    || fail "best-auth left stale config.toml in reused output dir"
}

test_mark_exhausted_persists_to_cache_and_best_auth_skips_it() {
  reset_home
  local saved_a="$WORK_DIR/exhaust-a.json"
  local saved_b="$WORK_DIR/exhaust-b.json"
  make_api_auth "$saved_a" "sk-test-exhaust-a-1111111111" "exhaust-a"
  make_api_auth "$saved_b" "sk-test-exhaust-b-2222222222" "exhaust-b"
  save_auth "ExhaustA" "$saved_a"
  save_auth "ExhaustB" "$saved_b"
  mkdir -p "$TEST_HOME/.codex-switcher"
  cat > "$TEST_HOME/.codex-switcher/config.json" <<'JSON'
{
  "activeProfile" : "ExhaustA",
  "profiles" : [
    {"id" : "ExhaustA", "label" : "Exhaust A"},
    {"id" : "ExhaustB", "label" : "Exhaust B"}
  ]
}
JSON
  cat > "$TEST_HOME/.codex-switcher/cache.json" <<'JSON'
{
  "snapshots" : {
    "ExhaustA" : {
      "planType" : "team",
      "creditsRemaining" : null,
      "primaryUsedPercent" : 1,
      "primaryResetAt" : "2030-01-01T00:00:00Z",
      "secondaryUsedPercent" : 1,
      "secondaryResetAt" : "2030-01-01T00:00:00Z",
      "fetchedAt" : "2026-05-30T12:00:00Z"
    },
    "ExhaustB" : {
      "planType" : "team",
      "creditsRemaining" : null,
      "primaryUsedPercent" : 50,
      "primaryResetAt" : "2030-01-01T00:00:00Z",
      "secondaryUsedPercent" : 50,
      "secondaryResetAt" : "2030-01-01T00:00:00Z",
      "fetchedAt" : "2026-05-30T12:00:00Z"
    }
  }
}
JSON

  run_helper mark-exhausted ExhaustA --until 2030-01-01T00:00:00Z >/dev/null
  grep -Fq '"exhaustionOverrides"' "$TEST_HOME/.codex-switcher/cache.json" \
    || fail "mark-exhausted did not persist overrides to cache.json"
  grep -Fq '"ExhaustA"' "$TEST_HOME/.codex-switcher/cache.json" \
    || fail "mark-exhausted did not persist ExhaustA override"

  local selected
  selected="$(run_helper best-auth --dir "$WORK_DIR/exhaust-out")"
  [[ "$selected" == "ExhaustB" ]] || fail "best-auth did not skip exhausted profile"
}

test_unentitled_build_uses_file_vault() {
  # This check is inspection only: never run an entitlement-bearing helper here
  # because the test must not access the macOS Keychain.
  if codesign -d --entitlements :- "$HELPER" 2>/dev/null | grep -q "keychain-access-groups"; then
    printf 'skip: helper has Keychain entitlement; file-vault gate not exercised\n'
    return 0
  fi
  reset_home
  local login="$WORK_DIR/dev-vault-login.json"
  make_api_auth "$login" "sk-test-dev-vault-1111111111" "dev-vault"

  FAKE_CODEX_LOGIN_AUTH="$login" run_helper_dev login DevVault \
    >/dev/null 2>"$WORK_DIR/dev-vault.err" || fail "login via dev vault failed"

  grep -q "no data-protection Keychain entitlement" "$WORK_DIR/dev-vault.err" \
    || fail "dev-vault notice was not printed"
  [[ -f "$TEST_HOME/.codex-switcher/dev-auth-store/DevVault.json" ]] \
    || fail "auth was not saved to the file dev vault"
  cmp -s "$TEST_HOME/.codex-switcher/dev-auth-store/DevVault.json" "$login" \
    || fail "dev vault saved wrong auth content"
}

test_force_keychain_cannot_bypass_entitlement() {
  # This is inspection only: never run an entitlement-bearing helper here
  # because the test must not access the macOS Keychain.
  if codesign -d --entitlements :- "$HELPER" 2>/dev/null | grep -q "keychain-access-groups"; then
    printf 'skip: helper has Keychain entitlement; force override gate not exercised\n'
    return 0
  fi
  reset_home
  local login="$WORK_DIR/force-keychain-login.json"
  make_api_auth "$login" "sk-test-force-keychain-1111111111" "force-keychain"

  CODEX_PROFILE_HOME="$TEST_HOME" \
    CODEX_PROFILE_FORCE_KEYCHAIN=1 \
    CODEX_PROFILE_TEST_ASSUME_CODEX_STOPPED=1 \
    CODEX_BUNDLED_CLI="$FAKE_APP" \
    CODEX_CLI="$FAKE_CODEX" \
    FAKE_CODEX_LOGIN_HOME_LOG="$LOGIN_HOME_LOG" \
    FAKE_CODEX_LOGIN_AUTH="$login" \
    "$HELPER" login ForceKeychain >/dev/null 2>"$WORK_DIR/force-keychain.err" \
    || fail "force-keychain override bypassed the file vault"

  [[ -f "$TEST_HOME/.codex-switcher/dev-auth-store/ForceKeychain.json" ]] \
    || fail "force-keychain override did not use the file vault"
  cmp -s "$TEST_HOME/.codex-switcher/dev-auth-store/ForceKeychain.json" "$login" \
    || fail "force-keychain override saved wrong auth content"
}

test_file_auth_store_dir_override_pins_backend() {
  # The menu app pins a delegated helper to its OWN auth backend via
  # CODEX_PROFILE_FILE_AUTH_STORE_DIR so an app/helper signing mismatch can't
  # split auth across two stores. The override must route auth to that explicit
  # dir regardless of the helper's own signing identity, overriding the default
  # dev-auth-store. (Works on signed and unsigned helpers, so no skip.)
  reset_home
  local login="$WORK_DIR/file-override-login.json"
  local override_dir="$WORK_DIR/app-pinned-store"
  make_api_auth "$login" "sk-test-file-override-1111111111" "file-override"

  CODEX_PROFILE_HOME="$TEST_HOME" \
    CODEX_PROFILE_FILE_AUTH_STORE_DIR="$override_dir" \
    CODEX_PROFILE_TEST_ASSUME_CODEX_STOPPED=1 \
    CODEX_BUNDLED_CLI="$FAKE_APP" \
    CODEX_CLI="$FAKE_CODEX" \
    FAKE_CODEX_LOGIN_HOME_LOG="$LOGIN_HOME_LOG" \
    FAKE_CODEX_LOGIN_AUTH="$login" \
    "$HELPER" login FileOverride >/dev/null 2>"$WORK_DIR/file-override.err" \
    || fail "login with file-store override failed"

  [[ -f "$override_dir/FileOverride.json" ]] \
    || fail "auth was not saved to the app-pinned file store"
  cmp -s "$override_dir/FileOverride.json" "$login" \
    || fail "app-pinned file store saved wrong auth content"
  [[ ! -f "$TEST_HOME/.codex-switcher/dev-auth-store/FileOverride.json" ]] \
    || fail "auth leaked into the default dev-auth-store instead of the pinned dir"
}

test_import_auth_preserves_on_missing_identity() {
  reset_home
  local existing="$WORK_DIR/token-only-existing.json"
  local updated="$WORK_DIR/token-only-updated.json"
  local exported="$WORK_DIR/token-only-exported.json"
  local import_dir="$WORK_DIR/token-only-import"
  make_token_only_auth "$existing" "access-old" "refresh-old"
  make_token_only_auth "$updated" "access-new" "refresh-new"
  save_auth "TokenOnly" "$existing"
  mkdir -p "$import_dir"
  cp "$updated" "$import_dir/auth.json"

  if run_helper import-auth --dir "$import_dir" --profile TokenOnly >/dev/null 2>"$WORK_DIR/import-token-only.err"; then
    fail "import-auth accepted updated auth with unverifiable identity"
  fi

  export_auth "TokenOnly" "$exported"
  assert_same_file "$exported" "$existing" "import-auth overwrote auth with unverifiable identity"
}

write_exec_test_state() {
  # Two oauth profiles; RotateA has the most remaining quota so exec picks it
  # first. Live usage fetches fail fast (fake codex), falling back to cache.
  reset_home
  local saved_a="$WORK_DIR/rotate-a.json"
  local saved_b="$WORK_DIR/rotate-b.json"
  make_oauth_auth "$saved_a" "access-rotate-a" "refresh-a" "acct-rotate-a"
  make_oauth_auth "$saved_b" "access-rotate-b" "refresh-b" "acct-rotate-b"
  save_auth "RotateA" "$saved_a"
  save_auth "RotateB" "$saved_b"
  mkdir -p "$TEST_HOME/.codex-switcher"
  cat > "$TEST_HOME/.codex-switcher/config.json" <<'JSON'
{
  "activeProfile" : "RotateA",
  "profiles" : [
    {"id" : "RotateA", "label" : "Rotate A"},
    {"id" : "RotateB", "label" : "Rotate B"}
  ]
}
JSON
  cat > "$TEST_HOME/.codex-switcher/cache.json" <<'JSON'
{
  "snapshots" : {
    "RotateA" : {
      "planType" : "team",
      "creditsRemaining" : null,
      "primaryUsedPercent" : 10,
      "primaryResetAt" : "2030-01-01T00:00:00Z",
      "secondaryUsedPercent" : 10,
      "secondaryResetAt" : "2030-01-01T00:00:00Z",
      "fetchedAt" : "2026-05-30T12:00:00Z"
    },
    "RotateB" : {
      "planType" : "team",
      "creditsRemaining" : null,
      "primaryUsedPercent" : 50,
      "primaryResetAt" : "2030-01-01T00:00:00Z",
      "secondaryUsedPercent" : 50,
      "secondaryResetAt" : "2030-01-01T00:00:00Z",
      "fetchedAt" : "2026-05-30T12:00:00Z"
    }
  }
}
JSON
}

has_exhaustion_override() {
  plutil -extract "exhaustionOverrides.$1" json \
    -o /dev/null "$TEST_HOME/.codex-switcher/cache.json" >/dev/null 2>&1
}

# True when cache.json has a lease reservation recorded for <profile>.
has_lease() {
  plutil -extract "leases.$1" json \
    -o /dev/null "$TEST_HOME/.codex-switcher/cache.json" >/dev/null 2>&1
}

# Prints a reservation field (token, home, expiresAt, createdAt) for <profile>.
# Only ever used inside [[ ]]; a missing lease/field yields empty + nonzero.
lease_field() {
  plutil -extract "leases.$1.$2" raw \
    -o - "$TEST_HOME/.codex-switcher/cache.json" 2>/dev/null
}

test_exec_rotates_on_usage_limit() {
  write_exec_test_state
  local attempt_log="$WORK_DIR/exec-attempts.log"
  local target="$WORK_DIR/fake-exec-target"
  local exported_b="$WORK_DIR/exported-rotate-b.json"
  : > "$attempt_log"
  cat > "$target" <<EOF
#!/usr/bin/env bash
set -euo pipefail
if grep -q "access-rotate-a" "\$CODEX_HOME/auth.json"; then
  echo "A" >> "$attempt_log"
  echo "ERROR: 429 Too Many Requests - usage limit reached" >&2
  exit 1
fi
echo "B" >> "$attempt_log"
printf '{\n  "tokens" : {\n    "access_token" : "access-rotate-b-refreshed",\n    "refresh_token" : "refresh-b-2",\n    "account_id" : "acct-rotate-b"\n  }\n}\n' > "\$CODEX_HOME/auth.json"
cat
echo "rotate-ok"
EOF
  chmod +x "$target"

  local out
  out="$(printf 'stdin-marker\n' | run_helper exec --timeout 10 -- "$target" 2>"$WORK_DIR/exec-rotate.err")" \
    || fail "exec did not succeed after rotation ($(cat "$WORK_DIR/exec-rotate.err"))"

  grep -q "stdin-marker" <<<"$out" || fail "exec did not pass stdin through to the child"
  grep -q "rotate-ok" <<<"$out" || fail "exec did not pass child stdout through"
  [[ "$(cat "$attempt_log")" == "A
B" ]] || fail "exec attempts were not RotateA then RotateB (got: $(tr '\n' ' ' < "$attempt_log"))"
  has_exhaustion_override RotateA || fail "exec did not mark RotateA exhausted"
  has_exhaustion_override RotateB && fail "exec wrongly marked RotateB exhausted"
  export_auth "RotateB" "$exported_b"
  grep -q "access-rotate-b-refreshed" "$exported_b" \
    || fail "exec did not import the refreshed RotateB auth back"
  [[ -z "$(ls -A "$TEST_HOME/.codex-switcher/tmp" 2>/dev/null)" ]] \
    || fail "exec left temp homes behind"
  [[ ! -f "$TEST_HOME/.codex/auth.json" ]] \
    || fail "exec touched the live ~/.codex/auth.json"
}

test_exec_does_not_rotate_on_ordinary_failure() {
  write_exec_test_state
  local attempt_log="$WORK_DIR/exec-plain-fail.log"
  local target="$WORK_DIR/fake-exec-plain-fail"
  : > "$attempt_log"
  cat > "$target" <<EOF
#!/usr/bin/env bash
echo "ran" >> "$attempt_log"
echo "boom: ordinary failure" >&2
exit 3
EOF
  chmod +x "$target"

  local status=0
  run_helper exec --timeout 10 -- "$target" >/dev/null 2>"$WORK_DIR/exec-plain-fail.err" || status=$?
  [[ "$status" -eq 3 ]] || fail "exec did not pass through child exit code 3 (got $status)"
  [[ "$(wc -l < "$attempt_log" | tr -d ' ')" == "1" ]] \
    || fail "exec retried an ordinary (non-usage-limit) failure"
  has_exhaustion_override RotateA && fail "exec marked RotateA exhausted on an ordinary failure"
  has_exhaustion_override RotateB && fail "exec marked RotateB exhausted on an ordinary failure"
  grep -q "boom: ordinary failure" "$WORK_DIR/exec-plain-fail.err" \
    || fail "exec did not pass child stderr through"
}

test_exec_cleans_temp_home_when_command_missing() {
  write_exec_test_state

  if run_helper exec --timeout 10 -- /nonexistent/exec-target >/dev/null 2>&1; then
    fail "exec succeeded with a nonexistent command"
  fi
  [[ -z "$(ls -A "$TEST_HOME/.codex-switcher/tmp" 2>/dev/null)" ]] \
    || fail "exec leaked a temp home (with credentials) after a bad-command failure"
}

test_exec_gives_up_when_all_profiles_limited() {
  write_exec_test_state
  local attempt_log="$WORK_DIR/exec-all-limited.log"
  local target="$WORK_DIR/fake-exec-all-limited"
  : > "$attempt_log"
  cat > "$target" <<EOF
#!/usr/bin/env bash
echo "ran" >> "$attempt_log"
echo "You've hit your usage limit." >&2
exit 1
EOF
  chmod +x "$target"

  if run_helper exec --max-attempts 2 --timeout 10 -- "$target" >/dev/null 2>"$WORK_DIR/exec-all-limited.err"; then
    fail "exec succeeded even though every profile was usage-limited"
  fi
  [[ "$(wc -l < "$attempt_log" | tr -d ' ')" == "2" ]] \
    || fail "exec did not run exactly --max-attempts times (got $(wc -l < "$attempt_log"))"
  has_exhaustion_override RotateA || fail "exec did not mark RotateA exhausted"
  has_exhaustion_override RotateB || fail "exec did not mark RotateB exhausted"
  grep -q "usage limit hit on 2 profile(s)" "$WORK_DIR/exec-all-limited.err" \
    || fail "exec did not explain that all attempts were usage-limited"
}

test_import_auth_accepts_same_identity_refresh() {
  reset_home
  local existing="$WORK_DIR/oauth-existing.json"
  local updated="$WORK_DIR/oauth-updated.json"
  local exported="$WORK_DIR/oauth-exported.json"
  local import_dir="$WORK_DIR/oauth-import"
  make_oauth_auth "$existing" "access-old" "refresh-old" "acct-1"
  make_oauth_auth "$updated" "access-new" "refresh-new" "acct-1"
  save_auth "OAuth" "$existing"
  mkdir -p "$import_dir"
  cp "$updated" "$import_dir/auth.json"

  run_helper import-auth --dir "$import_dir" --profile OAuth >/dev/null

  export_auth "OAuth" "$exported"
  assert_same_file "$exported" "$updated" "import-auth did not save refreshed same-identity auth"
}

test_lease_begin_reserves_and_seeds() {
  write_exec_test_state
  # performBestAuth copies the live ~/.codex/config.toml into the lease home,
  # so seed one with a marker before begin.
  printf 'model = "gpt-lease"\n' > "$TEST_HOME/.codex/config.toml"

  local report="$WORK_DIR/lease-begin.json"
  run_helper lease begin --json --non-interactive > "$report"

  local profile home token
  profile="$(plutil -extract profile raw -o - "$report")"
  home="$(plutil -extract home raw -o - "$report")"
  token="$(plutil -extract token raw -o - "$report")"

  [[ "$profile" == "RotateA" ]] \
    || fail "lease begin selected $profile instead of RotateA (best quota)"
  # The home lives at <switcher-home>/.codex-switcher/leases/<token>. Match the
  # structural tail rather than the full path: the switcher home is derived from
  # CODEX_PROFILE_HOME and path-normalized by the binary, so a verbatim
  # comparison against $TEST_HOME is brittle.
  case "$home" in
    */.codex-switcher/leases/"$token") ;;
    *) fail "lease home ($home) is not <switcher-home>/.codex-switcher/leases/$token" ;;
  esac
  [[ -d "$home" ]] || fail "lease home dir was not created"
  [[ "$(stat -f '%Lp' "$home")" == "700" ]] \
    || fail "lease home is not private (0700)"
  [[ -f "$home/auth.json" ]] || fail "lease home is missing auth.json"
  [[ "$(stat -f '%Lp' "$home/auth.json")" == "600" ]] \
    || fail "lease home auth.json is not 0600"
  [[ -f "$home/config.toml" ]] || fail "lease home is missing config.toml"
  grep -Fq 'model = "gpt-lease"' "$home/config.toml" \
    || fail "lease home config.toml is not the live config copy"
  [[ "$(lease_field RotateA token)" == "$token" ]] \
    || fail "cache.json leases.RotateA.token does not match the printed token"
  has_lease RotateA || fail "cache.json has no lease reservation for RotateA"
}

test_lease_begin_excludes_active_lease() {
  write_exec_test_state

  local first="$WORK_DIR/lease-begin-1.json"
  run_helper lease begin --json --non-interactive > "$first"
  local first_profile first_home
  first_profile="$(plutil -extract profile raw -o - "$first")"
  first_home="$(plutil -extract home raw -o - "$first")"
  [[ "$first_profile" == "RotateA" ]] \
    || fail "first lease begin selected $first_profile instead of RotateA"

  # RotateA is now held by an active lease; the second begin must skip it.
  local second="$WORK_DIR/lease-begin-2.json"
  run_helper lease begin --json --non-interactive > "$second"
  local second_profile second_home
  second_profile="$(plutil -extract profile raw -o - "$second")"
  second_home="$(plutil -extract home raw -o - "$second")"
  [[ "$second_profile" == "RotateB" ]] \
    || fail "second lease begin selected $second_profile instead of RotateB (RotateA should be held)"
  [[ "$second_home" != "$first_home" ]] \
    || fail "second lease begin reused the first lease's home"

  has_lease RotateA || fail "first lease reservation was lost"
  has_lease RotateB || fail "second lease reservation was not recorded"
}

test_lease_gc_reclaims_expired() {
  write_exec_test_state
  local leases_root="$TEST_HOME/.codex-switcher/leases"
  local token="gc-expired-token"
  local home="$leases_root/$token"
  mkdir -p "$home"
  printf 'dead\n' > "$home/auth.json"

  # Inject a reservation that has already expired so gc reclaims it. The
  # expired-reclaim path is keyed on the reservation, not the orphan window.
  plutil -insert "leases" -json \
    "{\"GcProfile\":{\"token\":\"$token\",\"home\":\"$home\",\"expiresAt\":\"2000-01-01T00:00:00Z\",\"createdAt\":\"2026-06-24T00:00:00Z\"}}" \
    "$TEST_HOME/.codex-switcher/cache.json"

  run_helper lease gc >/dev/null

  has_lease GcProfile && fail "lease gc did not drop the expired reservation"
  [[ ! -d "$home" ]] || fail "lease gc did not remove the expired reservation's home"
}

test_lease_gc_preserves_active_lease() {
  write_exec_test_state
  local report="$WORK_DIR/lease-begin.json"
  run_helper lease begin --json --non-interactive > "$report"
  local home token
  home="$(plutil -extract home raw -o - "$report")"
  token="$(plutil -extract token raw -o - "$report")"
  [[ "$(plutil -extract profile raw -o - "$report")" == "RotateA" ]] \
    || fail "setup lease begin did not pick RotateA"

  run_helper lease gc >/dev/null

  [[ -d "$home" ]] || fail "lease gc removed an active lease's home"
  has_lease RotateA || fail "lease gc dropped an active reservation"
  [[ "$(lease_field RotateA token)" == "$token" ]] \
    || fail "lease gc altered the active reservation"
}

test_lease_gc_sweeps_old_orphan_but_keeps_fresh() {
  write_exec_test_state
  local leases_root="$TEST_HOME/.codex-switcher/leases"
  mkdir -p "$leases_root/old-token" "$leases_root/fresh-token"
  printf 'stale\n' > "$leases_root/old-token/auth.json"
  printf 'fresh\n' > "$leases_root/fresh-token/auth.json"
  # Backdate old-token (and its contents) well past the 300s orphan grace
  # window; leave fresh-token at its current mtime. The dir touch must come
  # last so the file write above does not bump it back to now.
  touch -t 200001010000 "$leases_root/old-token/auth.json"
  touch -t 200001010000 "$leases_root/old-token"
  touch "$leases_root/fresh-token"

  run_helper lease gc >/dev/null

  [[ ! -d "$leases_root/old-token" ]] \
    || fail "lease gc did not sweep an old orphan home"
  [[ -d "$leases_root/fresh-token" ]] \
    || fail "lease gc swept a fresh orphan home inside the 300s grace window"
}

test_lease_swap_rotates_credential_in_place() {
  write_exec_test_state
  local begin_report="$WORK_DIR/lease-begin.json"
  run_helper lease begin --json --non-interactive > "$begin_report"
  local home token
  home="$(plutil -extract home raw -o - "$begin_report")"
  token="$(plutil -extract token raw -o - "$begin_report")"
  [[ "$(plutil -extract profile raw -o - "$begin_report")" == "RotateA" ]] \
    || fail "setup lease begin did not pick RotateA"

  # A warm codex session keeps state under sessions/; swap must never touch it.
  mkdir -p "$home/sessions"
  printf 'keep-me\n' > "$home/sessions/keep.txt"

  local swap_report="$WORK_DIR/lease-swap.json"
  run_helper lease swap "$token" --json --non-interactive > "$swap_report"

  [[ "$(plutil -extract profile raw -o - "$swap_report")" == "RotateB" ]] \
    || fail "lease swap did not rotate to RotateB"
  [[ "$(plutil -extract home raw -o - "$swap_report")" == "$home" ]] \
    || fail "lease swap moved the home instead of rotating in place"
  [[ -d "$home" ]] || fail "lease swap removed the warm home"
  [[ -f "$home/sessions/keep.txt" ]] \
    || fail "lease swap touched sessions/ during rotation"

  # The credential in the unchanged home now belongs to RotateB.
  local rotate_b="$WORK_DIR/lease-rotate-b.json"
  export_auth "RotateB" "$rotate_b"
  assert_same_file "$home/auth.json" "$rotate_b" \
    "lease swap did not swap RotateB's credential into the warm home"

  has_exhaustion_override RotateA \
    || fail "lease swap did not mark the rotated-away profile exhausted"
  has_lease RotateA && fail "lease swap left the reservation on RotateA"
  [[ "$(lease_field RotateB token)" == "$token" ]] \
    || fail "lease swap did not rebind the reservation to RotateB under the same token"
}

test_lease_end_writes_back_and_releases() {
  write_exec_test_state
  local begin_report="$WORK_DIR/lease-begin.json"
  run_helper lease begin --json --non-interactive > "$begin_report"
  local home token
  home="$(plutil -extract home raw -o - "$begin_report")"
  token="$(plutil -extract token raw -o - "$begin_report")"

  # Simulate codex refreshing the token in place: SAME identity (account id),
  # fresh access/refresh tokens.
  local refreshed="$WORK_DIR/lease-refreshed.json"
  make_oauth_auth "$refreshed" "access-rotate-a-refreshed" "refresh-a-2" "acct-rotate-a"
  cp "$refreshed" "$home/auth.json"

  run_helper lease end "$token" --non-interactive >/dev/null

  local exported="$WORK_DIR/lease-end-exported.json"
  export_auth "RotateA" "$exported"
  assert_same_file "$exported" "$refreshed" \
    "lease end did not write the refreshed credential back to RotateA's vault"

  has_lease RotateA && fail "lease end did not release the reservation"
  [[ ! -d "$home" ]] || fail "lease end did not remove the leased home"
}

test_lease_end_is_idempotent() {
  write_exec_test_state

  # No active lease: a clean no-op that must succeed (exit 0).
  run_helper lease end deadbeef-no-such-token --non-interactive >/dev/null

  local begin_report="$WORK_DIR/lease-begin.json"
  run_helper lease begin --json --non-interactive > "$begin_report"
  local token
  token="$(plutil -extract token raw -o - "$begin_report")"

  # First end tears the lease down (succeeds); the second has nothing to do
  # and must still succeed (idempotent, exit 0).
  run_helper lease end "$token" --non-interactive >/dev/null
  run_helper lease end "$token" --non-interactive >/dev/null
}

test_lease_end_preserves_home_on_writeback_failure() {
  write_exec_test_state
  local begin_report="$WORK_DIR/lease-begin.json"
  run_helper lease begin --json --non-interactive > "$begin_report"
  local home token
  home="$(plutil -extract home raw -o - "$begin_report")"
  token="$(plutil -extract token raw -o - "$begin_report")"

  # Snapshot RotateA's stored credential, then put a DIFFERENT-identity blob in
  # the home so writeback fails the identity-fingerprint check (exit 5 inside).
  local before="$WORK_DIR/rotate-a-before.json"
  export_auth "RotateA" "$before"
  local wrong="$WORK_DIR/wrong-identity.json"
  make_oauth_auth "$wrong" "access-x" "refresh-x" "acct-DIFFERENT"
  cp "$wrong" "$home/auth.json"

  # end must NOT lose the credential: it preserves the home + reservation and
  # leaves the stored vault auth untouched (it did not write the wrong identity).
  run_helper lease end "$token" --non-interactive >/dev/null 2>&1 || true
  [[ -d "$home" ]] || fail "lease end deleted the home after a writeback failure (credential lost)"
  has_lease RotateA || fail "lease end released the reservation after a writeback failure"
  local after="$WORK_DIR/rotate-a-after.json"
  export_auth "RotateA" "$after"
  assert_same_file "$after" "$before" "lease end wrote a mismatched-identity credential to the vault"
}

test_lease_gc_preserves_expired_lease_with_recoverable_writeback() {
  write_exec_test_state
  local leases_root="$TEST_HOME/.codex-switcher/leases"
  local token="gc-preserve-token"
  local home="$leases_root/$token"
  mkdir -p "$home"

  # The home holds a DIFFERENT-identity credential for RotateA, so write-back
  # fails the identity check (exit 5 = recoverable: a real credential is at
  # risk). gc must PRESERVE the home + reservation rather than destroy it, even
  # though the reservation is expired AND the home is backdated past the 300s
  # orphan grace window. This is the F1 regression: the orphan sweep must
  # protect every RECORDED token, not just active ones, so a preserved
  # failed-writeback home is never swept.
  make_oauth_auth "$home/auth.json" "access-x" "refresh-x" "acct-DIFFERENT"
  plutil -insert "leases" -json \
    "{\"RotateA\":{\"token\":\"$token\",\"home\":\"$home\",\"expiresAt\":\"2000-01-01T00:00:00Z\",\"createdAt\":\"2026-06-24T00:00:00Z\"}}" \
    "$TEST_HOME/.codex-switcher/cache.json"
  # Backdate the home past the orphan grace window so only the recorded-token
  # protection (not the mtime grace) can save it.
  touch -t 200001010000 "$home/auth.json"
  touch -t 200001010000 "$home"

  run_helper lease gc >/dev/null 2>&1 || true

  [[ -d "$home" ]] || fail "lease gc swept a preserved expired lease home (credential lost)"
  has_lease RotateA || fail "lease gc dropped a preserved expired reservation"

  # A second gc must STILL preserve it (the protection is not one-shot).
  run_helper lease gc >/dev/null 2>&1 || true
  [[ -d "$home" ]] || fail "a second lease gc swept the preserved expired lease home"
}

test_lease_end_exits_nonzero_on_recoverable_writeback_failure() {
  write_exec_test_state
  local begin_report="$WORK_DIR/lease-begin.json"
  run_helper lease begin --json --non-interactive > "$begin_report"
  local home token
  home="$(plutil -extract home raw -o - "$begin_report")"
  token="$(plutil -extract token raw -o - "$begin_report")"

  # Different-identity blob in the home => exit 5 inside importRefreshedAuth.
  # F3 regression: lease end must exit NON-ZERO so automation can detect that a
  # credential is stranded pending recovery (vs. the clean exit-0 teardown).
  make_oauth_auth "$home/auth.json" "access-x" "refresh-x" "acct-DIFFERENT"

  if run_helper lease end "$token" --non-interactive >/dev/null 2>&1; then
    fail "lease end exited 0 despite a recoverable (identity-mismatch) writeback failure"
  fi
  [[ -d "$home" ]] || fail "lease end deleted the home after a recoverable writeback failure"
  has_lease RotateA || fail "lease end released the reservation after a recoverable writeback failure"
}

test_lease_end_is_idempotent_zero_exit_when_no_lease() {
  write_exec_test_state
  # No lease recorded: ending an unknown token is the idempotent no-op and MUST
  # stay exit 0 so a trap firing it repeatedly never reports failure.
  run_helper lease end "no-such-token" --non-interactive >/dev/null 2>&1 \
    || fail "lease end of an unknown token did not exit 0 (idempotent no-op)"
}

test_lease_end_rejects_mismatched_profile() {
  write_exec_test_state
  local begin_report="$WORK_DIR/lease-begin.json"
  run_helper lease begin --json --non-interactive > "$begin_report"
  local home token
  home="$(plutil -extract home raw -o - "$begin_report")"
  token="$(plutil -extract token raw -o - "$begin_report")"

  # The lease is bound to RotateA; ending it with --profile RotateB must fail
  # fast (wrong-account writeback footgun) and touch nothing.
  if run_helper lease end "$token" --profile RotateB --non-interactive >/dev/null 2>&1; then
    fail "lease end accepted a --profile that does not match the bound profile"
  fi
  [[ -d "$home" ]] || fail "lease end removed the home despite the --profile guard rejecting the call"
  has_lease RotateA || fail "lease end released the reservation despite rejecting the call"
}

test_switch_preserves_outgoing_auth
test_switch_current_chatgpt_layout_stops_running_desktop
test_switch_invalid_desktop_installation_preserves_state
test_switch_rolls_back_after_auth_write_failure
test_switch_rolls_back_after_config_write_failure
test_switch_does_not_roll_back_after_launch_failure
test_switch_refuses_unmanaged_live_auth
test_switch_refuses_unreadable_live_auth
test_switch_refuses_ambiguous_live_auth
test_switch_uses_active_profile_to_disambiguate_live_auth
test_login_uses_isolated_home_and_preserves_live_auth
test_login_rejects_duplicate_auth_and_preserves_target_auth
test_file_vault_login_preserves_incomplete_legacy_disk_migration
test_keychain_repair_reports_no_migration_yet
test_best_auth_exports_lowest_usage_configured_profile
test_mark_exhausted_persists_to_cache_and_best_auth_skips_it
test_exec_rotates_on_usage_limit
test_exec_does_not_rotate_on_ordinary_failure
test_exec_cleans_temp_home_when_command_missing
test_exec_gives_up_when_all_profiles_limited
test_unentitled_build_uses_file_vault
test_force_keychain_cannot_bypass_entitlement
test_file_auth_store_dir_override_pins_backend
test_import_auth_preserves_on_missing_identity
test_import_auth_accepts_same_identity_refresh
test_lease_begin_reserves_and_seeds
test_lease_begin_excludes_active_lease
test_lease_gc_reclaims_expired
test_lease_gc_preserves_active_lease
test_lease_gc_sweeps_old_orphan_but_keeps_fresh
test_lease_swap_rotates_credential_in_place
test_lease_end_writes_back_and_releases
test_lease_end_is_idempotent
test_lease_end_preserves_home_on_writeback_failure
test_lease_gc_preserves_expired_lease_with_recoverable_writeback
test_lease_end_exits_nonzero_on_recoverable_writeback_failure
test_lease_end_is_idempotent_zero_exit_when_no_lease
test_lease_end_rejects_mismatched_profile

printf 'Integration tests: all tests passed\n'
