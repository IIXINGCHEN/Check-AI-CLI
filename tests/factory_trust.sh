#!/usr/bin/env bash
set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/scripts/check-ai-cli-versions.sh"

assert_true() {
  "$@" || { printf '[FAIL] Expected command to succeed: %s\n' "$*" >&2; exit 1; }
}

assert_false() {
  if "$@"; then
    printf '[FAIL] Expected command to fail: %s\n' "$*" >&2
    exit 1
  fi
}

assert_true is_factory_download_base_url 'https://downloads.factory.ai'
assert_true is_factory_download_base_url 'https://app.factory.ai/releases'
assert_false is_factory_download_base_url 'http://downloads.factory.ai'
assert_false is_factory_download_base_url 'https://downloads.factory.ai.evil.test'
assert_false is_factory_download_base_url 'https://user:pass@downloads.factory.ai'
assert_false is_factory_download_base_url 'https://downloads.factory.ai?redirect=evil'
assert_false is_factory_download_base_url 'https://downloads.factory.ai/releases?redirect=evil'

target="$(select_release_target 'Fixture' 'official' '1.2.0' 'npm' '1.1.0')"
[ "$target" = '1.2.0' ] || { printf '[FAIL] Release target policy selected %s.\n' "$target" >&2; exit 1; }

printf '[PASS] Factory download URL trust checks passed.\n'
