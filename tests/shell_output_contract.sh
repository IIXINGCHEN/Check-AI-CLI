#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$REPO_ROOT/scripts/check-ai-cli-versions.sh"

assert_eq() {
  local actual="$1" expected="$2" message="$3"
  if [ "$actual" != "$expected" ]; then
    printf '[FAIL] %s\nExpected: %s\nActual: %s\n' "$message" "$expected" "$actual" >&2
    exit 1
  fi
}

assert_contains() {
  local actual="$1" expected="$2" message="$3"
  case "$actual" in
    *"$expected"*) ;;
    *)
      printf '[FAIL] %s\nExpected substring: %s\nActual: %s\n' "$message" "$expected" "$actual" >&2
      exit 1
      ;;
  esac
}

assert_not_contains() {
  local actual="$1" unexpected="$2" message="$3"
  case "$actual" in
    *"$unexpected"*)
      printf '[FAIL] %s\nUnexpected substring: %s\nActual: %s\n' "$message" "$unexpected" "$actual" >&2
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

test_select_best_npm_mirror_returns_url_only() {
  local registry
  registry="$(
    NPM_BEST_MIRROR=""
    NPM_REGISTRY_CANDIDATES=()
    NETWORK_REGION="global"
    test_url_ok() { [ "$1" = "$NPM_MIRROR_DEFAULT" ]; }
    select_best_npm_mirror
    printf '%s' "$NPM_BEST_MIRROR"
  )"
  assert_eq "$registry" 'https://registry.npmjs.org' 'Expected npm mirror cache to contain only the registry URL.'
}

test_registry_candidates_fail_over_between_global_and_china_sources() {
  local registries
  registries="$(
    NPM_BEST_MIRROR=""
    NPM_REGISTRY_CANDIDATES=()
    NETWORK_REGION="global"
    test_url_ok() { [ "$1" = "$NPM_MIRROR_TENCENT" ]; }
    select_best_npm_mirror
    registry_candidates
  )"
  assert_eq "$(printf '%s\n' "$registries" | head -n 1)" "$NPM_MIRROR_TENCENT" 'Expected a reachable China source when the official source is unavailable.'
  assert_contains "$registries" "$NPM_MIRROR_DEFAULT" 'Expected the official source to remain a retry candidate.'

  registries="$(
    NPM_BEST_MIRROR=""
    NPM_REGISTRY_CANDIDATES=()
    NETWORK_REGION="china"
    test_url_ok() { return 0; }
    select_best_npm_mirror
    registry_candidates
  )"
  assert_eq "$(printf '%s\n' "$registries" | head -n 1)" "$NPM_MIRROR_TAOBAO" 'Expected the preferred China source first in China mode.'
  assert_eq "$(printf '%s\n' "$registries" | tail -n 1)" "$NPM_MIRROR_DEFAULT" 'Expected the official source as the final China-mode fallback.'
}

test_fallback_metadata_uses_newest_reachable_mirror() {
  local version
  version="$(
    official_registry() { printf '%s' "$NPM_MIRROR_DEFAULT"; }
    select_best_npm_mirror() { :; }
    registry_candidates() {
      printf '%s\n' "$NPM_MIRROR_TAOBAO" "$NPM_MIRROR_TENCENT" "$NPM_MIRROR_HUAWEI" "$NPM_MIRROR_DEFAULT"
    }
    fetch_text() {
      case "$1" in
        *registry.npmjs.org*) return 1 ;;
        *registry.npmmirror.com*) printf '{"version":"0.1.4"}' ;;
        *mirrors.cloud.tencent.com*) printf '{"version":"1.0.5"}' ;;
        *repo.huaweicloud.com*) printf '{"version":"1.0.4"}' ;;
      esac
    }
    get_npm_latest_version '@xai-official/grok'
  )"
  assert_eq "$version" '1.0.5' 'Expected the newest reachable mirror metadata when the official source is unavailable.'
}

test_untrusted_mirror_resolution_returns_url_only() {
  local base
  base="$(
    CHECK_AI_CLI_SKIP_MAIN=1 \
    CHECK_AI_CLI_RAW_BASE='https://mirror.example/repo' \
    CHECK_AI_CLI_ALLOW_UNTRUSTED_MIRROR=1 \
    bash --noprofile --norc -c '
      source "$1"
      sleep() { :; }
      resolve_base
    ' _ "$REPO_ROOT/install.sh" 2>/dev/null
  )"
  assert_eq "$base" 'https://mirror.example/repo' 'Expected resolve_base stdout to contain only the resolved base URL.'
}

test_latest_stable_ref_rejects_non_semver_tag_names() {
  local tag
  # Note: assignment-from-substitution triggers errexit when the substitution
  # fails on bash 5.2+, so the inner script must exit 0; rejection is asserted
  # via empty output, not via the child exit code.
  tag="$(
    CHECK_AI_CLI_SKIP_MAIN=1 \
    bash --noprofile --norc -c '
      source "$1"
      get_latest_release_api_url() { printf "%s" "unused://fixture"; }
      fetch_text() { printf "%s" "{\"tag_name\":\"nightly-2026.09.07\"}"; }
      get_latest_stable_ref || true
    ' _ "$REPO_ROOT/install.sh" 2>/dev/null
  )"
  assert_eq "$tag" '' 'Expected a non-semver latest release tag to be rejected (fail closed to the main commit SHA).'

  tag="$(
    CHECK_AI_CLI_SKIP_MAIN=1 \
    bash --noprofile --norc -c '
      source "$1"
      get_latest_release_api_url() { printf "%s" "unused://fixture"; }
      fetch_text() { printf "%s" "{\"tag_name\":\"v1.4.0\"}"; }
      get_latest_stable_ref
    ' _ "$REPO_ROOT/install.sh" 2>/dev/null
  )"
  assert_eq "$tag" 'v1.4.0' 'Expected a semver latest release tag to pass through.'
}

test_lifecycle_propagates_update_failure() {
  local rc
  AUTO_MODE=1
  bad_update() { return 42; }
  get_latest_fix() { printf '1.2.3\n'; }
  get_local_fix() { printf '\n'; }

  set +e
  run_tool_lifecycle 'Fixture' get_latest_fix get_local_fix bad_update >/dev/null 2>&1
  rc=$?
  set -e

  assert_eq "$rc" '42' 'Expected install failure to propagate out of run_tool_lifecycle.'
}

test_main_returns_nonzero_for_selected_update_failure() {
  local rc

  set +e
  (
    AUTO_MODE=1
    require_fetch_tool() { return 0; }
    show_banner() { :; }
    detect_network() { NETWORK_REGION="global"; }
    select_best_npm_mirror() { NPM_BEST_MIRROR='https://registry.npmjs.org'; }
    ask_selection() { printf '2\n'; }
    get_latest_codex() { printf '2.0.0\n'; }
    get_local_codex() { printf '1.0.0\n'; }
    update_codex() { return 42; }
    main >/dev/null 2>&1
  )
  rc=$?
  set -e

  if [ "$rc" -eq 0 ]; then
    printf '[FAIL] Expected main to return non-zero when a selected update fails.\n' >&2
    exit 1
  fi
}

test_proxy_logs_hide_credentials() {
  local output
  output="$(
    HTTP_PROXY='http://user:secret@127.0.0.1:8080'
    HTTPS_PROXY=''
    ALL_PROXY=''
    CHECK_AI_CLI_REGION='global'
    test_url_ok() { return 1; }
    detect_network 2>&1
  )"

  assert_not_contains "$output" 'secret' 'Expected proxy logs to hide password text.'
  assert_contains "$output" 'http://***@127.0.0.1:8080' 'Expected proxy logs to keep a redacted proxy location.'
}

test_uninstaller_refuses_unmarked_directory() {
  local temp_root rc
  temp_root="$(mktemp -d)"
  set +e
  CHECK_AI_CLI_INSTALL_DIR="$temp_root" bash "$REPO_ROOT/uninstall.sh" </dev/null >/dev/null 2>&1
  rc=$?
  set -e
  rm -rf "$temp_root"
  if [ "$rc" -eq 0 ]; then
    printf '[FAIL] Expected the shell uninstaller to refuse an unmarked directory.\n' >&2
    exit 1
  fi
}

test_banner_is_npm_only_five_tools() {
  local text
  text="$(cat "$REPO_ROOT/scripts/check-ai-cli-versions.sh")"
  assert_contains "$text" 'npm-only' 'banner/docs mention npm-only'
  assert_contains "$text" 'Grok Build' 'includes Grok'
  assert_not_contains "$text" 'Factory CLI' 'Factory removed from checker'
  assert_not_contains "$text" 'app.factory.ai' 'no factory bootstrap URL'
  assert_not_contains "$text" 'brew install' 'no brew update channel'
  assert_not_contains "$text" 'Trying: claude update' 'no native claude updater path'
}

test_npm_install_uses_reviewed_script_approvals() {
  local output
  output="$(
    NPM_BEST_MIRROR='https://registry.npmjs.org'
    npm() { printf '%s\n' "$*"; }
    npm_install_global '@google/gemini-cli@0.57.0' 'https://registry.npmjs.org' '@github/keytar,node-pty'
  )"
  assert_eq "$output" 'install -g --allow-scripts=@github/keytar,node-pty @google/gemini-cli@0.57.0 --registry https://registry.npmjs.org' 'Expected a one-shot reviewed --allow-scripts policy.'
}

test_only_canonical_grok_layout_is_migratable() {
  local old_home="${HOME:-}" old_grok_home="${GROK_HOME:-}" canonical
  HOME='/tmp/check-ai-cli-grok-home'
  unset GROK_HOME
  canonical="$HOME/.grok/bin/grok"

  if ! is_grok_npm_migration_candidate 'grok' "$canonical"; then
    printf '[FAIL] Expected canonical Grok layout to be migratable.\n' >&2
    exit 1
  fi
  if is_grok_npm_migration_candidate 'grok' '/tmp/unrelated/grok'; then
    printf '[FAIL] Unknown external Grok path must remain blocked.\n' >&2
    exit 1
  fi
  if is_grok_npm_migration_candidate 'codex' "$canonical"; then
    printf '[FAIL] Migration exception must be Grok-only.\n' >&2
    exit 1
  fi

  HOME="$old_home"
  if [ -n "$old_grok_home" ]; then GROK_HOME="$old_grok_home"; else unset GROK_HOME; fi
}

test_canonical_grok_update_reaches_npm() {
  local temp_root rc install_calls
  temp_root="$(mktemp -d)"

  set +e
  (
    HOME="$temp_root"
    unset GROK_HOME
    mkdir -p "$HOME/.grok/bin"
    printf '#!/usr/bin/env bash\nexit 0\n' > "$HOME/.grok/bin/grok"
    chmod +x "$HOME/.grok/bin/grok"
    PATH="$HOME/.grok/bin:$PATH"
    NPM_BEST_MIRROR='https://registry.npmmirror.com'
    fixture_version='0.2.111'

    require_npm() { return 0; }
    get_local_tool_version() { printf '%s' "$fixture_version"; }
    npm() { [ "${1:-}" != 'list' ]; }
    get_npm_latest_version() { printf '1.0.5'; }
    select_best_npm_mirror() { :; }
    registry_candidates() {
      printf '%s\n' 'https://registry.npmmirror.com' 'https://mirrors.cloud.tencent.com/npm/' 'https://registry.npmjs.org'
    }
    official_registry() { printf 'https://registry.npmjs.org'; }
    # Keep the stale-mirror failover hermetic: the version probe would otherwise
    # hit the network for a fixture-only version.
    npm_registry_version_state() { printf 'present'; }
    npm_install_global() {
      printf '%s|%s|%s\n' "$1" "$2" "$3" >> "$temp_root/install-calls"
      if [ "$2" = 'https://registry.npmmirror.com' ]; then
        fixture_version='0.1.4'
      else
        fixture_version='1.0.5'
      fi
      return 0
    }
    repair_tool_path() { return 0; }

    update_tool_via_npm "${TOOL_DEFS[3]}"
  ) >/dev/null 2>&1
  rc=$?
  set -e

  install_calls="$(cat "$temp_root/install-calls" 2>/dev/null || true)"
  rm -rf "$temp_root"
  assert_eq "$rc" '0' 'Expected canonical Grok migration to complete through the npm updater.'
  assert_contains "$install_calls" '@xai-official/grok@1.0.5|https://registry.npmmirror.com|@xai-official/grok' 'Expected the stale preferred mirror to be attempted first.'
  assert_contains "$install_calls" '@xai-official/grok@1.0.5|https://mirrors.cloud.tencent.com/npm/|@xai-official/grok' 'Expected an unusable mirror result to fail over to the next reachable source.'
}

test_staging_cleanup_reclaims_only_npm_leftovers() {
  local root residue lookalike scoped_residue

  root="$(mktemp -d)"
  residue="$root/.opencode-ai-Ab12Cd34"
  lookalike="$root/.opencode-ai-backup"
  scoped_residue="$root/@anthropic-ai/.claude-code-QiOifoBj"
  mkdir -p "$residue/node_modules" "$lookalike/node_modules" "$scoped_residue/node_modules"

  # A staging leftover alone proves nothing: its live package directory is what
  # shows a newer install has already replaced it.
  assert_eq "$(npm_staging_dirs "$root" 'opencode-ai')" '' 'A staged leftover without its live sibling must not match'
  assert_eq "$(npm_staging_dirs "$root" '@anthropic-ai/claude-code')" '' 'A staged leftover without its live sibling must not match (scoped)'

  mkdir -p "$root/opencode-ai" "$root/@anthropic-ai/claude-code"
  assert_eq "$(npm_staging_dirs "$root" 'opencode-ai')" "$residue" 'Expected the unscoped staging leftover to match'
  assert_eq "$(npm_staging_dirs "$root" '@anthropic-ai/claude-code')" "$scoped_residue" 'Expected the scoped staging leftover to match'

  invoke_npm_staging_cleanup 'opencode|OpenCode|opencode-ai|opencode-ai@latest|opencode|opencode-ai' "$root" >/dev/null 2>&1
  assert_eq "$([ -e "$residue" ] && echo present || echo gone)" 'gone' 'Expected the matched staging leftover to be reclaimed'
  assert_eq "$([ -d "$lookalike" ] && echo present || echo gone)" 'present' 'A directory outside the npm staging shape must survive'
  assert_eq "$([ -d "$root/opencode-ai" ] && echo present || echo gone)" 'present' 'The live package directory must survive'

  rm -rf "$root"
}

test_lagging_mirror_is_skipped_without_an_install_attempt() {
  # A mirror that has not synced the authoritative pinned version can only make
  # npm abort with ETARGET. It must be skipped with an informational line — no
  # install attempt, no [WARNING] — while the next reachable source installs it.
  local temp_root rc install_calls log_text
  temp_root="$(mktemp -d)"

  set +e
  (
    HOME="$temp_root"
    unset GROK_HOME
    mkdir -p "$HOME/.grok/bin"
    printf '#!/usr/bin/env bash\nexit 0\n' > "$HOME/.grok/bin/grok"
    chmod +x "$HOME/.grok/bin/grok"
    PATH="$HOME/.grok/bin:$PATH"
    fixture_version='0.2.111'

    require_npm() { return 0; }
    get_local_tool_version() { printf '%s' "$fixture_version"; }
    npm() { [ "${1:-}" != 'list' ]; }
    get_npm_latest_version() { printf '1.0.34'; }
    select_best_npm_mirror() { :; }
    registry_candidates() {
      printf '%s\n' 'https://registry.npmmirror.com' 'https://repo.huaweicloud.com/repository/npm/' 'https://registry.npmjs.org'
    }
    official_registry() { printf 'https://registry.npmjs.org'; }
    npm_registry_version_state() {
      if [ "$3" = 'https://registry.npmmirror.com' ]; then printf 'absent'; else printf 'present'; fi
    }
    npm_install_global() {
      printf '%s|%s|%s\n' "$1" "$2" "$3" >> "$temp_root/install-calls"
      fixture_version='1.0.34'
      return 0
    }
    repair_tool_path() { return 0; }

    update_tool_via_npm "${TOOL_DEFS[3]}"
  ) >"$temp_root/log" 2>&1
  rc=$?
  set -e

  install_calls="$(cat "$temp_root/install-calls" 2>/dev/null || true)"
  log_text="$(cat "$temp_root/log" 2>/dev/null || true)"
  rm -rf "$temp_root"

  assert_eq "$rc" '0' 'Expected the update to succeed through the next source.'
  assert_not_contains "$install_calls" 'https://registry.npmmirror.com' 'A lagging mirror must not receive an install attempt.'
  assert_contains "$install_calls" '@xai-official/grok@1.0.34|https://repo.huaweicloud.com/repository/npm/|@xai-official/grok' 'Expected the pinned version to install from the next source.'
  assert_contains "$log_text" 'has not published v1.0.34 yet; skipping this source' 'Expected an informational skip line for mirror sync lag.'
  assert_not_contains "$log_text" '[WARNING]' 'Mirror sync lag must not be reported as a warning.'
}

run_test 'select_best_npm_mirror returns only the URL' test_select_best_npm_mirror_returns_url_only
run_test 'registry candidates fail over between global and China sources' test_registry_candidates_fail_over_between_global_and_china_sources
run_test 'fallback metadata uses newest reachable mirror' test_fallback_metadata_uses_newest_reachable_mirror
run_test 'install.sh resolve_base returns only the URL' test_untrusted_mirror_resolution_returns_url_only
run_test 'latest stable ref rejects non-semver tag names' test_latest_stable_ref_rejects_non_semver_tag_names
run_test 'run_tool_lifecycle propagates install failure' test_lifecycle_propagates_update_failure
run_test 'main returns non-zero for selected update failure' test_main_returns_nonzero_for_selected_update_failure
run_test 'proxy logs hide credentials' test_proxy_logs_hide_credentials
run_test 'uninstaller refuses unmarked directory' test_uninstaller_refuses_unmarked_directory
run_test 'banner is npm-only five tools' test_banner_is_npm_only_five_tools
run_test 'npm install uses reviewed script approvals' test_npm_install_uses_reviewed_script_approvals
run_test 'only canonical Grok layout is migratable' test_only_canonical_grok_layout_is_migratable
run_test 'canonical Grok update reaches npm' test_canonical_grok_update_reaches_npm
run_test 'lagging mirror is skipped without an install attempt' test_lagging_mirror_is_skipped_without_an_install_attempt
run_test 'staging cleanup reclaims only npm leftovers' test_staging_cleanup_reclaims_only_npm_leftovers
printf '[PASS] All shell output contract tests passed.\n'
