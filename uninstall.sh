#!/usr/bin/env bash
set -euo pipefail

# Uninstall script: removes install dir (default current dir), does not edit PATH automatically
# Env vars:
# - CHECK_AI_CLI_INSTALL_DIR: install directory, default current dir

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
