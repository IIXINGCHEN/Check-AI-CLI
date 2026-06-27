#!/usr/bin/env bash
# -u: treat unset variables as errors
# -o pipefail: a pipeline fails if any command fails (guards "fetch_text url | bash")
set -uo pipefail

# Auto mode: install if missing, update if outdated, no Y/N prompts
AUTO_MODE="${CHECK_AI_CLI_AUTO:-0}"
if [ "${1:-}" = "--yes" ] || [ "${1:-}" = "-y" ]; then
  AUTO_MODE="1"
fi

OPENCODE_TARGET_VERSION="${CHECK_AI_CLI_OPENCODE_VERSION:-}"

# Colored output (no external deps)
COLOR_INFO='\033[36m'
COLOR_OK='\033[32m'
COLOR_WARN='\033[33m'
COLOR_ERR='\033[31m'
COLOR_RESET='\033[0m'

log_info() { echo -e "${COLOR_INFO}[INFO] $*${COLOR_RESET}"; }
log_ok() { echo -e "${COLOR_OK}[SUCCESS] $*${COLOR_RESET}"; }
log_warn() { echo -e "${COLOR_WARN}[WARNING] $*${COLOR_RESET}"; }
log_err() { echo -e "${COLOR_ERR}[ERROR] $*${COLOR_RESET}"; }

# Check if command exists
command_exists() { command -v "$1" >/dev/null 2>&1; }

require_fetch_tool() {
  if command_exists curl || command_exists wget; then return 0; fi
  log_err "curl/wget not found. Install curl or wget first."
  return 1
}

# ============================================================================
# Network Detection & npm Registry Management
# ============================================================================

# npm mirrors
NPM_MIRROR_TAOBAO="https://registry.npmmirror.com"
NPM_MIRROR_TENCENT="https://mirrors.cloud.tencent.com/npm/"
NPM_MIRROR_HUAWEI="https://repo.huaweicloud.com/repository/npm/"
NPM_MIRROR_DEFAULT="https://registry.npmjs.org"

# Network detection cache
NETWORK_PROXY_MODE=""
NETWORK_REGION=""
NPM_BEST_MIRROR=""

# Test URL with timing (returns time in ms or -1 on failure)
test_url_timing() {
  local url="$1" timeout="${2:-5}"
  local start end elapsed
  
  if command_exists curl; then
    start=$(date +%s%3N 2>/dev/null || date +%s)
    if curl -fsSL --connect-timeout "$timeout" --max-time "$timeout" "$url" >/dev/null 2>&1; then
      end=$(date +%s%3N 2>/dev/null || date +%s)
      elapsed=$((end - start))
      echo "$elapsed"
      return 0
    fi
  elif command_exists wget; then
    start=$(date +%s%3N 2>/dev/null || date +%s)
    if wget -q --timeout="$timeout" -O /dev/null "$url" 2>/dev/null; then
      end=$(date +%s%3N 2>/dev/null || date +%s)
      elapsed=$((end - start))
      echo "$elapsed"
      return 0
    fi
  fi
  echo "-1"
  return 1
}

# Check environment proxy settings
get_env_proxy() {
  local proxy=""
  proxy="${HTTPS_PROXY:-${https_proxy:-${HTTP_PROXY:-${http_proxy:-${ALL_PROXY:-${all_proxy:-}}}}}}"
  echo "$proxy"
}

# Detect network environment
detect_network_environment() {
  # Return cached result
  if [ -n "$NETWORK_PROXY_MODE" ]; then return 0; fi
  
  log_info "Detecting network environment..."
  
  # Check for proxy
  local env_proxy has_proxy
  env_proxy="$(get_env_proxy)"
  has_proxy="no"
  
  if [ -n "$env_proxy" ]; then
    has_proxy="yes"
    log_info "Environment proxy detected: $env_proxy"
  else
    log_info "No proxy configured (direct connection)"
  fi
  
  # User override
  local region_override="${CHECK_AI_CLI_REGION:-}"
  if [ -n "$region_override" ]; then
    case "$(echo "$region_override" | tr '[:upper:]' '[:lower:]')" in
      china|cn)
        NETWORK_PROXY_MODE="direct"
        NETWORK_REGION="china"
        log_info "Region override: China (via CHECK_AI_CLI_REGION)"
        return 0
        ;;
      global|intl)
        NETWORK_PROXY_MODE="global"
        NETWORK_REGION="global"
        log_info "Region override: Global (via CHECK_AI_CLI_REGION)"
        return 0
        ;;
    esac
  fi
  
  log_info "Testing connectivity to determine best npm source..."
  
  # Test connectivity
  local google_time baidu_time npmjs_time npmmirror_time
  google_time=$(test_url_timing "https://www.google.com/generate_204" 5)
  baidu_time=$(test_url_timing "https://www.baidu.com" 5)
  npmjs_time=$(test_url_timing "https://registry.npmjs.org" 5)
  npmmirror_time=$(test_url_timing "https://registry.npmmirror.com" 5)
  
  local google_ok baidu_ok npmjs_ok npmmirror_ok
  [ "$google_time" != "-1" ] && google_ok="yes" || google_ok="no"
  [ "$baidu_time" != "-1" ] && baidu_ok="yes" || baidu_ok="no"
  [ "$npmjs_time" != "-1" ] && npmjs_ok="yes" || npmjs_ok="no"
  [ "$npmmirror_time" != "-1" ] && npmmirror_ok="yes" || npmmirror_ok="no"
  
  # Determine proxy mode
  if [ "$google_ok" = "yes" ] && [ "$baidu_ok" = "yes" ]; then
    NETWORK_PROXY_MODE="global"
    log_info "Network mode: Global proxy (all traffic proxied)"
  elif [ "$google_ok" = "no" ] && [ "$baidu_ok" = "yes" ]; then
    NETWORK_PROXY_MODE="direct"
    log_info "Network mode: Direct connection (China network)"
  elif [ "$google_ok" = "yes" ] && [ "$baidu_ok" = "no" ]; then
    NETWORK_PROXY_MODE="rule"
    log_info "Network mode: Rule-based proxy (selective)"
  else
    NETWORK_PROXY_MODE="unknown"
    log_warn "Network mode: Unknown (network issues)"
  fi
  
  # Determine effective region based on npm registry speed
  case "$NETWORK_PROXY_MODE" in
    global)
      if [ "$npmjs_ok" = "yes" ] && [ "$npmmirror_ok" = "yes" ]; then
        if [ "$npmjs_time" -le "$npmmirror_time" ]; then
          NETWORK_REGION="global"
        else
          NETWORK_REGION="china"
        fi
      elif [ "$npmjs_ok" = "yes" ]; then
        NETWORK_REGION="global"
      elif [ "$npmmirror_ok" = "yes" ]; then
        NETWORK_REGION="china"
      else
        NETWORK_REGION="global"
      fi
      ;;
    direct)
      NETWORK_REGION="china"
      ;;
    rule)
      if [ "$npmmirror_ok" = "yes" ] && { [ "$npmjs_ok" = "no" ] || [ "$npmmirror_time" -lt "$npmjs_time" ]; }; then
        NETWORK_REGION="china"
      else
        NETWORK_REGION="global"
      fi
      ;;
    *)
      NETWORK_REGION="unknown"
      ;;
  esac
  
  log_info "Effective region for npm: $NETWORK_REGION"
}

# Get best npm mirror based on network detection
get_best_npm_mirror() {
  detect_network_environment
  
  if [ "$NETWORK_REGION" = "china" ]; then
    # Test China mirrors
    if test_url_timing "$NPM_MIRROR_TAOBAO" 3 >/dev/null 2>&1; then
      log_info "Using China npm mirror: npmmirror (taobao)"
      echo "$NPM_MIRROR_TAOBAO"
      return 0
    fi
    if test_url_timing "$NPM_MIRROR_TENCENT" 3 >/dev/null 2>&1; then
      log_info "Using China npm mirror: tencent"
      echo "$NPM_MIRROR_TENCENT"
      return 0
    fi
    if test_url_timing "$NPM_MIRROR_HUAWEI" 3 >/dev/null 2>&1; then
      log_info "Using China npm mirror: huawei"
      echo "$NPM_MIRROR_HUAWEI"
      return 0
    fi
    log_info "Using China npm mirror: npmmirror (taobao) [fallback]"
    echo "$NPM_MIRROR_TAOBAO"
    return 0
  fi
  
  log_info "Using official npm registry"
  echo "$NPM_MIRROR_DEFAULT"
}

# Resolve the best regional npm mirror once and cache it in NPM_BEST_MIRROR.
# Caching keeps repeated npm installs (several tools) from re-running network
# probes, and --registry is applied per command so ~/.npmrc is never persisted.
select_best_npm_mirror() {
  if [ -n "$NPM_BEST_MIRROR" ]; then return 0; fi
  NPM_BEST_MIRROR="$(get_best_npm_mirror)"
}

# Install a global npm package using the cached best mirror via --registry.
npm_install_global() {
  local spec="$1"
  select_best_npm_mirror
  npm install -g "$spec" --registry "$NPM_BEST_MIRROR"
}

# Extract x.y.z from arbitrary text
extract_semver() {
  # Anchor version boundary: reject when preceded/followed by digit or dot to avoid
  # mis-extracting from multi-segment numbers like dates '2026.01.0.142' or paths '/1.2.3/bin'.
  echo "$*" | grep -Eo '(^|[^0-9.])([0-9]+\.[0-9]+\.[0-9]+)([^0-9.]|$)' | head -n 1 | grep -Eo '[0-9]+\.[0-9]+\.[0-9]+' | head -n 1
}

# Compare two x.y.z versions: prints -1/0/1, prints empty if not comparable
compare_semver() {
  local a b a1 a2 a3 b1 b2 b3
  a="$(extract_semver "$1")"
  b="$(extract_semver "$2")"
  [ -n "$a" ] || return 1
  [ -n "$b" ] || return 1
  IFS='.' read -r a1 a2 a3 <<< "$a"
  IFS='.' read -r b1 b2 b3 <<< "$b"
  if [ "$a1" -ne "$b1" ]; then [ "$a1" -lt "$b1" ] && echo -1 || echo 1; return 0; fi
  if [ "$a2" -ne "$b2" ]; then [ "$a2" -lt "$b2" ] && echo -1 || echo 1; return 0; fi
  if [ "$a3" -ne "$b3" ]; then [ "$a3" -lt "$b3" ] && echo -1 || echo 1; return 0; fi
  echo 0
}

show_progress_enabled() {
  [ "${CHECK_AI_CLI_SHOW_PROGRESS:-0}" = "1" ] && [ -t 2 ]
}

# Prefer curl, fallback to wget
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

get_local_version() {
  local name="$1"
  if ! command_exists "$name"; then return 1; fi
  extract_semver "$("$name" --version 2>/dev/null | tr '\n' ' ')"
}

normalize_dir() {
  local dir="${1:-}"
  [ -n "$dir" ] || return 1
  if [ -d "$dir" ]; then (cd "$dir" && pwd); else printf '%s\n' "${dir%/}"; fi
}

path_contains_dir() {
  local path_value="$1" needle current
  needle="$(normalize_dir "$2" 2>/dev/null || true)"
  [ -n "$needle" ] || return 1
  IFS=':' read -r -a parts <<< "$path_value"
  for current in "${parts[@]}"; do
    [ -n "$current" ] || continue
    [ "$(normalize_dir "$current" 2>/dev/null || true)" = "$needle" ] && return 0
  done
  return 1
}

remove_path_entry() {
  local path_value="$1" needle current result=()
  needle="$(normalize_dir "$2" 2>/dev/null || true)"
  [ -n "$needle" ] || { printf '%s\n' "$path_value"; return 0; }
  IFS=':' read -r -a parts <<< "$path_value"
  for current in "${parts[@]}"; do
    [ -n "$current" ] || continue
    [ "$(normalize_dir "$current" 2>/dev/null || true)" = "$needle" ] || result+=("$current")
  done
  local IFS=':'
  printf '%s\n' "${result[*]:-}"
}

prepend_path_entry() {
  local normalized trimmed
  normalized="$(normalize_dir "$2" 2>/dev/null || true)"
  [ -n "$normalized" ] || { printf '%s\n' "$1"; return 0; }
  trimmed="$(remove_path_entry "$1" "$normalized")"
  [ -n "$trimmed" ] && printf '%s\n' "$normalized:$trimmed" || printf '%s\n' "$normalized"
}

get_npm_global_bin_dir() {
  local prefix
  command_exists npm || return 1
  prefix="$(npm config get prefix 2>/dev/null | tr -d '\r\n')"
  [ -n "$prefix" ] && [ "$prefix" != "undefined" ] || return 1
  printf '%s\n' "$prefix/bin"
}

get_profile_file() {
  local shell_name
  shell_name="$(basename "${SHELL:-bash}")"
  case "$shell_name" in
    fish) printf '%s\n' "$HOME/.config/fish/config.fish" ;;
    zsh) printf '%s\n' "${ZDOTDIR:-$HOME}/.zshrc" ;;
    bash) [ -f "$HOME/.bashrc" ] && printf '%s\n' "$HOME/.bashrc" || printf '%s\n' "$HOME/.profile" ;;
    *) printf '%s\n' "$HOME/.profile" ;;
  esac
}

get_path_marker() {
  printf 'check-ai-cli:path:%s\n' "$(printf '%s' "$1" | tr '/\\: .' '_')"
}

persist_path_preference() {
  local dir="$1" file marker tmp shell_name
  file="$(get_profile_file)"
  marker="$(get_path_marker "$dir")"
  mkdir -p "$(dirname "$file")"
  [ -f "$file" ] || : > "$file"
  tmp="$file.tmp.$$"
  grep -Fv "$marker" "$file" > "$tmp" 2>/dev/null || true
  shell_name="$(basename "${SHELL:-bash}")"
  if [ "$shell_name" = "fish" ]; then
    printf 'fish_add_path -m "%s" # %s\n' "$dir" "$marker" >> "$tmp"
  else
    printf 'export PATH="%s:$PATH" # %s\n' "$dir" "$marker" >> "$tmp"
  fi
  mv "$tmp" "$file"
}

ensure_profile_path_prefers() {
  local normalized
  normalized="$(normalize_dir "$1" 2>/dev/null || true)"
  [ -n "$normalized" ] || return 1
  persist_path_preference "$normalized"
  PATH="$(prepend_path_entry "$PATH" "$normalized")"
  export PATH
  log_info "Moved $normalized to the front of your PATH permanently"
}

emit_dir_if_exists() {
  [ -d "$1" ] && printf '%s\n' "$1"
}

get_tool_candidate_dirs() {
  local tool_id="$1" npm_bin
  npm_bin="$(get_npm_global_bin_dir 2>/dev/null || true)"
  case "$tool_id" in
    factory) emit_dir_if_exists "$HOME/.local/bin"; emit_dir_if_exists "$HOME/bin" ;;
    claude) emit_dir_if_exists "$npm_bin"; emit_dir_if_exists "$HOME/.local/bin"; emit_dir_if_exists "$HOME/bin" ;;
    codex) emit_dir_if_exists "$npm_bin"; emit_dir_if_exists "/opt/homebrew/bin"; emit_dir_if_exists "/usr/local/bin"; emit_dir_if_exists "/home/linuxbrew/.linuxbrew/bin" ;;
    gemini) emit_dir_if_exists "$npm_bin"; emit_dir_if_exists "/opt/homebrew/bin"; emit_dir_if_exists "/usr/local/bin"; emit_dir_if_exists "/home/linuxbrew/.linuxbrew/bin" ;;
    opencode) emit_dir_if_exists "$HOME/.opencode/bin"; emit_dir_if_exists "$npm_bin"; emit_dir_if_exists "/opt/homebrew/bin"; emit_dir_if_exists "/usr/local/bin"; emit_dir_if_exists "/home/linuxbrew/.linuxbrew/bin" ;;
  esac | awk 'NF && !seen[$0]++'
}

repair_tool_path() {
  local tool_id="$1" dirs=() dir idx
  while IFS= read -r dir; do dirs+=("$dir"); done < <(get_tool_candidate_dirs "$tool_id")
  [ "${#dirs[@]}" -gt 0 ] || return 1
  for ((idx=${#dirs[@]}-1; idx>=0; idx--)); do ensure_profile_path_prefers "${dirs[$idx]}"; done
  return 0
}

get_local_factory() { repair_tool_path factory >/dev/null 2>&1 || true; get_local_version droid || get_local_version factory || true; }
get_local_claude() { repair_tool_path claude >/dev/null 2>&1 || true; get_local_version claude || get_local_version claude-code || true; }
get_local_codex() { repair_tool_path codex >/dev/null 2>&1 || true; get_local_version codex || true; }
get_local_gemini() { repair_tool_path gemini >/dev/null 2>&1 || true; get_local_version gemini || true; }
get_local_opencode() { repair_tool_path opencode >/dev/null 2>&1 || true; get_local_version opencode || true; }

get_latest_factory() {
  local text
  text="$(fetch_text 'https://app.factory.ai/cli/windows' || true)"
  extract_semver "$(echo "$text" | grep -Eo '\$version[[:space:]]*=[[:space:]]*"[^"]+"' | head -n 1)"
}

get_npm_latest_version() {
  local package_name="$1" text
  text="$(fetch_text "https://registry.npmjs.org/$package_name/latest" || true)"
  extract_semver "$(echo "$text" | grep -Eo '\"version\"[[:space:]]*:[[:space:]]*\"[^\"]+\"' | head -n 1)"
}

get_github_latest_release_version() {
  local repo="$1" text
  text="$(fetch_text "https://api.github.com/repos/$repo/releases/latest" || true)"
  extract_semver "$(echo "$text" | grep -Eo '\"tag_name\"[[:space:]]*:[[:space:]]*\"[^\"]+\"' | head -n 1)"
}

get_claude_bootstrap_stable_version() {
  extract_semver "$(fetch_text 'https://storage.googleapis.com/claude-code-dist-86c565f3-f756-42ad-8dfa-d59b1c096819/claude-code-releases/stable' || true)"
}

get_claude_repo_latest_version() {
  get_github_latest_release_version 'anthropics/claude-code'
}

select_higher_version() {
  [ -n "${1:-}" ] || { printf '%s\n' "${2:-}"; return 0; }
  [ -n "${2:-}" ] || { printf '%s\n' "$1"; return 0; }
  [ "$(compare_semver "$1" "$2" || true)" = "-1" ] && printf '%s\n' "$2" || printf '%s\n' "$1"
}

resolve_version_conflict() {
  local tool_name="$1" primary_label="$2" primary="$3" secondary_label="$4" secondary="$5" selected
  selected="$(select_higher_version "$primary" "$secondary")"
  [ -n "$primary" ] && [ -n "$secondary" ] && [ "$primary" != "$secondary" ] && log_warn "$tool_name latest version conflict: $primary_label=v$primary, $secondary_label=v$secondary. Using v$selected."
  printf '%s\n' "$selected"
}

get_latest_claude() {
  local repo stable npm
  repo="$(get_claude_repo_latest_version)"
  stable="$(get_claude_bootstrap_stable_version)"
  if [ -z "$repo" ] && [ -z "$stable" ]; then
    npm="$(get_npm_latest_version '@anthropic-ai/claude-code')"
    printf '%s\n' "$npm"
    return
  fi
  # Prefer bootstrap stable: the native updater installs from the stable channel,
  # which may lag behind GitHub releases due to staged rollout.
  [ -n "$stable" ] && printf '%s\n' "$stable" && return
  printf '%s\n' "$repo"
}

get_latest_codex() {
  local repo npm
  repo="$(get_github_latest_release_version 'openai/codex')"
  [ -n "$repo" ] && printf '%s\n' "$repo" && return
  npm="$(get_npm_latest_version '@openai/codex')"
  printf '%s\n' "$npm"
}

get_latest_gemini() {
  local repo npm
  repo="$(get_github_latest_release_version 'google-gemini/gemini-cli')"
  [ -n "$repo" ] && printf '%s\n' "$repo" && return
  npm="$(get_npm_latest_version '@google/gemini-cli')"
  printf '%s\n' "$npm"
}

get_latest_opencode() {
  # 优先使用环境变量指定的版本
  if [ -n "$OPENCODE_TARGET_VERSION" ]; then
    extract_semver "$OPENCODE_TARGET_VERSION"
    return
  fi

  local repo npm
  repo="$(get_github_latest_release_version 'anomalyco/opencode')"
  if [ -n "$repo" ]; then printf '%s\n' "$repo"; return; fi
  npm="$(get_npm_latest_version 'opencode-ai')"
  if [ -n "$npm" ]; then printf '%s\n' "$npm"; return; fi
  log_warn "Failed to determine latest OpenCode version from official sources."
}

confirm_yes() {
  local prompt="$1"
  if [ "$AUTO_MODE" = "1" ]; then
    echo "$prompt" >/dev/null 2>&1 || true
    return 0
  fi
  read -r -p "$prompt" ans || true
  case "${ans:-}" in
    Y|y|YES|yes) return 0 ;;
    *) return 1 ;;
  esac
}

# Security warning for remote script execution
confirm_remote_script_execution() {
  local url="$1" tool_name="$2"
  if [ "$AUTO_MODE" = "1" ]; then
    log_warn "[SECURITY] Auto mode: executing remote script from $url"
    return 0
  fi
  echo ""
  log_warn "┌─────────────────────────────────────────────────────────────┐"
  log_warn "│ SECURITY WARNING: Remote Script Execution                   │"
  log_warn "└─────────────────────────────────────────────────────────────┘"
  echo -e "${COLOR_WARN}Tool: $tool_name${COLOR_RESET}"
  echo -e "${COLOR_WARN}URL:  $url${COLOR_RESET}"
  echo ""
  echo -e "${COLOR_ERR}This will download and execute a script from the internet.${COLOR_RESET}"
  echo -e "${COLOR_ERR}Only proceed if you trust the source.${COLOR_RESET}"
  echo ""
  read -r -p "Type 'YES' to confirm execution: " ans || true
  [ "${ans:-}" = "YES" ]
}

# Detect whether the shell is running under Windows (Git Bash / MSYS / Cygwin).
# Used to decide whether Factory can be installed via verified binary download
# (Windows-only path, mirrors the PowerShell checker) instead of piping the
# official install script into sh.
is_windows_shell() {
  case "${OSTYPE:-}" in
    msys|cygwin) return 0 ;;
  esac
  case "$(uname -s 2>/dev/null)" in
    *MINGW*|*MSYS*|*CYGWIN*) return 0 ;;
  esac
  return 1
}

# Return 0 if a sha256 tool (sha256sum or shasum) is available.
sha256_tool_exists() {
  command_exists sha256sum && return 0
  command_exists shasum && return 0
  return 1
}

# Print the sha256 of a file (lowercase hex), or empty on failure.
sha256_file() {
  local file="$1"
  if command_exists sha256sum; then sha256sum "$file" | awk '{print $1}'; return 0; fi
  if command_exists shasum; then shasum -a 256 "$file" | awk '{print $1}'; return 0; fi
  return 1
}

# Download a URL into $OutFile. Reuses curl/wget preference from fetch_text.
download_file() {
  local url="$1" out="$2"
  if command_exists curl; then curl -fsSL "$url" -o "$out" || return 1; return 0; fi
  if command_exists wget; then wget -q --timeout=60 -O "$out" "$url" || return 1; return 0; fi
  return 1
}

# Install Factory on Windows via verified binary download (mirrors the
# PowerShell Install-FactoryFromBootstrap). Returns 0 on success, non-zero on
# failure (caller falls back to the official install script).
install_factory_binary_windows() {
  if ! sha256_tool_exists; then
    log_warn "sha256 tool not found; skipping verified binary install."
    return 1
  fi
  local text version base_url arch binary_name rg_binary_name
  text="$(fetch_text 'https://app.factory.ai/cli/windows' || true)"
  [ -n "$text" ] || { log_warn "Failed to fetch Factory bootstrap metadata."; return 1; }
  version="$(echo "$text" | grep -Eo '\$version[[:space:]]*=[[:space:]]*"[^"]+"' | head -n 1 | sed -E 's/.*"([^"]+)".*/\1/')"
  base_url="$(echo "$text" | grep -Eo '\$baseUrl[[:space:]]*=[[:space:]]*"[^"]+"' | head -n 1 | sed -E 's/.*"([^"]+)".*/\1/')"
  [ -n "$version" ] && [ -n "$base_url" ] || { log_warn "Failed to parse Factory bootstrap metadata."; return 1; }
  base_url="${base_url%/}"

  # Architecture detection mirrors the PowerShell Get-FactoryArchitectures baseline
  # fallback: prefer x64-baseline when AVX2 is uncertain, else x64.
  local proc_arch
  proc_arch="${PROCESSOR_ARCHITECTURE:-$(uname -m 2>/dev/null)}"
  case "$proc_arch" in
    *ARM64*|*aarch64*) arch="x64-baseline" ;;
    *) arch="x64" ;;
  esac

  binary_name="droid.exe"
  rg_binary_name="rg.exe"

  local factory_url factory_sha_url rg_url rg_sha_url tmpdir
  factory_url="$base_url/factory-cli/releases/$version/windows/$arch/$binary_name"
  factory_sha_url="$factory_url.sha256"
  rg_url="$base_url/ripgrep/windows/$arch/$rg_binary_name"
  rg_sha_url="$rg_url.sha256"

  tmpdir="$(mktemp -d 2>/dev/null)" || { log_warn "Failed to create temp dir for Factory download."; return 1; }

  local binary_path rg_binary_path expected actual
  binary_path="$tmpdir/$binary_name"
  rg_binary_path="$tmpdir/$rg_binary_name"

  log_info "Downloading Factory CLI v$version (Windows-$arch) with checksum verification"

  if ! download_file "$factory_url" "$binary_path"; then
    log_warn "Failed to download Factory binary; falling back to official installer."
    rm -rf "$tmpdir" 2>/dev/null
    return 1
  fi

  expected="$(fetch_text "$factory_sha_url" | awk '{print tolower($1)}')"
  actual="$(sha256_file "$binary_path" | tr '[:upper:]' '[:lower:]')"
  if [ -z "$expected" ] || [ -z "$actual" ] || [ "$expected" != "$actual" ]; then
    log_warn "Factory CLI checksum verification failed; falling back to official installer."
    rm -rf "$tmpdir" 2>/dev/null
    return 1
  fi
  log_info "Factory CLI checksum verification passed"

  # ripgrep is optional - only verify if it downloads successfully.
  if download_file "$rg_url" "$rg_binary_path"; then
    expected="$(fetch_text "$rg_sha_url" | awk '{print tolower($1)}')"
    actual="$(sha256_file "$rg_binary_path" | tr '[:upper:]' '[:lower:]')"
    if [ -n "$expected" ] && [ -n "$actual" ] && [ "$expected" = "$actual" ]; then
      log_info "ripgrep checksum verification passed"
    else
      log_warn "ripgrep checksum verification skipped or failed (non-fatal)"
    fi
  fi

  local install_dir factory_bin_dir install_path rg_install_path
  install_dir="$USERPROFILE/bin"
  [ -n "$USERPROFILE" ] || install_dir="$HOME/bin"
  factory_bin_dir="$USERPROFILE/.factory/bin"
  [ -n "$USERPROFILE" ] || factory_bin_dir="$HOME/.factory/bin"
  install_path="$install_dir/$binary_name"
  rg_install_path="$factory_bin_dir/$rg_binary_name"

  mkdir -p "$install_dir" "$factory_bin_dir" 2>/dev/null

  cp -f "$binary_path" "$install_path" 2>/dev/null || {
    # Destination may be locked by a running droid. Stop it and retry once.
    log_info "Stopping running droid to complete update"
    taskkill //F //IM droid.exe >/dev/null 2>&1 || true
    sleep 1
    cp -f "$binary_path" "$install_path" || { log_warn "Failed to install Factory binary."; rm -rf "$tmpdir"; return 1; }
  }
  cp -f "$rg_binary_path" "$rg_install_path" 2>/dev/null || true

  rm -rf "$tmpdir" 2>/dev/null
  log_info "Factory CLI v$version installed successfully."
  ensure_profile_path_prefers "$install_dir" 2>/dev/null || true
  repair_tool_path factory >/dev/null 2>&1 || true
  return 0
}

update_factory() {
  log_info "Updating Factory CLI (Droid)..."

  # On Windows shells (Git Bash / MSYS / Cygwin), prefer the verified binary
  # download path (mirrors PowerShell Install-FactoryFromBootstrap) which
  # validates the SHA256 of droid.exe before install.
  if is_windows_shell; then
    if install_factory_binary_windows; then return 0; fi
    log_warn "Verified binary install unavailable; falling back to official installer."
  fi

  log_info "Trying: official bootstrap"
  local url='https://app.factory.ai/cli'
  if ! confirm_remote_script_execution "$url" "Factory CLI"; then
    log_warn "Installation cancelled by user."
    return 1
  fi
  if fetch_text "$url" | sh; then repair_tool_path factory >/dev/null 2>&1 || true; return 0; fi
  log_err "Factory CLI installer failed."
  return 1
}


# Get the bounded timeout (seconds) for `claude update`. Mirrors the PowerShell
# Get-ClaudeNativeUpdateTimeoutSeconds so both platforms honor the same knob.
get_claude_native_update_timeout_seconds() {
  local v="${CHECK_AI_CLI_CLAUDE_UPDATE_TIMEOUT_SECONDS:-}"
  if [ -n "$v" ] && [ "$v" -gt 0 ] 2>/dev/null; then printf '%s' "$v"; return; fi
  printf '%s' '300'
}

# Run `claude update` with a bounded timeout. Returns 0 on success, non-zero on
# failure or when claude is not installed. Mirrors Invoke-ClaudeNativeUpdate so
# the POSIX checker tries the fast native updater before falling back to the
# heavier official install script and npm.
try_claude_native_update() {
  if ! command_exists claude; then return 1; fi
  log_info "Trying: claude update"
  local timeout_sec
  timeout_sec="$(get_claude_native_update_timeout_seconds)"
  if command_exists timeout; then
    timeout "$timeout_sec" claude update || { log_warn "native claude update failed or timed out"; return 1; }
  elif command_exists gtimeout; then
    gtimeout "$timeout_sec" claude update || { log_warn "native claude update failed or timed out"; return 1; }
  else
    # No timeout(1) available (e.g. macOS without coreutils). Run without a
    # bound rather than skipping the native updater entirely.
    claude update || { log_warn "native claude update failed"; return 1; }
  fi
  return 0
}

# Return 0 if the locally installed Claude is at least $1, else 1. Empty target
# is treated as "satisfied" (mirrors Test-ClaudeVersionAtLeast).
test_claude_version_at_least() {
  local target="$1" localv cmp
  [ -n "$target" ] || return 0
  localv="$(get_local_claude || true)"
  [ -n "$localv" ] || return 1
  cmp="$(compare_semver "$localv" "$target" || true)"
  [ "$cmp" = "0" ] || [ "$cmp" = "1" ]
}

update_claude() {
  log_info "Updating Claude Code..."
  local target
  target="$(get_latest_claude || true)"

  # 1. Native updater (fast, self-contained). Mirrors PowerShell priority.
  if try_claude_native_update; then
    repair_tool_path claude >/dev/null 2>&1 || true
    if test_claude_version_at_least "$target"; then return 0; fi
    if [ -n "$target" ]; then
      log_warn "native Claude update completed but local version is still older than target v$target."
    else
      log_warn "native Claude update completed but local Claude version could not be verified."
    fi
  fi

  # 2. Official install.sh (heavier, downloads the full installer).
  log_info "Trying: official bootstrap"
  local url='https://claude.ai/install.sh'
  if confirm_remote_script_execution "$url" "Claude Code"; then
    if fetch_text "$url" | bash; then
      repair_tool_path claude >/dev/null 2>&1 || true
      if test_claude_version_at_least "$target"; then return 0; fi
      if [ -n "$target" ]; then
        log_warn "official Claude install script completed but local version is still older than target v$target."
      fi
    fi
  else
    log_warn "Remote script execution declined, trying other methods..."
  fi

  # 3. npm fallback.
  if command_exists npm; then
    log_info "Trying: npm install"
    if npm_install_global '@anthropic-ai/claude-code'; then
      repair_tool_path claude >/dev/null 2>&1 || true
      return 0
    fi
  fi

  log_err "No installer found. Install curl/wget, brew, or Node.js (npm) first."
  return 1
}

update_codex() {
  log_info "Updating OpenAI Codex..."
  if command_exists npm; then
    log_info "Trying: npm install"
    npm_install_global '@openai/codex@latest' || return 1
    repair_tool_path codex >/dev/null 2>&1 || true
    return 0
  fi
  if command_exists brew; then
    log_info "Trying: brew install"
    brew install --cask codex || return 1
    repair_tool_path codex >/dev/null 2>&1 || true
    return 0
  fi
  log_err "No installer found. Install npm or brew first."
  return 1
}

update_gemini() {
  log_info "Updating Gemini CLI..."
  if command_exists npm; then
    log_info "Trying: npm install"
    npm_install_global '@google/gemini-cli@latest' || return 1
    repair_tool_path gemini >/dev/null 2>&1 || true
    return 0
  fi
  if command_exists brew; then
    log_info "Trying: brew install"
    if brew list --formula gemini-cli >/dev/null 2>&1; then brew upgrade gemini-cli || return 1; else brew install gemini-cli || return 1; fi
    repair_tool_path gemini >/dev/null 2>&1 || true
    return 0
  fi
  log_err "No installer found. Install npm or brew first."
  return 1
}

update_opencode() {
  log_info "Updating OpenCode..."
  local target localv cmp url
  target="$(get_latest_opencode)"
  [ -n "$target" ] || { log_err "Failed to determine OpenCode target version"; return 1; }
  log_info "Target OpenCode version: v$target"

  log_info "Trying: curl/wget install"
  url='https://opencode.ai/install'
  if confirm_remote_script_execution "$url" "OpenCode"; then
    if fetch_text "$url" | bash -s -- --version "$target"; then
      repair_tool_path opencode >/dev/null 2>&1 || true
      localv="$(get_local_opencode || true)"
      cmp="$(compare_semver "$localv" "$target" || true)"
      if [ "$cmp" = "0" ] || [ "$cmp" = "1" ]; then return 0; fi
    else
      log_warn "curl/wget install failed, continuing fallbacks."
    fi
  else
    log_warn "Remote script execution declined, trying other methods..."
  fi

  if command_exists opencode; then
    log_info "Trying: opencode upgrade"
    opencode upgrade "v$target" || true
    repair_tool_path opencode >/dev/null 2>&1 || true
    localv="$(get_local_opencode || true)"
    cmp="$(compare_semver "$localv" "$target" || true)"
    if [ "$cmp" = "0" ] || [ "$cmp" = "1" ]; then return 0; fi
  fi

  if command_exists brew; then
    log_info "Trying: brew install"
    if brew install anomalyco/tap/opencode; then
      if ! opencode upgrade "v$target" 2>/dev/null; then
        log_warn "opencode upgrade failed, checking if installed version is sufficient..."
      fi
      repair_tool_path opencode >/dev/null 2>&1 || true
      localv="$(get_local_opencode || true)"
      cmp="$(compare_semver "$localv" "$target" || true)"
      if [ "$cmp" = "0" ] || [ "$cmp" = "1" ]; then return 0; fi
    else
      log_warn "brew install failed, continuing fallbacks."
    fi
  fi

  if command_exists npm; then
    log_info "Trying: npm install"
    npm_install_global "opencode-ai@latest" || return 1
    repair_tool_path opencode >/dev/null 2>&1 || true
    localv="$(get_local_opencode || true)"
    cmp="$(compare_semver "$localv" "$target" || true)"
    if [ "$cmp" = "0" ] || [ "$cmp" = "1" ]; then return 0; fi
  fi

  log_err "No installer found. Install curl/wget, brew, or Node.js (npm) first."
  return 1
}

print_tool_header() {
  local title="$1"
  echo ""
  echo "$title"
  printf '%*s\n' "${#title}" '' | tr ' ' '='
}

print_versions() {
  local latest="$1" localv="$2"
  [ -n "$latest" ] && log_ok "Latest version: v$latest" || log_warn "Latest version: unknown"
  [ -n "$localv" ] && log_ok "Local version: v$localv" || log_warn "Local version: not installed"
}

handle_update_flow() {
  local latest="$1" localv="$2" update_fn="$3"
  if [ -z "$localv" ]; then
    [ -n "$latest" ] || log_warn "Latest version unknown. Installing anyway."
    confirm_yes "Install now? (Y/N): " && "$update_fn"
    return 0
  fi
  [ -n "$latest" ] || { log_warn "Latest version unknown. Skipping update check."; return 0; }
  local cmp
  cmp="$(compare_semver "$localv" "$latest" || true)"
  [ "$cmp" = "0" ] && log_ok "Already up to date." && return 0
  [ "$cmp" = "1" ] && log_warn "Local version is newer than latest source." && return 0
  [ "$cmp" = "-1" ] && confirm_yes "Update now? (Y/N): " && "$update_fn"
}

check_tool() {
  local title="$1" latest_fn="$2" local_fn="$3" update_fn="$4"
  print_tool_header "$title"
  log_info "Fetching latest version..."
  local latest localv
  latest="$("$latest_fn" || true)"
  localv="$("$local_fn" || true)"
  print_versions "$latest" "$localv"
  handle_update_flow "$latest" "$localv" "$update_fn"
}

show_banner() {
  echo ""
  echo "==============================================="
  echo " AI CLI Version Checker"
  echo " Factory CLI (Droid) | Claude Code | OpenAI Codex | Gemini CLI | OpenCode"
  echo "==============================================="
  echo ""
}

ask_selection() {
  echo "Select tools to check:"
  echo "  [1] Factory CLI (Droid)"
  echo "  [2] Claude Code"
  echo "  [3] OpenAI Codex"
  echo "  [4] Gemini CLI"
  echo "  [5] OpenCode"
  echo "  [A] Check all (default)"
  echo "  [Q] Quit"
  read -r -p "Enter choice (1/2/3/4/5/A/Q): " choice || true
  echo "${choice:-A}" | tr '[:lower:]' '[:upper:]'
}

main() {
  local sel
  require_fetch_tool || exit 1
  show_banner
  select_best_npm_mirror
  sel="$(ask_selection)"
  if [ "$sel" = "Q" ]; then exit 0; fi
  if [ "$sel" = "1" ] || [ "$sel" = "A" ]; then check_tool "Factory CLI (Droid)" get_latest_factory get_local_factory update_factory; fi
  if [ "$sel" = "2" ] || [ "$sel" = "A" ]; then check_tool "Claude Code" get_latest_claude get_local_claude update_claude; fi
  if [ "$sel" = "3" ] || [ "$sel" = "A" ]; then check_tool "OpenAI Codex" get_latest_codex get_local_codex update_codex; fi
  if [ "$sel" = "4" ] || [ "$sel" = "A" ]; then check_tool "Gemini CLI" get_latest_gemini get_local_gemini update_gemini; fi
  if [ "$sel" = "5" ] || [ "$sel" = "A" ]; then check_tool "OpenCode" get_latest_opencode get_local_opencode update_opencode; fi
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
fi