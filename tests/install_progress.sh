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
      declare -F render_byte_progress >/dev/null
      printf ready
    "
  )"
  assert_equal "$output" 'ready' 'Expected install.sh to expose helpers in test mode.'
}

test_render_fifty_percent() {
  local output
  output="$(
    CHECK_AI_CLI_SKIP_MAIN=1 bash --noprofile --norc -c "
      source \"$ROOT_DIR/install.sh\"
      render_byte_progress 100 200 20
    "
  )"
  assert_equal "$output" '[##########..........] 50%' 'Expected shell progress to render ten filled segments at 50%.'
}

test_clamp_to_hundred() {
  local output
  output="$(
    CHECK_AI_CLI_SKIP_MAIN=1 bash --noprofile --norc -c "
      source \"$ROOT_DIR/install.sh\"
      render_byte_progress 120 80 20
    "
  )"
  assert_equal "$output" '[####################] 100%' 'Expected shell progress to clamp at 100%.'
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

test_main_exit_trap_under_nounset() {
  local output
  output="$(
    CHECK_AI_CLI_SKIP_MAIN=1 bash --noprofile --norc -c "
      set -euo pipefail
      source \"$ROOT_DIR/install.sh\"
      require_fetch_tool() { return 0; }
      require_sha256_tool() { return 0; }
      mktemp() { printf '%s\n' \"\$PWD/mock-stage\"; }
      download_manifest() {
        mkdir -p \"\$1\"
        printf 'aaaaaaaa  bin/check-ai-cli\n' > \"\$1/checksums.sha256\"
      }
      download_all() { return 0; }
      verify_all() { return 0; }
      deploy_all() { return 0; }
      print_next_steps() { return 0; }
      main
      printf ready
    " 2>&1
  )"
  assert_equal "$output" 'ready' 'Expected main to exit cleanly without nounset trap failures.'
}

run_test 'install.sh can load helpers without executing main flow' test_source_without_main
run_test 'Shell byte progress renders hash bar at fifty percent' test_render_fifty_percent
run_test 'Shell byte progress clamps at one hundred percent' test_clamp_to_hundred
run_test 'download_with_retry works under nounset' test_download_with_retry_under_nounset
run_test 'main exits cleanly under nounset' test_main_exit_trap_under_nounset

printf '[PASS] All install progress shell tests passed.\n'
