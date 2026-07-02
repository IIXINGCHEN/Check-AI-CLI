#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
source "$REPO_ROOT/scripts/check-ai-cli-versions.sh"

assert_eq() {
  local actual="$1" expected="$2" message="$3"
  if [ "$actual" != "$expected" ]; then
    printf '[FAIL] %s\nExpected: %s\nActual: %s\n' "$message" "$expected" "$actual"
    exit 1
  fi
}

assert_starts_with() {
  local actual="$1" expected="$2" message="$3"
  case "$actual" in
    "$expected"*) ;;
    *)
      printf '[FAIL] %s\nExpected prefix: %s\nActual: %s\n' "$message" "$expected" "$actual"
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

test_ensure_profile_path_prefers() {
  local temp_dir rc_file
  temp_dir="$(mktemp -d)"
  rc_file="$temp_dir/.bashrc"
  PATH="/usr/bin:/bin"
  export PATH
  SHELL="/bin/bash"
  export SHELL

  get_profile_file() {
    printf '%s\n' "$rc_file"
  }

  ensure_profile_path_prefers "$temp_dir/npm-bin" >/dev/null 2>&1 || true

  assert_starts_with "$PATH" "$temp_dir/npm-bin" 'Expected current PATH to be prepended with the repaired directory.'
  grep -F "export PATH=\"$temp_dir/npm-bin:\$PATH\"" "$rc_file" >/dev/null
  rm -rf "$temp_dir"
}

test_repair_tool_path_keeps_priority_order() {
  local temp_dir rc_file primary secondary
  temp_dir="$(mktemp -d)"
  rc_file="$temp_dir/.bashrc"
  primary="$temp_dir/opencode-bin"
  secondary="$temp_dir/npm-bin"
  mkdir -p "$primary" "$secondary"
  PATH="/usr/bin:/bin"
  export PATH
  SHELL="/bin/bash"
  export SHELL

  get_profile_file() {
    printf '%s\n' "$rc_file"
  }

  get_tool_candidate_dirs() {
    printf '%s\n%s\n' "$primary" "$secondary"
  }

  repair_tool_path opencode >/dev/null 2>&1

  assert_starts_with "$PATH" "$primary" 'Expected first candidate directory to stay first after repair.'
  grep -F "$primary" "$rc_file" >/dev/null
  grep -F "$secondary" "$rc_file" >/dev/null
  rm -rf "$temp_dir"
}

test_resolve_version_conflict_prefers_higher_official_source() {
  local version
  version="$(resolve_version_conflict 'Claude Code' 'official stable' '2.1.71' 'npm latest' '2.1.69' | tail -n 1)"
  assert_eq "$version" '2.1.71' 'Expected conflict resolver to keep the higher official version.'
}

run_test 'ensure_profile_path_prefers persists and prepends PATH' test_ensure_profile_path_prefers
run_test 'repair_tool_path keeps candidate priority order' test_repair_tool_path_keeps_priority_order
run_test 'resolve_version_conflict prefers higher official source' test_resolve_version_conflict_prefers_higher_official_source
printf '[PASS] All shell PATH repair tests passed.\n'
