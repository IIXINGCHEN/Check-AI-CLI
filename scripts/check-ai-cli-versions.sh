#!/usr/bin/env bash
# npm-only AI CLI checker (POSIX):
#   @anthropic-ai/claude-code@latest
#   @openai/codex@latest
#   @google/gemini-cli@latest
#   @xai-official/grok@latest
#   opencode-ai@latest
# No Factory, remote install scripts, brew/scoop/choco, or native self-upgrade.
set -uo pipefail

AUTO_MODE="${CHECK_AI_CLI_AUTO:-0}"
if [ "${1:-}" = "--yes" ] || [ "${1:-}" = "-y" ]; then
  AUTO_MODE="1"
fi

COLOR_INFO='\033[36m'
COLOR_OK='\033[32m'
COLOR_WARN='\033[33m'
COLOR_ERR='\033[31m'
COLOR_RESET='\033[0m'

log_info() { echo -e "${COLOR_INFO}[INFO] $*${COLOR_RESET}" >&2; }
log_ok() { echo -e "${COLOR_OK}[SUCCESS] $*${COLOR_RESET}" >&2; }
log_warn() { echo -e "${COLOR_WARN}[WARNING] $*${COLOR_RESET}" >&2; }
log_err() { echo -e "${COLOR_ERR}[ERROR] $*${COLOR_RESET}" >&2; }

log_safe_proxy_url() {
  printf '%s' "${1:-}" | sed -E 's#^([A-Za-z][A-Za-z0-9+.-]*://)[^/@[:space:]]+@#\1***@#'
}

command_exists() { command -v "$1" >/dev/null 2>&1; }

require_fetch_tool() {
  if command_exists curl || command_exists wget; then return 0; fi
  log_err "curl/wget not found. Install curl or wget first."
  return 1
}

require_npm() {
  if command_exists npm; then return 0; fi
  log_err "npm not found. Install Node.js first. This checker only supports: npm i -g <package>@latest"
  return 1
}

# Tool registry: id|title|package|spec|commands(comma)|allowed install scripts(comma)
TOOL_DEFS=(
  "claude|Claude Code|@anthropic-ai/claude-code|@anthropic-ai/claude-code@latest|claude,claude-code|@anthropic-ai/claude-code"
  "codex|OpenAI Codex|@openai/codex|@openai/codex@latest|codex|"
  "gemini|Gemini CLI|@google/gemini-cli|@google/gemini-cli@latest|gemini|@github/keytar,node-pty"
  "grok|Grok Build|@xai-official/grok|@xai-official/grok@latest|grok|@xai-official/grok"
  "opencode|OpenCode|opencode-ai|opencode-ai@latest|opencode|opencode-ai"
)

tool_field() {
  # $1=def $2=field index 1-based
  printf '%s' "$1" | cut -d'|' -f"$2"
}

# ---------------------------------------------------------------------------
# Network / npm mirror
# ---------------------------------------------------------------------------

NPM_MIRROR_TAOBAO="https://registry.npmmirror.com"
NPM_MIRROR_TENCENT="https://mirrors.cloud.tencent.com/npm/"
NPM_MIRROR_HUAWEI="https://repo.huaweicloud.com/repository/npm/"
NPM_MIRROR_DEFAULT="https://registry.npmjs.org"
NPM_BEST_MIRROR=""
NPM_REGISTRY_CANDIDATES=()
NETWORK_REGION=""

get_env_proxy() {
  printf '%s' "${HTTPS_PROXY:-${https_proxy:-${HTTP_PROXY:-${http_proxy:-${ALL_PROXY:-${all_proxy:-}}}}}}"
}

test_url_ok() {
  local url="$1" timeout="${2:-5}"
  if command_exists curl; then
    curl -fsSL --connect-timeout "$timeout" --max-time "$timeout" "$url" >/dev/null 2>&1 && return 0
  elif command_exists wget; then
    wget -q --timeout="$timeout" -O /dev/null "$url" 2>/dev/null && return 0
  fi
  return 1
}

detect_network() {
  log_info "Detecting network environment..."
  local env_proxy
  env_proxy="$(get_env_proxy)"
  if [ -n "$env_proxy" ]; then
    log_info "Environment proxy detected: $(log_safe_proxy_url "$env_proxy")"
  else
    log_info "No proxy configured (direct connection)"
  fi

  local region_override="${CHECK_AI_CLI_REGION:-}"
  if [ -n "$region_override" ]; then
    case "$(echo "$region_override" | tr '[:upper:]' '[:lower:]')" in
      china|cn) NETWORK_REGION="china"; log_info "Region override: China"; return 0 ;;
      global|intl) NETWORK_REGION="global"; log_info "Region override: Global"; return 0 ;;
    esac
  fi

  log_info "Testing connectivity to determine best npm source..."
  local npmjs_ok=0 mirror_ok=0
  test_url_ok "$NPM_MIRROR_DEFAULT" 5 && npmjs_ok=1
  test_url_ok "$NPM_MIRROR_TAOBAO" 5 && mirror_ok=1

  if [ "$mirror_ok" -eq 1 ] && [ "$npmjs_ok" -eq 0 ]; then
    NETWORK_REGION="china"
  elif [ "$npmjs_ok" -eq 1 ] && [ "$mirror_ok" -eq 0 ]; then
    NETWORK_REGION="global"
  elif [ "$mirror_ok" -eq 1 ]; then
    # Prefer china mirror when both work and region not forced — heuristic: baidu faster path
    if test_url_ok "https://www.baidu.com" 3 && ! test_url_ok "https://www.google.com/generate_204" 3; then
      NETWORK_REGION="china"
    else
      NETWORK_REGION="global"
    fi
  else
    NETWORK_REGION="unknown"
  fi
  log_info "Effective region for npm: $NETWORK_REGION"
}

append_registry_candidate() {
  local candidate="$1" existing
  # ${arr[@]+...} guard: expanding an empty array is a fatal unbound-variable
  # error under set -u on bash 3.2-4.3 (e.g. macOS stock /usr/bin/bash).
  for existing in ${NPM_REGISTRY_CANDIDATES[@]+"${NPM_REGISTRY_CANDIDATES[@]}"}; do
    [ "$existing" = "$candidate" ] && return 0
  done
  NPM_REGISTRY_CANDIDATES+=("$candidate")
}

build_registry_candidates() {
  local url
  local preferred=() secondary=()
  NPM_REGISTRY_CANDIDATES=()
  if [ -z "$NETWORK_REGION" ]; then detect_network; fi

  if [ "$NETWORK_REGION" = 'china' ]; then
    preferred=("$NPM_MIRROR_TAOBAO" "$NPM_MIRROR_TENCENT" "$NPM_MIRROR_HUAWEI")
    secondary=("$NPM_MIRROR_DEFAULT")
  else
    preferred=("$NPM_MIRROR_DEFAULT")
    secondary=("$NPM_MIRROR_TAOBAO" "$NPM_MIRROR_TENCENT" "$NPM_MIRROR_HUAWEI")
  fi

  for url in "${preferred[@]}" "${secondary[@]}"; do
    test_url_ok "$url" 4 && append_registry_candidate "$url"
  done
  for url in "${preferred[@]}" "${secondary[@]}"; do
    append_registry_candidate "$url"
  done

  NPM_BEST_MIRROR="${NPM_REGISTRY_CANDIDATES[0]}"
  case "$NPM_BEST_MIRROR" in
    "$NPM_MIRROR_DEFAULT") log_info "Using official npm registry" ;;
    "$NPM_MIRROR_TAOBAO") log_info "Using China npm mirror: npmmirror (taobao)" ;;
    "$NPM_MIRROR_TENCENT") log_info "Using China npm mirror: tencent" ;;
    "$NPM_MIRROR_HUAWEI") log_info "Using China npm mirror: huawei" ;;
  esac
}

select_best_npm_mirror() {
  [ -n "$NPM_BEST_MIRROR" ] && [ "${#NPM_REGISTRY_CANDIDATES[@]}" -gt 0 ] && return 0
  build_registry_candidates
}

get_best_npm_mirror() {
  select_best_npm_mirror
  printf '%s' "$NPM_BEST_MIRROR"
}

registry_candidates() {
  select_best_npm_mirror
  printf '%s\n' ${NPM_REGISTRY_CANDIDATES[@]+"${NPM_REGISTRY_CANDIDATES[@]}"}
}

official_registry() { printf '%s' "$NPM_MIRROR_DEFAULT"; }

# ---------------------------------------------------------------------------
# fetch / semver
# ---------------------------------------------------------------------------

fetch_text() {
  local url="$1"
  if command_exists curl; then
    curl -fsSL "$url" 2>/dev/null || return 1
    return 0
  fi
  if command_exists wget; then
    wget -qO- "$url" 2>/dev/null || return 1
    return 0
  fi
  return 1
}

extract_semver() {
  echo "$*" | grep -Eo '(^|[^0-9.])([0-9]+\.[0-9]+\.[0-9]+)([^0-9.]|$)' | head -n 1 | grep -Eo '[0-9]+\.[0-9]+\.[0-9]+' | head -n 1
}

extract_prerelease_tag() {
  echo "$*" | grep -Eo '(^|[^0-9.])[0-9]+\.[0-9]+\.[0-9]+-[0-9A-Za-z.-]+' | head -n 1 | sed -E 's/.*[0-9]+\.[0-9]+\.[0-9]+-//'
}

is_prerelease() {
  [ -n "$(extract_prerelease_tag "$*")" ]
}

# semver 11.4: dot-separated identifiers compare numerically when both are
# numeric, numeric identifiers always rank lower than alphanumeric ones, and
# the remaining identifiers compare in ASCII sort order.
prerelease_identifier_cmp() {
  local a="$1" b="$2" a_num=0 b_num=0 first
  [[ "$a" =~ ^[0-9]+$ ]] && a_num=1
  [[ "$b" =~ ^[0-9]+$ ]] && b_num=1
  if [ "$a_num" -eq 1 ] && [ "$b_num" -eq 1 ]; then
    if [ $((10#$a)) -lt $((10#$b)) ]; then echo -1; return 0; fi
    if [ $((10#$a)) -gt $((10#$b)) ]; then echo 1; return 0; fi
    echo 0
    return 0
  fi
  if [ "$a_num" -ne "$b_num" ]; then
    if [ "$a_num" -eq 1 ]; then echo -1; else echo 1; fi
    return 0
  fi
  if [ "$a" = "$b" ]; then echo 0; return 0; fi
  first="$(printf '%s\n%s\n' "$a" "$b" | LC_ALL=C sort | head -n 1)"
  [ "$first" = "$a" ] && echo -1 || echo 1
}

compare_prerelease_tag() {
  local a_ids=() b_ids=() i len cmp
  IFS='.' read -r -a a_ids <<< "$1"
  IFS='.' read -r -a b_ids <<< "$2"
  len=$(( ${#a_ids[@]} > ${#b_ids[@]} ? ${#a_ids[@]} : ${#b_ids[@]} ))
  for ((i = 0; i < len; i++)); do
    if [ "$i" -ge "${#a_ids[@]}" ]; then echo -1; return 0; fi
    if [ "$i" -ge "${#b_ids[@]}" ]; then echo 1; return 0; fi
    cmp="$(prerelease_identifier_cmp "${a_ids[$i]}" "${b_ids[$i]}")"
    if [ "$cmp" != "0" ]; then echo "$cmp"; return 0; fi
  done
  echo 0
}

compare_semver() {
  local a b a1 a2 a3 b1 b2 b3 tag_a tag_b
  a="$(extract_semver "$1")"
  b="$(extract_semver "$2")"
  [ -n "$a" ] || return 1
  [ -n "$b" ] || return 1
  IFS='.' read -r a1 a2 a3 <<< "$a"
  IFS='.' read -r b1 b2 b3 <<< "$b"
  if [ "$a1" -ne "$b1" ]; then [ "$a1" -lt "$b1" ] && echo -1 || echo 1; return 0; fi
  if [ "$a2" -ne "$b2" ]; then [ "$a2" -lt "$b2" ] && echo -1 || echo 1; return 0; fi
  if [ "$a3" -ne "$b3" ]; then [ "$a3" -lt "$b3" ] && echo -1 || echo 1; return 0; fi
  tag_a="$(extract_prerelease_tag "$1")"
  tag_b="$(extract_prerelease_tag "$2")"
  if [ -n "$tag_a" ] && [ -z "$tag_b" ]; then echo -1; return 0; fi
  if [ -z "$tag_a" ] && [ -n "$tag_b" ]; then echo 1; return 0; fi
  if [ -n "$tag_a" ] && [ -n "$tag_b" ]; then
    if [ "$tag_a" = "$tag_b" ]; then echo 0; return 0; fi
    compare_prerelease_tag "$tag_a" "$tag_b"
    return 0
  fi
  echo 0
}

# ---------------------------------------------------------------------------
# PATH / local version
# ---------------------------------------------------------------------------

normalize_dir() {
  local d="${1:-}"
  [ -n "$d" ] || return 1
  (cd "$d" 2>/dev/null && pwd) || printf '%s' "$d"
}

get_npm_global_bin_dir() {
  local prefix bin
  command_exists npm || return 1
  prefix="$(npm config get prefix 2>/dev/null || true)"
  [ -n "$prefix" ] || return 1
  if [ -d "$prefix/bin" ]; then
    normalize_dir "$prefix/bin"
    return 0
  fi
  normalize_dir "$prefix"
}

path_contains_dir() {
  local path_value="$1" dir="$2" p target
  target="$(normalize_dir "$dir" 2>/dev/null || true)"
  [ -n "$target" ] || return 1
  IFS=':' read -r -a parts <<< "$path_value"
  for p in "${parts[@]}"; do
    [ -n "$p" ] || continue
    if [ "$(normalize_dir "$p" 2>/dev/null || true)" = "$target" ]; then return 0; fi
  done
  return 1
}

remove_path_entry() {
  local path_value="$1" dir="$2" p target out=""
  target="$(normalize_dir "$dir" 2>/dev/null || true)"
  IFS=':' read -r -a parts <<< "$path_value"
  for p in "${parts[@]}"; do
    [ -n "$p" ] || continue
    if [ -n "$target" ] && [ "$(normalize_dir "$p" 2>/dev/null || true)" = "$target" ]; then continue; fi
    if [ -z "$out" ]; then out="$p"; else out="$out:$p"; fi
  done
  printf '%s' "$out"
}

prepend_path_entry() {
  local path_value="$1" dir="$2" clean
  clean="$(remove_path_entry "$path_value" "$dir")"
  dir="$(normalize_dir "$dir" 2>/dev/null || printf '%s' "$dir")"
  if [ -z "$clean" ]; then printf '%s' "$dir"; else printf '%s:%s' "$dir" "$clean"; fi
}

get_profile_file() {
  if [ -n "${ZSH_VERSION:-}" ] && [ -f "$HOME/.zshrc" ]; then printf '%s' "$HOME/.zshrc"; return; fi
  if [ -f "$HOME/.bashrc" ]; then printf '%s' "$HOME/.bashrc"; return; fi
  if [ -f "$HOME/.bash_profile" ]; then printf '%s' "$HOME/.bash_profile"; return; fi
  if [ -f "$HOME/.profile" ]; then printf '%s' "$HOME/.profile"; return; fi
  printf '%s' "$HOME/.profile"
}

get_path_marker() {
  printf '# check-ai-cli npm bin prefer: %s' "$1"
}

ensure_profile_path_prefers() {
  local dir="$1" profile marker line
  [ -d "$dir" ] || return 1
  dir="$(normalize_dir "$dir")"
  profile="$(get_profile_file)"
  marker="$(get_path_marker "$dir")"
  line="export PATH=\"$dir:\$PATH\"  $marker"
  if [ -f "$profile" ] && grep -F "$marker" "$profile" >/dev/null 2>&1; then
    :
  else
    printf '\n%s\n' "$line" >> "$profile"
    log_info "Updated your PATH permanently to prefer npm global bin ($profile)"
  fi
  export PATH="$(prepend_path_entry "${PATH:-}" "$dir")"
}

repair_tool_path() {
  local npm_bin
  npm_bin="$(get_npm_global_bin_dir || true)"
  if [ -n "$npm_bin" ]; then
    ensure_profile_path_prefers "$npm_bin" 2>/dev/null || export PATH="$(prepend_path_entry "${PATH:-}" "$npm_bin")"
  fi
  return 0
}

get_local_version_cmd() {
  local cmd ver
  for cmd in "$@"; do
    if command_exists "$cmd"; then
      ver="$(extract_semver "$("$cmd" --version 2>&1 || true)")"
      if [ -z "$ver" ]; then
        ver="$(extract_semver "$("$cmd" -v 2>&1 || true)")"
      fi
      if [ -n "$ver" ]; then
        printf '%s' "$ver"
        return 0
      fi
    fi
  done
  return 1
}

get_local_tool_version() {
  local def="$1" cmds
  repair_tool_path >/dev/null 2>&1 || true
  cmds="$(tool_field "$def" 5)"
  IFS=',' read -r -a arr <<< "$cmds"
  get_local_version_cmd "${arr[@]}" || true
}

# ---------------------------------------------------------------------------
# npm latest / install
# ---------------------------------------------------------------------------

npm_registry_latest_url() {
  local registry="$1" package="$2" base encoded
  base="${registry%/}"
  if [[ "$package" == @*/* ]]; then
    # @scope/name -> @scope%2Fname
    encoded="$(printf '%s' "$package" | sed 's#/#%2F#')"
    printf '%s/%s/latest' "$base" "$encoded"
  else
    printf '%s/%s/latest' "$base" "$package"
  fi
}

get_npm_latest_version() {
  local package="$1" reg url text ver official fallback_ver="" fallback_reg="" cmp
  local registries=()
  select_best_npm_mirror
  official="$(official_registry)"
  # npmjs.org is authoritative for dist-tags. Mirrors are fallback metadata
  # only; stale mirror data must never suppress a real update.
  url="$(npm_registry_latest_url "$official" "$package")"
  text="$(fetch_text "$url" || true)"
  if [ -n "$text" ]; then
    ver="$(printf '%s' "$text" | sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1)"
    ver="$(extract_semver "$ver")"
    if [ -n "$ver" ]; then printf '%s' "$ver"; return 0; fi
  fi

  while IFS= read -r reg; do
    [ -n "$reg" ] && registries+=("$reg")
  done < <(registry_candidates)
  for reg in ${registries[@]+"${registries[@]}"}; do
    [ "${reg%/}" = "${official%/}" ] && continue
    url="$(npm_registry_latest_url "$reg" "$package")"
    text="$(fetch_text "$url" || true)"
    [ -n "$text" ] || continue
    ver="$(printf '%s' "$text" | sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1)"
    ver="$(extract_semver "$ver")"
    [ -n "$ver" ] || continue
    if [ -z "$fallback_ver" ]; then
      fallback_ver="$ver"
      fallback_reg="$reg"
    else
      cmp="$(compare_semver "$fallback_ver" "$ver" || true)"
      if [ "$cmp" = '-1' ]; then fallback_ver="$ver"; fallback_reg="$reg"; fi
    fi
  done
  if [ -n "$fallback_ver" ]; then
    log_warn "Official npm registry unavailable; using newest fallback metadata v$fallback_ver from $fallback_reg"
    printf '%s' "$fallback_ver"
    return 0
  fi
  return 1
}

npm_install_global() {
  local spec="$1" registry="${2:-}" allow_scripts="${3:-}"
  if [ -z "$registry" ]; then
    select_best_npm_mirror
    registry="$NPM_BEST_MIRROR"
  fi
  if [ -n "$allow_scripts" ]; then
    npm install -g "--allow-scripts=$allow_scripts" "$spec" --registry "$registry"
  else
    npm install -g "$spec" --registry "$registry"
  fi
}

grok_npm_canonical_path() {
  local grok_home="${GROK_HOME:-}"
  if [ -z "$grok_home" ]; then
    [ -n "${HOME:-}" ] || return 1
    grok_home="${HOME%/}/.grok"
  fi
  printf '%s/bin/grok' "${grok_home%/}"
}

is_grok_npm_migration_candidate() {
  local id="$1" source="$2" canonical
  [ "$id" = 'grok' ] || return 1
  [ -n "$source" ] || return 1
  canonical="$(grok_npm_canonical_path || true)"
  [ -n "$canonical" ] || return 1
  [ "$source" = "$canonical" ] || [ "$source" = "${canonical}.exe" ]
}

update_tool_via_npm() {
  local def="$1"
  local id title package spec cmds allow_scripts target install_spec reg installed=0 last_err="" localv cmp command_path
  local registries=()
  id="$(tool_field "$def" 1)"
  title="$(tool_field "$def" 2)"
  package="$(tool_field "$def" 3)"
  spec="$(tool_field "$def" 4)"
  cmds="$(tool_field "$def" 5)"
  allow_scripts="$(tool_field "$def" 6)"

  log_info "Updating $title..."
  require_npm || return 1

  localv="$(get_local_tool_version "$def" || true)"
  if [ -n "$localv" ] && ! npm list -g --depth=0 "$package" >/dev/null 2>&1; then
    command_path=""
    IFS=',' read -r -a command_arr <<< "$cmds"
    for command_name in "${command_arr[@]}"; do
      if command_exists "$command_name"; then command_path="$(command -v "$command_name")"; break; fi
    done
    if is_grok_npm_migration_candidate "$id" "$command_path"; then
      log_info "Detected the canonical Grok installer layout. The official npm package will migrate this binary in place."
    else
      log_err "$title is installed outside npm at ${command_path:-unknown path}. Automatic npm update was blocked to avoid a conflicting installation. To manage via this tool, move the external command out of PATH and run: npm install -g $spec"
      return 1
    fi
  fi

  target="$(get_npm_latest_version "$package" || true)"
  install_spec="$spec"
  if [ -n "$target" ]; then
    # Pin the authoritative version so a stale mirror fails and falls back.
    install_spec="${package}@${target}"
  fi
  select_best_npm_mirror
  while IFS= read -r reg; do
    [ -n "$reg" ] && registries+=("$reg")
  done < <(registry_candidates)

  for reg in ${registries[@]+"${registries[@]}"}; do
    log_info "Trying: npm install ($reg)"
    if npm_install_global "$install_spec" "$reg" "$allow_scripts"; then
      repair_tool_path >/dev/null 2>&1 || true
      localv="$(get_local_tool_version "$def" || true)"
      if [ -z "$localv" ]; then
        last_err="installed command is not runnable via $reg"
        log_warn "$last_err; trying next source"
        continue
      fi
      if [ -n "$target" ]; then
        cmp="$(compare_semver "$localv" "$target" || true)"
        if [ "$cmp" != '0' ]; then
          last_err="installed v$localv via $reg, expected v$target"
          log_warn "$last_err; trying next source"
          continue
        fi
      fi
      installed=1
      break
    else
      last_err="npm install failed via $reg"
      log_warn "$last_err"
    fi
  done

  if [ "$installed" -ne 1 ]; then
    log_err "npm install failed for $install_spec. $last_err"
    return 1
  fi

  if [ -z "$localv" ]; then
    log_err "$title installed but local version could not be verified."
    return 1
  fi

  if [ -n "$target" ]; then
    cmp="$(compare_semver "$localv" "$target" || true)"
    if [ "$cmp" = "-1" ]; then
      log_err "$title installed v$localv but target is v$target"
      return 1
    fi
  fi
  return 0
}

# ---------------------------------------------------------------------------
# Lifecycle / UI
# ---------------------------------------------------------------------------

confirm_yes() {
  local prompt="$1" ans
  if [ "$AUTO_MODE" = "1" ]; then return 0; fi
  read -r -p "$prompt" ans || true
  case "$(echo "${ans:-}" | tr '[:lower:]' '[:upper:]')" in
    Y|YES) return 0 ;;
    *) return 1 ;;
  esac
}

run_tool_lifecycle() {
  local title="$1" get_latest="$2" get_local="$3" do_update="$4"
  local latest localv cmp did_update=0

  echo ""
  echo "$title"
  echo "$(printf '%*s' "${#title}" '' | tr ' ' '=')"

  log_info "Fetching latest version..."
  latest="$($get_latest || true)"
  if [ -n "$latest" ]; then log_ok "Latest version: v$latest"; else log_warn "Latest version: unknown"; fi

  localv="$($get_local || true)"
  if [ -n "$localv" ]; then log_ok "Local version: v$localv"; else log_warn "Local version: not installed"; fi

  if [ -z "$localv" ]; then
    if [ -z "$latest" ]; then log_warn "Latest version unknown. Installing anyway."; fi
    if confirm_yes "Install now? (Y/N): "; then
      local update_rc=0
      $do_update || update_rc=$?
      if [ "$update_rc" -ne 0 ]; then return "$update_rc"; fi
      did_update=1
    else
      return 0
    fi
  elif [ -z "$latest" ]; then
    log_warn "Latest version unknown. Skipping update check."
    return 0
  else
    cmp="$(compare_semver "$localv" "$latest" || true)"
    if [ "$cmp" = "0" ]; then
      log_ok "Already up to date."
      return 0
    elif [ "$cmp" = "1" ]; then
      log_warn "Local version is newer than latest source."
      return 0
    elif [ "$cmp" = "-1" ]; then
      if confirm_yes "Update now? (Y/N): "; then
        local update_rc=0
        $do_update || update_rc=$?
        if [ "$update_rc" -ne 0 ]; then return "$update_rc"; fi
        did_update=1
      else
        return 0
      fi
    fi
  fi

  if [ "$did_update" -eq 1 ]; then
    log_info "Re-checking local version..."
    localv="$($get_local || true)"
    if [ -n "$localv" ]; then log_ok "Local version: v$localv"; else log_warn "Local version: not installed"; return 1; fi
    if [ -n "$latest" ]; then
      cmp="$(compare_semver "$localv" "$latest" || true)"
      if [ "$cmp" = "-1" ]; then
        log_warn "Update may have failed (still older than latest)."
        log_warn "Tip: npm i -g <package>@latest --registry https://registry.npmjs.org"
        return 1
      fi
    fi
  fi
  return 0
}

# Per-tool wrappers for lifecycle function names
get_latest_claude() { get_npm_latest_version '@anthropic-ai/claude-code'; }
get_local_claude() { get_local_tool_version "${TOOL_DEFS[0]}"; }
update_claude() { update_tool_via_npm "${TOOL_DEFS[0]}"; }

get_latest_codex() { get_npm_latest_version '@openai/codex'; }
get_local_codex() { get_local_tool_version "${TOOL_DEFS[1]}"; }
update_codex() { update_tool_via_npm "${TOOL_DEFS[1]}"; }

get_latest_gemini() { get_npm_latest_version '@google/gemini-cli'; }
get_local_gemini() { get_local_tool_version "${TOOL_DEFS[2]}"; }
update_gemini() { update_tool_via_npm "${TOOL_DEFS[2]}"; }

get_latest_grok() { get_npm_latest_version '@xai-official/grok'; }
get_local_grok() { get_local_tool_version "${TOOL_DEFS[3]}"; }
update_grok() { update_tool_via_npm "${TOOL_DEFS[3]}"; }

get_latest_opencode() { get_npm_latest_version 'opencode-ai'; }
get_local_opencode() { get_local_tool_version "${TOOL_DEFS[4]}"; }
update_opencode() { update_tool_via_npm "${TOOL_DEFS[4]}"; }

check_tool() {
  run_tool_lifecycle "$@"
}

show_banner() {
  echo ""
  echo "==============================================="
  echo " AI CLI Version Checker (npm-only)"
  echo " Claude Code | OpenAI Codex | Gemini CLI | Grok Build | OpenCode"
  echo "==============================================="
  echo ""
}

ask_selection() {
  echo "Select tools to check:"
  echo "  [1] Claude Code"
  echo "  [2] OpenAI Codex"
  echo "  [3] Gemini CLI"
  echo "  [4] Grok Build"
  echo "  [5] OpenCode"
  echo "  [A] Check all (default)"
  echo "  [U] Check all and Update all (auto-yes)"
  echo "  [Q] Quit"
  local choice
  read -r -p "Enter choice (1-5/A/U/Q): " choice || true
  echo "${choice:-A}" | tr '[:lower:]' '[:upper:]'
}

main() {
  local sel status=0
  require_fetch_tool || exit 1
  show_banner
  detect_network
  select_best_npm_mirror
  sel="$(ask_selection)"
  if [ "$sel" = "Q" ]; then exit 0; fi
  if [ "$sel" = "U" ]; then AUTO_MODE="1"; fi

  if [ "$sel" = "1" ] || [ "$sel" = "A" ] || [ "$sel" = "U" ]; then
    check_tool "Claude Code" get_latest_claude get_local_claude update_claude || status=$?
  fi
  if [ "$sel" = "2" ] || [ "$sel" = "A" ] || [ "$sel" = "U" ]; then
    check_tool "OpenAI Codex" get_latest_codex get_local_codex update_codex || status=$?
  fi
  if [ "$sel" = "3" ] || [ "$sel" = "A" ] || [ "$sel" = "U" ]; then
    check_tool "Gemini CLI" get_latest_gemini get_local_gemini update_gemini || status=$?
  fi
  if [ "$sel" = "4" ] || [ "$sel" = "A" ] || [ "$sel" = "U" ]; then
    check_tool "Grok Build" get_latest_grok get_local_grok update_grok || status=$?
  fi
  if [ "$sel" = "5" ] || [ "$sel" = "A" ] || [ "$sel" = "U" ]; then
    check_tool "OpenCode" get_latest_opencode get_local_opencode update_opencode || status=$?
  fi
  return "$status"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
fi
