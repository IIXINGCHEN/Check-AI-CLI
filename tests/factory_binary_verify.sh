#!/usr/bin/env bash
set -uo pipefail

# Regression coverage for shell-side Factory verified binary install (F1.1).
# Mirrors the PowerShell Install-FactoryFromBootstrap: on Windows shells the
# POSIX checker now downloads droid.exe and validates its SHA256 before
# install, instead of piping the official install script into sh unverified.

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

# shellcheck disable=SC1091
source "$ROOT_DIR/scripts/check-ai-cli-versions.sh"

test_is_windows_shell_detects_msys() {
  local rc
  (
    OSTYPE=msys
    is_windows_shell
  )
  rc=$?
  if [ "$rc" -ne 0 ]; then
    printf '[FAIL] Expected OSTYPE=msys to be detected as Windows shell.\n' >&2
    exit 1
  fi
}

test_is_windows_shell_detects_mingw_uname() {
  local rc
  (
    OSTYPE=""
    uname() { echo 'MINGW64_NT-10.0'; }
    is_windows_shell
  )
  rc=$?
  if [ "$rc" -ne 0 ]; then
    printf '[FAIL] Expected MINGW uname to be detected as Windows shell.\n' >&2
    exit 1
  fi
}

test_is_windows_shell_rejects_linux() {
  local rc
  (
    OSTYPE=linux-gnu
    uname() { echo 'Linux'; }
    is_windows_shell
  )
  rc=$?
  if [ "$rc" -eq 0 ]; then
    printf '[FAIL] Expected Linux to NOT be detected as Windows shell.\n' >&2
    exit 1
  fi
}

test_sha256_tool_exists_when_sha256sum_present() {
  local rc
  (
    command_exists() { [ "$1" = "sha256sum" ]; }
    sha256_tool_exists
  )
  rc=$?
  if [ "$rc" -ne 0 ]; then
    printf '[FAIL] Expected sha256_tool_exists to succeed when sha256sum is present.\n' >&2
    exit 1
  fi
}

test_sha256_tool_exists_when_only_shasum_present() {
  local rc
  (
    command_exists() { [ "$1" = "shasum" ]; }
    sha256_tool_exists
  )
  rc=$?
  if [ "$rc" -ne 0 ]; then
    printf '[FAIL] Expected sha256_tool_exists to succeed when only shasum is present.\n' >&2
    exit 1
  fi
}

test_sha256_tool_exists_fails_when_neither_present() {
  local rc
  (
    command_exists() { return 1; }
    sha256_tool_exists
  )
  rc=$?
  if [ "$rc" -eq 0 ]; then
    printf '[FAIL] Expected sha256_tool_exists to fail when neither tool is present.\n' >&2
    exit 1
  fi
}

# End-to-end: install_factory_binary_windows aborts on checksum mismatch.
test_install_factory_aborts_on_checksum_mismatch() {
  local rc
  (
    # Pretend we are on Windows so the binary path is exercised.
    OSTYPE=msys
    export OSTYPE

    # All command_exists checks succeed.
    command_exists() { return 0; }

    # fetch_text returns fake bootstrap metadata, then a wrong checksum.
    fetch_text() {
      case "$1" in
        *"/cli/windows") printf '$version = "9.9.9"\n$baseUrl = "https://downloads.test"\n' ;;
        *.sha256) printf 'deadbeef0000000000000000000000000000000000000000000000000000ffff' ;;
        *) return 1 ;;
      esac
    }

    # download_file writes a fake binary.
    download_file() { printf 'fake-binary-content' > "$2"; return 0; }

    # sha256_file returns a hash that does NOT match the fake .sha256 above.
    sha256_file() { printf 'aaaabbbbccccdddd000000000000000000000000000000000000000000000000'; }

    # Silence logs.
    log_info() { :; }
    log_warn() { :; }
    log_err() { :; }

    # mktemp stub - use a real temp dir (command builtin mkdir is mocked below).
    mktemp() { local d; d="$(command mktemp -d 2>/dev/null || echo "/tmp/factory-test-$$")"; command mkdir -p "$d" 2>/dev/null; printf '%s' "$d"; }

    mkdir() { return 0; }
    cp() { return 0; }
    rm() { return 0; }
    sleep() { return 0; }
    ensure_profile_path_prefers() { return 0; }
    repair_tool_path() { return 0; }

    install_factory_binary_windows
  )
  rc=$?
  if [ "$rc" -eq 0 ]; then
    printf '[FAIL] Expected install_factory_binary_windows to fail on checksum mismatch.\n' >&2
    exit 1
  fi
}

test_install_factory_uses_home_when_userprofile_unset() {
  local temp_root rc
  temp_root="$(mktemp -d)"
  (
    OSTYPE=msys
    export OSTYPE
    unset USERPROFILE
    HOME="$temp_root/home"
    export HOME

    command_exists() { return 0; }
    fetch_text() {
      case "$1" in
        *"/cli/windows") printf '$version = "9.9.9"\n$baseUrl = "https://downloads.test"\n' ;;
        *.sha256) printf 'aaaa' ;;
        *) return 1 ;;
      esac
    }
    download_file() { printf 'fake-binary-content' > "$2"; return 0; }
    sha256_file() { printf 'aaaa'; }
    log_info() { :; }
    log_warn() { :; }
    log_err() { :; }
    cp() { return 0; }
    sleep() { return 0; }
    ensure_profile_path_prefers() { return 0; }
    repair_tool_path() { return 0; }

    install_factory_binary_windows
  )
  rc=$?
  rm -rf "$temp_root"
  if [ "$rc" -ne 0 ]; then
    printf '[FAIL] Expected install_factory_binary_windows to fall back to HOME when USERPROFILE is unset.\n' >&2
    exit 1
  fi
}

run_test 'is_windows_shell detects MSYS OSTYPE' test_is_windows_shell_detects_msys
run_test 'is_windows_shell detects MINGW via uname' test_is_windows_shell_detects_mingw_uname
run_test 'is_windows_shell rejects Linux' test_is_windows_shell_rejects_linux
run_test 'sha256_tool_exists succeeds when sha256sum present' test_sha256_tool_exists_when_sha256sum_present
run_test 'sha256_tool_exists succeeds when only shasum present' test_sha256_tool_exists_when_only_shasum_present
run_test 'sha256_tool_exists fails when neither present' test_sha256_tool_exists_fails_when_neither_present
run_test 'install_factory_binary_windows aborts on checksum mismatch' test_install_factory_aborts_on_checksum_mismatch
run_test 'install_factory_binary_windows falls back to HOME without USERPROFILE' test_install_factory_uses_home_when_userprofile_unset

printf '[PASS] All Factory binary verification shell tests passed.\n'
