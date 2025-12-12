#!/usr/bin/env bash
set -euo pipefail

# 中文注释: 卸载脚本, 删除安装目录(默认当前目录), 不自动修改 PATH
# 中文注释: 环境变量:
# 中文注释: - CHECK_AI_CLI_INSTALL_DIR: 安装目录, 默认当前目录

INSTALL_DIR="${CHECK_AI_CLI_INSTALL_DIR:-.}"

log_info() { printf "[INFO] %s\n" "$*"; }
log_ok() { printf "[SUCCESS] %s\n" "$*"; }
log_warn() { printf "[WARNING] %s\n" "$*"; }
log_err() { printf "[ERROR] %s\n" "$*"; }

confirm_delete() {
  local dir="$1"
  log_warn "This will remove directory: $dir"
  read -r -p "Type DELETE to confirm: " ans || true
  [ "${ans:-}" = "DELETE" ]
}

main() {
  local dir
  dir="$(cd "$INSTALL_DIR" && pwd)"
  if ! confirm_delete "$dir"; then log_warn "Canceled."; exit 0; fi
  rm -rf -- "$dir"
  log_ok "Uninstalled: $dir"
}

main

