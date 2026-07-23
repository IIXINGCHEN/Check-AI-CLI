#!/usr/bin/env bash
set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MAIN="$ROOT_DIR/scripts/check-ai-cli-versions.sh"

assert_equal() {
  local actual="$1" expected="$2" message="$3"
  if [ "$actual" != "$expected" ]; then
    printf '[FAIL] %s\nExpected: %s\nActual: %s\n' "$message" "$expected" "$actual" >&2
    exit 1
  fi
}

assert_contains() {
  local haystack="$1" needle="$2" message="$3"
  if ! printf '%s' "$haystack" | grep -F "$needle" >/dev/null 2>&1; then
    printf '[FAIL] %s (missing: %s)\n' "$message" "$needle" >&2
    exit 1
  fi
}

assert_not_contains() {
  local haystack="$1" needle="$2" message="$3"
  if printf '%s' "$haystack" | grep -F "$needle" >/dev/null 2>&1; then
    printf '[FAIL] %s (found forbidden: %s)\n' "$message" "$needle" >&2
    exit 1
  fi
}

# shellcheck disable=SC1091
source "$MAIN"

text="$(cat "$MAIN")"

assert_contains "$text" '@anthropic-ai/claude-code' 'claude package'
assert_contains "$text" '@openai/codex' 'codex package'
assert_contains "$text" '@google/gemini-cli' 'gemini package'
assert_contains "$text" '@xai-official/grok' 'grok package'
assert_contains "$text" 'opencode-ai' 'opencode package'
assert_contains "$text" 'update_tool_via_npm' 'npm-only updater'
assert_contains "$text" 'npm-only' 'banner npm-only'

assert_not_contains "$text" 'app.factory.ai' 'no factory bootstrap'
assert_not_contains "$text" 'update_factory' 'no update_factory'
# Avoid bare 'claude update' — it false-matches "get_local_claude update_claude".
assert_not_contains "$text" 'claude.ai/install' 'no remote claude install'
assert_not_contains "$text" 'Trying: claude update' 'no native claude updater path'
assert_not_contains "$text" 'brew install' 'no brew install channel'
assert_not_contains "$text" 'opencode upgrade' 'no opencode self-upgrade'
assert_not_contains "$text" 'confirm_remote_script_execution' 'no remote script gate for AI CLIs'

# semver helpers
assert_equal "$(compare_semver 1.2.3 1.2.3)" "0" 'semver equal'
assert_equal "$(compare_semver 1.2.3 1.2.4)" "-1" 'semver older'
assert_equal "$(compare_semver 2.0.0 1.9.9)" "1" 'semver newer'
assert_equal "$(extract_semver 'v1.4.5 (build)')" "1.4.5" 'extract semver'

# tool defs count
assert_equal "${#TOOL_DEFS[@]}" "5" 'five tools'

printf '[PASS] npm_only_contract.sh\n'
