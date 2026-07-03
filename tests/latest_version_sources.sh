#!/usr/bin/env bash
set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

assert_eq() {
  local actual="$1" expected="$2" message="$3"
  if [ "$actual" != "$expected" ]; then
    printf '[FAIL] %s\nExpected: %s\nActual: %s\n' "$message" "$expected" "$actual" >&2
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

source "$ROOT_DIR/scripts/check-ai-cli-versions.sh"

test_claude_prefers_newer_npm_over_stable() {
  get_claude_repo_latest_version() { printf '%s\n' '2.1.200'; }
  get_claude_bootstrap_stable_version() { printf '%s\n' '2.1.152'; }
  get_npm_latest_version() { printf '%s\n' '2.1.162'; }

  assert_eq "$(get_latest_claude 2>/dev/null)" '2.1.162' 'Claude should use newer installable npm version over bootstrap stable.'
}

test_claude_falls_back_to_repo_when_installable_sources_missing() {
  get_claude_repo_latest_version() { printf '%s\n' '2.1.72'; }
  get_claude_bootstrap_stable_version() { :; }
  get_npm_latest_version() { :; }

  assert_eq "$(get_latest_claude)" '2.1.72' 'Claude should fall back to GitHub release metadata only when installable sources are missing.'
}

test_codex_prefers_npm_installable_source() {
  get_github_latest_release_version() { printf '%s\n' '0.109.0'; }
  get_npm_latest_version() { printf '%s\n' '0.110.0'; }

  assert_eq "$(get_latest_codex)" '0.110.0' 'Codex should use npm because the updater installs via npm.'
}

test_gemini_prefers_npm_installable_source() {
  get_github_latest_release_version() { printf '%s\n' '0.24.0'; }
  get_npm_latest_version() { printf '%s\n' '0.25.0'; }

  assert_eq "$(get_latest_gemini)" '0.25.0' 'Gemini should use npm because the updater installs via npm.'
}

run_test 'get_latest_claude prefers newer npm installable source' test_claude_prefers_newer_npm_over_stable
run_test 'get_latest_claude falls back to repo when installable sources are missing' test_claude_falls_back_to_repo_when_installable_sources_missing
run_test 'get_latest_codex prefers npm installable source' test_codex_prefers_npm_installable_source
run_test 'get_latest_gemini prefers npm installable source' test_gemini_prefers_npm_installable_source
printf '[PASS] All shell latest-source tests passed.\n'
