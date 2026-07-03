#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$REPO_ROOT/scripts/check-ai-cli-versions.sh"

assert_eq() {
  local actual="$1" expected="$2" message="$3"
  if [ "$actual" != "$expected" ]; then
    printf '[FAIL] %s\nExpected: %s\nActual: %s\n' "$message" "$expected" "$actual" >&2
    exit 1
  fi
}

assert_contains() {
  local actual="$1" expected="$2" message="$3"
  case "$actual" in
    *"$expected"*) ;;
    *)
      printf '[FAIL] %s\nExpected substring: %s\nActual: %s\n' "$message" "$expected" "$actual" >&2
      exit 1
      ;;
  esac
}

assert_not_contains() {
  local actual="$1" unexpected="$2" message="$3"
  case "$actual" in
    *"$unexpected"*)
      printf '[FAIL] %s\nUnexpected substring: %s\nActual: %s\n' "$message" "$unexpected" "$actual" >&2
      exit 1
      ;;
  esac
}

run_test() {
  local name="$1"
  shift
  "$@"
  printf '[PASS] %s\n' "$name"
}

test_select_best_npm_mirror_returns_url_only() {
  local registry
  registry="$(
    NPM_BEST_MIRROR=""
    detect_network_environment() {
      NETWORK_REGION="global"
      log_info "diagnostic noise"
    }
    select_best_npm_mirror
    printf '%s' "$NPM_BEST_MIRROR"
  )"

  assert_eq "$registry" 'https://registry.npmjs.org' 'Expected npm mirror cache to contain only the registry URL.'
}

test_untrusted_mirror_resolution_returns_url_only() {
  local base
  base="$(
    CHECK_AI_CLI_SKIP_MAIN=1 \
    CHECK_AI_CLI_RAW_BASE='https://mirror.example/repo' \
    CHECK_AI_CLI_ALLOW_UNTRUSTED_MIRROR=1 \
    bash --noprofile --norc -c '
      source "$1"
      sleep() { :; }
      resolve_base
    ' _ "$REPO_ROOT/install.sh" 2>/dev/null
  )"

  assert_eq "$base" 'https://mirror.example/repo' 'Expected resolve_base stdout to contain only the resolved base URL.'
}

test_missing_install_failure_is_not_reported_success() {
  local rc
  AUTO_MODE=1
  bad_update() { return 42; }

  set +e
  handle_update_flow '1.2.3' '' bad_update >/dev/null 2>&1
  rc=$?
  set -e

  assert_eq "$rc" '42' 'Expected install failure to propagate out of handle_update_flow.'
}

test_main_returns_nonzero_for_selected_update_failure() {
  local rc

  set +e
  (
    AUTO_MODE=1
    require_fetch_tool() { return 0; }
    show_banner() { :; }
    select_best_npm_mirror() { :; }
    ask_selection() { printf '3\n'; }
    get_latest_codex() { printf '2.0.0\n'; }
    get_local_codex() { printf '1.0.0\n'; }
    update_codex() { return 42; }
    main >/dev/null 2>&1
  )
  rc=$?
  set -e

  if [ "$rc" -eq 0 ]; then
    printf '[FAIL] Expected main to return non-zero when a selected update fails.\n' >&2
    exit 1
  fi
}

test_proxy_logs_hide_credentials() {
  local output
  output="$(
    HTTP_PROXY='http://user:secret@127.0.0.1:8080'
    HTTPS_PROXY=''
    ALL_PROXY=''
    test_url_timing() { printf '%s\n' '-1'; return 1; }
    detect_network_environment 2>&1
  )"

  assert_not_contains "$output" 'secret' 'Expected proxy logs to hide password text.'
  assert_contains "$output" 'http://***@127.0.0.1:8080' 'Expected proxy logs to keep a redacted proxy location.'
}

run_test 'select_best_npm_mirror returns only the URL' test_select_best_npm_mirror_returns_url_only
run_test 'install.sh resolve_base returns only the URL' test_untrusted_mirror_resolution_returns_url_only
run_test 'handle_update_flow propagates install failure' test_missing_install_failure_is_not_reported_success
run_test 'main returns non-zero for selected update failure' test_main_returns_nonzero_for_selected_update_failure
run_test 'proxy logs hide credentials' test_proxy_logs_hide_credentials
printf '[PASS] All shell output contract tests passed.\n'
