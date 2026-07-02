#!/usr/bin/env bash
set -uo pipefail

# Regression coverage for extract_semver boundary anchoring (F2).
# Mirrors tests/SemVerParsing.Tests.ps1 for the POSIX checker. Prior to the fix
# the grep pattern `[0-9]+\.[0-9]+\.[0-9]+` had no boundary anchors and would
# extract a "version" from any three-dot-separated digit run, mis-parsing
# multi-segment numbers like dates (2026.01.0.142 -> "2026.01.0"). The anchored
# grep now requires the match to be bracketed by start/end or non-digit/non-dot
# characters.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

assert_equal() {
  local actual="$1" expected="$2" message="$3"
  if [ "$actual" != "$expected" ]; then
    printf '[FAIL] %s\nExpected: %s\nActual: %s\n' "$message" "$expected" "$actual" >&2
    exit 1
  fi
}

assert_empty() {
  local actual="$1" message="$2"
  if [ -n "$actual" ]; then
    printf '[FAIL] %s\nExpected: <empty>\nActual: %s\n' "$message" "$actual" >&2
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

# Source the main checker to bring extract_semver into scope. The file guards
# its main() invocation behind BASH_SOURCE comparison so sourcing is safe.
# shellcheck disable=SC1091
source "$ROOT_DIR/scripts/check-ai-cli-versions.sh"

test_plain_version() {
  local actual
  actual="$(extract_semver '1.2.3')"
  assert_equal "$actual" '1.2.3' 'Plain x.y.z should parse unchanged.'
}

test_v_prefix_tag() {
  local actual
  actual="$(extract_semver 'v1.2.3')"
  assert_equal "$actual" '1.2.3' 'v-prefixed tag should strip the prefix.'
}

test_rust_v_prefix_tag() {
  local actual
  actual="$(extract_semver 'rust-v0.142.3')"
  assert_equal "$actual" '0.142.3' 'rust-v prefixed tag should strip the prefix.'
}

test_claude_v_prefix_tag() {
  local actual
  actual="$(extract_semver 'claude-v1.0.0')"
  assert_equal "$actual" '1.0.0' 'claude-v prefixed tag should strip the prefix.'
}

test_version_with_build_metadata() {
  local actual
  actual="$(extract_semver 'claude 1.2.3 (build abc)')"
  assert_equal "$actual" '1.2.3' 'Version embedded in a longer string should be extracted.'
}

test_multi_word_version() {
  local actual
  actual="$(extract_semver 'claude code 1.0.30')"
  assert_equal "$actual" '1.0.30' 'Version after multiple words should be extracted.'
}

test_codex_version_output() {
  local actual
  actual="$(extract_semver 'codex 0.142.3')"
  assert_equal "$actual" '0.142.3' 'codex version output should parse.'
}

test_empty_input() {
  local actual
  actual="$(extract_semver '')"
  assert_empty "$actual" 'Empty input should yield empty.'
}

test_no_version_present() {
  local actual
  actual="$(extract_semver 'no version here')"
  assert_empty "$actual" 'String without a version should yield empty.'
}

test_rejects_multi_segment_date() {
  # Regression guard: previously extracted "2026.01.0" from "2026.01.0.142.3".
  local actual
  actual="$(extract_semver '2026.01.0.142.3')"
  assert_empty "$actual" 'Multi-segment digit run should not yield a partial version.'
}

test_rejects_ipv4_address() {
  local actual
  actual="$(extract_semver '10.20.30.40')"
  assert_empty "$actual" 'IPv4-like address should not be treated as a version.'
}

test_rejects_path_with_four_segment_number() {
  local actual
  actual="$(extract_semver 'C:\1.2.3.4\bin')"
  assert_empty "$actual" 'A 4-segment dotted number embedded in a path should not yield a partial version.'
}

run_test 'extract_semver parses a plain version string' test_plain_version
run_test 'extract_semver parses a v-prefixed tag' test_v_prefix_tag
run_test 'extract_semver parses a rust-v prefixed tag' test_rust_v_prefix_tag
run_test 'extract_semver parses a claude-v prefixed tag' test_claude_v_prefix_tag
run_test 'extract_semver parses a version with build metadata' test_version_with_build_metadata
run_test 'extract_semver parses a multi-word version output' test_multi_word_version
run_test 'extract_semver parses a codex version output' test_codex_version_output
run_test 'extract_semver returns empty for empty input' test_empty_input
run_test 'extract_semver returns empty when no version is present' test_no_version_present
run_test 'extract_semver rejects a multi-segment date-like number' test_rejects_multi_segment_date
run_test 'extract_semver rejects an IPv4-like address' test_rejects_ipv4_address
run_test 'extract_semver rejects a path with a 4-segment number' test_rejects_path_with_four_segment_number

printf '[PASS] All extract_semver regression tests passed.\n'