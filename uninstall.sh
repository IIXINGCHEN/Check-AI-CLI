#!/usr/bin/env bash
set -euo pipefail

# Uninstall script: removes install dir (default current dir), does not edit PATH automatically
# Env vars:
# - CHECK_AI_CLI_INSTALL_DIR: install directory, default current dir

INSTALL_DIR="${CHECK_AI_CLI_INSTALL_DIR:-.}"

log_info() { printf "[INFO] %s\n" "$*" >&2; }
log_ok() { printf "[SUCCESS] %s\n" "$*" >&2; }
log_warn() { printf "[WARNING] %s\n" "$*" >&2; }
log_err() { printf "[ERROR] %s\n" "$*" >&2; }

confirm_delete() {
  local dir="$1"
  log_warn "This will remove directory: $dir"
  read -r -p "Type DELETE to confirm: " ans || true
  [ "${ans:-}" = "DELETE" ]
}

main() {
  local dir
  if [ -d "$INSTALL_DIR" ]; then
    dir="$(cd "$INSTALL_DIR" && pwd)"
  else
    dir="$(cd "$(dirname "$INSTALL_DIR")" 2>/dev/null && pwd || pwd)/$(basename "$INSTALL_DIR")"
    log_warn "Install directory does not exist: $dir"
    log_warn "Nothing to uninstall."
    exit 0
  fi
  if ! confirm_delete "$dir"; then log_warn "Canceled."; exit 0; fi
  rm -rf -- "$dir"
  log_ok "Uninstalled: $dir"
}

main
