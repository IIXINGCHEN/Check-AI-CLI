#!/usr/bin/env bash
set -u

# 中文注释: 自动模式, 未安装则安装, 非最新则更新, 不再询问 Y/N
AUTO_MODE="${CHECK_AI_CLI_AUTO:-0}"
if [ "${1:-}" = "--yes" ] || [ "${1:-}" = "-y" ]; then
  AUTO_MODE="1"
fi

# 中文注释: 颜色输出(不依赖外部工具)
COLOR_INFO='\033[36m'
COLOR_OK='\033[32m'
COLOR_WARN='\033[33m'
COLOR_ERR='\033[31m'
COLOR_RESET='\033[0m'

log_info() { echo -e "${COLOR_INFO}[INFO] $*${COLOR_RESET}"; }
log_ok() { echo -e "${COLOR_OK}[SUCCESS] $*${COLOR_RESET}"; }
log_warn() { echo -e "${COLOR_WARN}[WARNING] $*${COLOR_RESET}"; }
log_err() { echo -e "${COLOR_ERR}[ERROR] $*${COLOR_RESET}"; }

# 中文注释: 判断命令是否存在
command_exists() { command -v "$1" >/dev/null 2>&1; }

# 中文注释: 从任意文本中提取 x.y.z
extract_semver() {
  echo "$*" | grep -Eo '[0-9]+\.[0-9]+\.[0-9]+' | head -n 1
}

# 中文注释: 比较两个 x.y.z, 输出 -1/0/1, 无法比较输出空
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

# 中文注释: 尽量用 curl, 没有则用 wget
fetch_text() {
  local url="$1"
  if command_exists curl; then curl -fsSL "$url" 2>/dev/null || return 1; fi
  if command_exists wget; then wget -qO- "$url" 2>/dev/null || return 1; fi
  return 1
}

get_local_version() {
  local name="$1"
  if ! command_exists "$name"; then return 1; fi
  extract_semver "$("$name" --version 2>/dev/null | tr '\n' ' ')"
}

get_local_factory() { get_local_version factory || get_local_version droid || true; }
get_local_claude() { get_local_version claude || get_local_version claude-code || true; }
get_local_codex() { get_local_version codex || true; }
get_local_gemini() { get_local_version gemini || true; }

get_latest_factory() {
  local text
  text="$(fetch_text 'https://app.factory.ai/cli/windows' || true)"
  extract_semver "$(echo "$text" | grep -Eo '\$version[[:space:]]*=[[:space:]]*"[^"]+"' | head -n 1)"
}

get_latest_claude() {
  local text
  text="$(fetch_text 'https://registry.npmjs.org/@anthropic-ai/claude-code/latest' || true)"
  extract_semver "$(echo "$text" | grep -Eo '\"version\"[[:space:]]*:[[:space:]]*\"[^\"]+\"' | head -n 1)"
}

get_latest_codex() {
  local text
  text="$(fetch_text 'https://api.github.com/repos/openai/codex/releases/latest' || true)"
  extract_semver "$(echo "$text" | grep -Eo '\"tag_name\"[[:space:]]*:[[:space:]]*\"[^\"]+\"' | head -n 1)"
}

get_latest_gemini() {
  local text
  text="$(fetch_text 'https://registry.npmjs.org/@google/gemini-cli/latest' || true)"
  extract_semver "$(echo "$text" | grep -Eo '\"version\"[[:space:]]*:[[:space:]]*\"[^\"]+\"' | head -n 1)"
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

update_factory() {
  log_info "Updating Factory CLI (Droid)..."
  if fetch_text 'https://app.factory.ai/cli' | sh; then return 0; fi
  fetch_text 'https://app.factory.ai/cli/install.sh' | bash
}

update_claude() {
  log_info "Updating Claude Code..."
  if fetch_text 'https://claude.ai/install.sh' | bash; then return 0; fi
  if command_exists npm; then npm install -g '@anthropic-ai/claude-code'; return 0; fi
  log_err "No installer and npm not found."
  return 1
}

update_codex() {
  log_info "Updating OpenAI Codex..."
  if command_exists brew; then brew install --cask codex && return 0; fi
  if command_exists npm; then npm install -g '@openai/codex' && return 0; fi
  log_err "brew/npm not found."
  return 1
}

update_gemini() {
  log_info "Updating Gemini CLI..."
  if command_exists npm; then npm install -g '@google/gemini-cli@latest' && return 0; fi
  if command_exists brew; then
    brew list --formula gemini-cli >/dev/null 2>&1 && brew upgrade gemini-cli && return 0
    brew install gemini-cli && return 0
  fi
  log_err "npm/brew not found."
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
  echo " Factory CLI (Droid) | Claude Code | OpenAI Codex | Gemini CLI"
  echo "==============================================="
  echo ""
}

ask_selection() {
  echo "Select tools to check:"
  echo "  [1] Factory CLI (Droid)"
  echo "  [2] Claude Code"
  echo "  [3] OpenAI Codex"
  echo "  [4] Gemini CLI"
  echo "  [A] Check all (default)"
  read -r -p "Enter choice (1/2/3/4/A): " choice || true
  echo "${choice:-A}" | tr '[:lower:]' '[:upper:]'
}

show_banner
sel="$(ask_selection)"

if [ "$sel" = "1" ] || [ "$sel" = "A" ]; then
  check_tool "Factory CLI (Droid)" get_latest_factory get_local_factory update_factory
fi
if [ "$sel" = "2" ] || [ "$sel" = "A" ]; then
  check_tool "Claude Code" get_latest_claude get_local_claude update_claude
fi
if [ "$sel" = "3" ] || [ "$sel" = "A" ]; then
  check_tool "OpenAI Codex" get_latest_codex get_local_codex update_codex
fi
if [ "$sel" = "4" ] || [ "$sel" = "A" ]; then
  check_tool "Gemini CLI" get_latest_gemini get_local_gemini update_gemini
fi
