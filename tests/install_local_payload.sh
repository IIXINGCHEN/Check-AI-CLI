#!/usr/bin/env bash
set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export CHECK_AI_CLI_SKIP_MAIN=1
source "$ROOT_DIR/install.sh"

local_root="$(get_local_payload_root || true)"
[ -z "$local_root" ] || { printf '[FAIL] Git checkout was incorrectly treated as a release payload.\n' >&2; exit 1; }

printf '[PASS] Git checkout local payload guard passed.\n'
