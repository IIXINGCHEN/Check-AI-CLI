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
  if ! printf '%s' "$haystack" | grep -F -- "$needle" >/dev/null 2>&1; then
    printf '[FAIL] %s (missing: %s)\n' "$message" "$needle" >&2
    exit 1
  fi
}

assert_not_contains() {
  local haystack="$1" needle="$2" message="$3"
  if printf '%s' "$haystack" | grep -F -- "$needle" >/dev/null 2>&1; then
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
assert_contains "$text" 'npmjs.org is authoritative for dist-tags' 'official metadata authority'
assert_contains "$text" 'install_spec="${package}@${target}"' 'authoritative version pin'
assert_contains "$text" '--allow-scripts=' 'one-shot lifecycle-script approvals'
assert_contains "$text" 'is_grok_npm_migration_candidate' 'canonical Grok npm migration gate'
assert_contains "$text" 'Automatic npm update was blocked to avoid a conflicting installation.' 'mixed-install guard'
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
assert_equal "$(compare_semver 1.2.3-beta.1 1.2.3)" "-1" 'prerelease older than release'
assert_equal "$(compare_semver 1.2.3 1.2.3-beta.1)" "1" 'release newer than prerelease'
assert_equal "$(compare_semver 1.2.3-beta.1 1.2.3-beta.2)" "-1" 'beta.1 older than beta.2'
assert_equal "$(compare_semver 1.2.3-beta.2 1.2.3-beta.10)" "-1" 'numeric prerelease identifiers compare numerically'
assert_equal "$(compare_semver 1.2.3-1 1.2.3-alpha)" "-1" 'numeric prerelease identifier is lower than alphanumeric'
assert_equal "$(compare_semver 1.2.3-beta 1.2.3-beta.1)" "-1" 'fewer prerelease identifiers is lower'
assert_equal "$(compare_semver 1.2.3-alpha.1 1.2.3-beta.1)" "-1" 'alphanumeric prerelease identifiers compare in ASCII order'
assert_equal "$(extract_semver 'v1.4.5 (build)')" "1.4.5" 'extract semver'

# tool defs count
assert_equal "${#TOOL_DEFS[@]}" "5" 'five tools'

# socket timeouts: stalled metadata/payload fetches must fail into retry or
# failover paths instead of hanging the run (regression for review-1 W3)
assert_contains "$text" 'curl -fsSL --max-time 30' 'checker fetch_text bounds curl by max-time'
assert_contains "$text" 'wget -qO- --timeout=30' 'checker fetch_text bounds wget by timeout'
install_text="$(cat "$ROOT_DIR/install.sh")"
assert_contains "$install_text" 'curl -fsSL --max-time 30' 'installer fetch_text bounds curl by max-time'
assert_contains "$install_text" '--timeout=30' 'installer fetches bound wget by timeout'
assert_contains "$install_text" 'curl -fSL --progress-bar --max-time 30' 'installer payload download bounds curl by max-time'

printf '[PASS] npm_only_contract.sh\n'
