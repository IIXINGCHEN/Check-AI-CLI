#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

assert_equal() {
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

test_source_without_main() {
  local output
  output="$(
    CHECK_AI_CLI_SKIP_MAIN=1 bash --noprofile --norc -c "
      source \"$ROOT_DIR/install.sh\"
      declare -F download_with_retry >/dev/null
      printf ready
    "
  )"
  assert_equal "$output" 'ready' 'Expected install.sh to expose helpers in test mode.'
}

test_distribution_path_rejects_traversal() {
  local rc
  set +e
  (
    CHECK_AI_CLI_SKIP_MAIN=1 bash --noprofile --norc -c "
      source \"$ROOT_DIR/install.sh\"
      validate_distribution_path '../install.ps1'
    "
  ) >/dev/null 2>&1
  rc=$?
  set -e
  if [ "$rc" -eq 0 ]; then
    printf '[FAIL] Expected the shell installer to reject traversal paths.\\n' >&2
    exit 1
  fi
}

test_main_checker_fetch_text_suppresses_native_progress() {
  local output
  output="$(
    bash --noprofile --norc -c "
      source \"$ROOT_DIR/scripts/check-ai-cli-versions.sh\"
      show_progress_enabled() { return 0; }
      command_exists() { [ \"\$1\" = curl ]; }
      curl() { printf 'args:%s\n' \"\$*\"; }
      fetch_text 'https://example.test/file'
    "
  )"
  assert_equal "$output" 'args:-fsSL https://example.test/file' 'Expected main checker fetch_text to suppress curl native progress output.'
}

test_download_with_retry_under_nounset() {
  local output
  output="$(
    CHECK_AI_CLI_SKIP_MAIN=1 bash --noprofile --norc -c "
      set -euo pipefail
      source \"$ROOT_DIR/install.sh\"
      fetch_to_temp() {
        printf payload > \"\$2\"
      }
      tmp_root=\$(mktemp -d)
      download_with_retry 'https://example.test/file' \"\$tmp_root/out.txt\"
      test -s \"\$tmp_root/out.txt\"
      printf ready
    "
  )"
  assert_equal "$output" 'ready' 'Expected download_with_retry to work under set -u after local variable initialization.'
}

test_resolve_base_prefers_latest_stable_release() {
  local output
  output="$(
    CHECK_AI_CLI_SKIP_MAIN=1 bash --noprofile --norc -c "
      source \"$ROOT_DIR/install.sh\"
      fetch_text() { printf '{\"tag_name\":\"v1.2.3\"}'; }
      resolve_base
    "
  )"
  assert_equal "$output" 'https://raw.githubusercontent.com/IIXINGCHEN/Check-AI-CLI/v1.2.3' 'Expected implicit shell installer ref to resolve to the latest stable release tag.'
}

test_resolve_base_falls_back_to_latest_main_commit_on_release_lookup_failure() {
  local output
  output="$(
    CHECK_AI_CLI_SKIP_MAIN=1 bash --noprofile --norc -c "
      source \"$ROOT_DIR/install.sh\"
      fetch_text() {
        if [ \"\$1\" = 'https://api.github.com/repos/IIXINGCHEN/Check-AI-CLI/releases/latest' ]; then
          return 1
        fi
        if [ \"\$1\" = 'https://api.github.com/repos/IIXINGCHEN/Check-AI-CLI/git/ref/heads/main' ]; then
          printf '{\"object\":{\"sha\":\"0123456789abcdef0123456789abcdef01234567\"}}'
          return 0
        fi
        return 2
      }
      resolve_base
    "
  )"
  assert_equal "$output" 'https://raw.githubusercontent.com/IIXINGCHEN/Check-AI-CLI/0123456789abcdef0123456789abcdef01234567' 'Expected shell installer to fall back to the latest main commit when stable release lookup fails.'
}

test_resolve_base_fails_closed_when_all_ref_lookups_fail() {
  local output rc
  set +e
  output="$(
    CHECK_AI_CLI_SKIP_MAIN=1 bash --noprofile --norc -c "
      source \"$ROOT_DIR/install.sh\"
      fetch_text() { return 1; }
      resolve_base 2>/dev/null
    "
  )"
  rc=$?
  set -e
  if [ "$rc" -eq 0 ]; then
    printf '[FAIL] Expected shell installer to refuse a mutable main fallback.\n' >&2
    exit 1
  fi
}

test_resolve_base_respects_explicit_ref() {
  local output
  output="$(
    CHECK_AI_CLI_SKIP_MAIN=1 CHECK_AI_CLI_REF=v1.2.3 bash --noprofile --norc -c "
      source \"$ROOT_DIR/install.sh\"
      fetch_text() { exit 99; }
      resolve_base
    "
  )"
  assert_equal "$output" 'https://raw.githubusercontent.com/IIXINGCHEN/Check-AI-CLI/v1.2.3' 'Expected explicit release tag to bypass shell stable release resolution.'
}

test_resolve_base_resolves_explicit_main_to_commit() {
  local output
  output="$(
    CHECK_AI_CLI_SKIP_MAIN=1 CHECK_AI_CLI_REF=main bash --noprofile --norc -c "
      source \"$ROOT_DIR/install.sh\"
      fetch_text() {
        if [ \"\$1\" = 'https://api.github.com/repos/IIXINGCHEN/Check-AI-CLI/git/ref/heads/main' ]; then
          printf '{\"object\":{\"sha\":\"0123456789abcdef0123456789abcdef01234567\"}}'
          return 0
        fi
        return 1
      }
      resolve_base
    "
  )"
  assert_equal "$output" 'https://raw.githubusercontent.com/IIXINGCHEN/Check-AI-CLI/0123456789abcdef0123456789abcdef01234567' 'Expected explicit main to resolve to an immutable commit.'
}

test_resolve_base_respects_explicit_raw_base() {
  local output
  output="$(
    CHECK_AI_CLI_SKIP_MAIN=1 CHECK_AI_CLI_RAW_BASE='https://raw.githubusercontent.com/IIXINGCHEN/Check-AI-CLI/main' bash --noprofile --norc -c "
      source \"$ROOT_DIR/install.sh\"
      fetch_text() { exit 99; }
      resolve_base
    "
  )"
  assert_equal "$output" 'https://raw.githubusercontent.com/IIXINGCHEN/Check-AI-CLI/main' 'Expected explicit CHECK_AI_CLI_RAW_BASE to bypass shell stable release resolution.'
}

test_main_exit_trap_under_nounset() {
  local output
  output="$(
    CHECK_AI_CLI_SKIP_MAIN=1 bash --noprofile --norc -c "
      set -euo pipefail
      CHECK_AI_CLI_REF=main
      source \"$ROOT_DIR/install.sh\"
      INSTALL_DIR=\"\$PWD/mock-install\"
      require_fetch_tool() { return 0; }
      require_sha256_tool() { return 0; }
      mktemp() { printf '%s\n' \"\$PWD/mock-stage\"; }
      download_manifest() {
        mkdir -p \"\$1\"
        printf 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa  bin/check-ai-cli\n' > \"\$1/checksums.sha256\"
      }
      download_distribution_list() { return 0; }
      download_all() { return 0; }
      verify_all() { return 0; }
      deploy_all() { return 0; }
      print_next_steps() { return 0; }
      main
      rm -rf -- \"\$INSTALL_DIR\"
      printf ready
    " 2>&1
  )"
  assert_equal "$output" 'ready' 'Expected main to exit cleanly without nounset trap failures.'
}

run_test 'install.sh can load helpers without executing main flow' test_source_without_main
run_test 'shell installer rejects traversal distribution paths' test_distribution_path_rejects_traversal
run_test 'Main shell checker suppresses native fetch progress' test_main_checker_fetch_text_suppresses_native_progress
run_test 'download_with_retry works under nounset' test_download_with_retry_under_nounset
run_test 'resolve_base prefers latest stable release' test_resolve_base_prefers_latest_stable_release
run_test 'resolve_base falls back to latest main commit on release lookup failure' test_resolve_base_falls_back_to_latest_main_commit_on_release_lookup_failure
run_test 'resolve_base fails closed when all ref lookups fail' test_resolve_base_fails_closed_when_all_ref_lookups_fail
run_test 'resolve_base respects explicit ref' test_resolve_base_respects_explicit_ref
run_test 'resolve_base resolves explicit main to commit' test_resolve_base_resolves_explicit_main_to_commit
run_test 'resolve_base respects explicit raw base' test_resolve_base_respects_explicit_raw_base
run_test 'main exits cleanly under nounset' test_main_exit_trap_under_nounset

printf '[PASS] All install progress shell tests passed.\n'
