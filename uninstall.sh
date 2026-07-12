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

require_install_marker() {
  local dir="$1" marker actual home
  home="${HOME:-}"
  if [ "$dir" = "/" ] || { [ -n "$home" ] && [ "$dir" = "$home" ]; }; then
    log_err "Refusing to remove a filesystem or user-profile root: $dir"
    return 1
  fi
  if [ -L "$dir" ]; then
    log_err "Refusing to remove a symbolic-link directory: $dir"
    return 1
  fi
  marker="$dir/.check-ai-cli-installed"
  [ -f "$marker" ] || {
    log_err "Refusing to remove an unmarked directory: $dir"
    return 1
  }
  actual="$(tr -d '\r\n' < "$marker")"
  [ "$actual" = 'Check-AI-CLI' ] || {
    log_err "Invalid Check-AI-CLI installation marker: $dir"
    return 1
  }
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
  require_install_marker "$dir"
  if ! confirm_delete "$dir"; then log_warn "Canceled."; exit 0; fi
  rm -rf -- "$dir"
  log_ok "Uninstalled: $dir"
}

main
