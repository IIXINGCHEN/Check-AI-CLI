#!/usr/bin/env bash
set -euo pipefail

# 中文注释: 这个脚本用于支持 curl | bash 一行命令安装/更新本仓库脚本文件
# 中文注释: 通过环境变量 CHECK_AI_CLI_RAW_BASE 可以指定加速镜像/代理前缀

BASE_DEFAULT="https://raw.githubusercontent.com/IIXINGCHEN/Check-AI-CLI/main"
BASE="${CHECK_AI_CLI_RAW_BASE:-$BASE_DEFAULT}"
BASE="${BASE%/}"
INSTALL_DIR="${CHECK_AI_CLI_INSTALL_DIR:-.}"

log_info() { printf "[INFO] %s\n" "$*"; }
log_ok() { printf "[SUCCESS] %s\n" "$*"; }
log_warn() { printf "[WARNING] %s\n" "$*"; }
log_err() { printf "[ERROR] %s\n" "$*"; }

command_exists() { command -v "$1" >/dev/null 2>&1; }

fetch_to_file() {
  local url="$1" out="$2"
  if command_exists curl; then curl -fsSL "$url" -o "$out"; return 0; fi
  if command_exists wget; then wget -qO "$out" "$url"; return 0; fi
  return 1
}

download_file_list() {
  echo "check-ai-cli-versions.sh"
}

download_all() {
  local dir="$1" f
  mkdir -p "$dir"
  while read -r f; do
    log_info "Downloading: $f"
    fetch_to_file "$BASE/$f" "$dir/$f" || return 1
  done < <(download_file_list)
}

print_next_steps() {
  local dir="$1"
  chmod +x "$dir/check-ai-cli-versions.sh" 2>/dev/null || true
  log_ok "Installed to: $dir"
  printf "\nNext:\n  cd \"%s\"\n  ./check-ai-cli-versions.sh\n\n" "$dir"
  log_warn "Tip: set CHECK_AI_CLI_RAW_BASE to use a mirror in mainland China."
}

download_all "$INSTALL_DIR"
print_next_steps "$INSTALL_DIR"
