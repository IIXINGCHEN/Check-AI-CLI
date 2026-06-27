#!/usr/bin/env bash
set -uo pipefail

# Regression coverage for shell-side Claude native updater (F1.2).
# Prior to the fix the POSIX checker had no `claude update` path and jumped
# straight to piping the official install.sh into bash. This test verifies the
# new try_claude_native_update is attempted first when claude exists, and that
# the timeout/env knob is honored.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

assert_equal() {
  local actual="$1" expected="$2" message="$3"
  if [ "$actual" != "$expected" ]; then
    printf '[FAIL] %s\nExpected: %s\nActual: %s\n' "$message" "$expected" "$actual" >&2
    exit 1
  fi
}

assert_true() {
  local cond="$1" message="$2"
  if [ "$cond" != "0" ]; then
    printf '[FAIL] %s\nExpected: true (0)\nActual: %s\n' "$message" "$cond" >&2
    exit 1
  fi
}

run_test() {
  local name="$1"
  shift
  if "$@"; then
    printf '[PASS] %s\n' "$name"
    return 0
  fi
  printf '[FAIL] %s\n' "$name" >&2
  exit 1
}

# Source the main checker to bring functions into scope.
# shellcheck disable=SC1091
source "$ROOT_DIR/scripts/check-ai-cli-versions.sh"

test_native_update_skipped_when_claude_absent() {
  local rc
  (
    command_exists() { [ "$1" != "claude" ]; }
    try_claude_native_update >/dev/null 2>&1
  )
  rc=$?
  if [ "$rc" -eq 0 ]; then
    printf '[FAIL] Expected try_claude_native_update to skip (non-zero) when claude is absent, got 0.\n' >&2
    exit 1
  fi
}

test_native_update_invokes_claude_update_when_present() {
  local output rc
  output="$(
    command_exists() { return 0; }
    timeout() { echo "timeout-called: $*"; return 0; }
    log_info() { :; }
    log_warn() { :; }
    try_claude_native_update 2>&1
    echo "exit=$?"
  )"
  # timeout wrapper receives "claude update" as its arguments.
  if ! echo "$output" | grep -q 'timeout-called: .*claude update'; then
    printf '[FAIL] Expected try_claude_native_update to invoke timeout with `claude update`.\nOutput: %s\n' "$output" >&2
    exit 1
  fi
  assert_equal "$(echo "$output" | tail -1 | sed 's/exit=//')" '0' 'Expected successful native update to return 0.'
}

test_native_update_honors_timeout_env() {
  local output
  output="$(
    CHECK_AI_CLI_CLAUDE_UPDATE_TIMEOUT_SECONDS=42
    export CHECK_AI_CLI_CLAUDE_UPDATE_TIMEOUT_SECONDS
    command_exists() { return 0; }
    timeout() { echo "timeout-seconds=$1"; return 0; }
    claude() { return 0; }
    log_info() { :; }
    log_warn() { :; }
    get_claude_native_update_timeout_seconds
  )"
  assert_equal "$output" '42' 'Expected timeout env knob to override the default 300s.'
}

test_native_update_uses_default_timeout_when_env_unset() {
  local output
  output="$(
    unset CHECK_AI_CLI_CLAUDE_UPDATE_TIMEOUT_SECONDS
    get_claude_native_update_timeout_seconds
  )"
  assert_equal "$output" '300' 'Expected default native update timeout to be 300s.'
}

test_version_at_least_empty_target_is_satisfied() {
  local result
  result="$(
    test_claude_version_at_least ""
    echo "exit=$?"
  )"
  assert_true "$(echo "$result" | tail -1 | sed 's/exit=//')" 'Expected empty target version to be treated as satisfied.'
}

test_version_at_least_rejects_when_local_missing() {
  local result
  result="$(
    get_local_claude() { return 1; }
    test_claude_version_at_least "1.2.3"
    echo "exit=$?"
  )"
  # exit=1 means "not satisfied" which is a non-zero return; we expect failure.
  if [ "$(echo "$result" | tail -1 | sed 's/exit=//')" != "1" ]; then
    printf '[FAIL] Expected missing local version to fail version-at-least check.\n' >&2
    exit 1
  fi
  printf '[PASS] (implicit)\n'
}

run_test 'try_claude_native_update skips when claude is absent' test_native_update_skipped_when_claude_absent
run_test 'try_claude_native_update invokes claude update when present' test_native_update_invokes_claude_update_when_present
run_test 'native update timeout honors CHECK_AI_CLI_CLAUDE_UPDATE_TIMEOUT_SECONDS' test_native_update_honors_timeout_env
run_test 'native update timeout defaults to 300s when env unset' test_native_update_uses_default_timeout_when_env_unset
run_test 'test_claude_version_at_least treats empty target as satisfied' test_version_at_least_empty_target_is_satisfied
run_test 'test_claude_version_at_least rejects when local version is missing' test_version_at_least_rejects_when_local_missing

printf '[PASS] All Claude native updater shell tests passed.\n'