#!/usr/bin/env bash
set -euo pipefail

# 中文注释: 这个脚本用于支持 curl | bash 一行命令安装/更新本仓库脚本文件
# 中文注释: 环境变量:
# 中文注释: - CHECK_AI_CLI_REF: 固定 tag/commit/main, 默认 main
# 中文注释: - CHECK_AI_CLI_RAW_BASE: raw 文件基础地址(镜像加速). 默认仅信任 GitHub 官方 raw
# 中文注释: - CHECK_AI_CLI_ALLOW_UNTRUSTED_MIRROR: 1 表示允许非官方镜像
# 中文注释: - CHECK_AI_CLI_INSTALL_DIR: 安装目录, 默认当前目录
# 中文注释: - CHECK_AI_CLI_RETRY: 下载重试次数, 默认 3

REF="${CHECK_AI_CLI_REF:-main}"
RAW_BASE="${CHECK_AI_CLI_RAW_BASE:-}"
ALLOW_UNTRUSTED="${CHECK_AI_CLI_ALLOW_UNTRUSTED_MIRROR:-0}"
RETRY="${CHECK_AI_CLI_RETRY:-3}"

is_number() { [[ "${1:-}" =~ ^[0-9]+$ ]]; }

clamp_retry() {
  if ! is_number "$RETRY"; then RETRY="3"; fi
  if [ "$RETRY" -lt 1 ]; then RETRY="1"; fi
  if [ "$RETRY" -gt 10 ]; then RETRY="10"; fi
}

is_trusted_base() {
  local base="$1"
  case "$base" in
    https://raw.githubusercontent.com/IIXINGCHEN/Check-AI-CLI/*) return 0 ;;
    https://github.com/IIXINGCHEN/Check-AI-CLI/raw/*) return 0 ;;
    *) return 1 ;;
  esac
}

resolve_base() {
  local base
  if [ -n "$RAW_BASE" ]; then
    base="${RAW_BASE%/}"
    if ! is_trusted_base "$base" && [ "$ALLOW_UNTRUSTED" != "1" ]; then
      log_err "Untrusted mirror base: $base"
      log_err "Set CHECK_AI_CLI_ALLOW_UNTRUSTED_MIRROR=1 to allow."
      exit 1
    fi
    echo "$base"
    return 0
  fi
  echo "https://raw.githubusercontent.com/IIXINGCHEN/Check-AI-CLI/$REF"
}

clamp_retry
BASE="$(resolve_base)"
INSTALL_DIR="${CHECK_AI_CLI_INSTALL_DIR:-.}"

log_info() { printf "[INFO] %s\n" "$*"; }
log_ok() { printf "[SUCCESS] %s\n" "$*"; }
log_warn() { printf "[WARNING] %s\n" "$*"; }
log_err() { printf "[ERROR] %s\n" "$*"; }

command_exists() { command -v "$1" >/dev/null 2>&1; }

ensure_parent_dir() {
  local path="$1"
  mkdir -p "$(dirname "$path")"
}

fetch_to_temp() {
  local url="$1" tmp="$2"
  if command_exists curl; then curl -fsSL "$url" -o "$tmp"; return 0; fi
  if command_exists wget; then wget -qO "$tmp" "$url"; return 0; fi
  return 1
}

download_with_retry() {
  local url="$1" out="$2" tmp="${out}.download"
  ensure_parent_dir "$out"
  for ((i=1; i<=RETRY; i++)); do
    rm -f "$tmp" >/dev/null 2>&1 || true
    if fetch_to_temp "$url" "$tmp" && [ -s "$tmp" ]; then
      mv -f "$tmp" "$out"
      return 0
    fi
    if [ "$i" -lt "$RETRY" ]; then sleep 2; fi
  done
  return 1
}

sha256_file() {
  local file="$1"
  if command_exists sha256sum; then sha256sum "$file" | awk '{print $1}'; return 0; fi
  if command_exists shasum; then shasum -a 256 "$file" | awk '{print $1}'; return 0; fi
  return 1
}

sha256_tool_exists() {
  command_exists sha256sum && return 0
  command_exists shasum && return 0
  return 1
}

print_sha256_help() {
  log_err "sha256 tool not found. Need sha256sum or shasum."
  if command_exists brew; then log_info "macOS: brew install coreutils"; return 0; fi
  if command_exists apt-get; then log_info "Debian/Ubuntu: sudo apt-get update && sudo apt-get install -y coreutils"; return 0; fi
  if command_exists dnf; then log_info "Fedora/RHEL: sudo dnf install -y coreutils"; return 0; fi
  if command_exists yum; then log_info "CentOS/RHEL: sudo yum install -y coreutils"; return 0; fi
  if command_exists apk; then log_info "Alpine: sudo apk add coreutils"; return 0; fi
  if command_exists pacman; then log_info "Arch: sudo pacman -S coreutils"; return 0; fi
  log_info "Install coreutils via your package manager."
}

require_sha256_tool() {
  sha256_tool_exists && return 0
  print_sha256_help
  return 1
}

list_manifest_paths() {
  local manifest="$1"
  awk 'NF>=2 && $1 !~ /^#/ {print $2}' "$manifest"
}

get_expected_hash() {
  local manifest="$1" path="$2"
  awk -v p="$path" '$2==p {print tolower($1); exit 0}' "$manifest"
}

verify_hash() {
  local manifest="$1" path="$2" file="$3"
  local expected actual
  expected="$(get_expected_hash "$manifest" "$path")"
  [ -n "$expected" ] || { log_err "Missing checksum: $path"; return 1; }
  actual="$(sha256_file "$file" 2>/dev/null | tr '[:upper:]' '[:lower:]')"
  [ -n "$actual" ] || { log_err "Failed to calculate sha256: $path"; return 1; }
  [ "$actual" = "$expected" ] || { log_err "Checksum mismatch: $path"; return 1; }
}

download_all() {
  local stage="$1" f
  mkdir -p "$stage/scripts" "$stage/bin"
  while read -r f; do
    [ -n "$f" ] || continue
    log_info "Downloading: $f"
    download_with_retry "$BASE/$f" "$stage/$f" || return 1
  done < <(list_manifest_paths "$stage/checksums.sha256")
}

download_manifest() {
  local stage="$1"
  download_with_retry "$BASE/checksums.sha256" "$stage/checksums.sha256"
}

verify_all() {
  local stage="$1" f
  while read -r f; do
    [ -n "$f" ] || continue
    verify_hash "$stage/checksums.sha256" "$f" "$stage/$f" || return 1
  done < <(list_manifest_paths "$stage/checksums.sha256")
}

deploy_one() {
  local stage="$1" dir="$2" rel="$3" src dst tmp
  src="$stage/$rel"
  dst="$dir/$rel"
  tmp="$dst.new"
  ensure_parent_dir "$dst"
  cp -f "$src" "$tmp"
  mv -f "$tmp" "$dst"
}

deploy_all() {
  local stage="$1" dir="$2" f
  mkdir -p "$dir/scripts" "$dir/bin"
  while read -r f; do
    [ -n "$f" ] || continue
    deploy_one "$stage" "$dir" "$f"
  done < <(list_manifest_paths "$stage/checksums.sha256")
}

print_next_steps() {
  local dir="$1"
  chmod +x "$dir/scripts/check-ai-cli-versions.sh" 2>/dev/null || true
  chmod +x "$dir/bin/check-ai-cli" 2>/dev/null || true
  chmod +x "$dir/uninstall.sh" 2>/dev/null || true
  log_ok "Installed to: $dir"
  printf "\nNext:\n  cd \"%s\"\n  ./bin/check-ai-cli\n\n" "$dir"
  log_warn "Tip: add \"$dir/bin\" to PATH for global usage."
  log_warn "Tip: set CHECK_AI_CLI_REF to pin a tag/commit for stability."
  log_warn "Tip: prefer HTTP_PROXY/HTTPS_PROXY instead of third-party mirrors."
}

main() {
  local stage
  stage="$(mktemp -d 2>/dev/null || mktemp -d -t check-ai-cli)"
  trap 'rm -rf "$stage" >/dev/null 2>&1 || true' EXIT

  download_manifest "$stage" || { log_err "Failed to download checksums.sha256"; exit 1; }
  require_sha256_tool || exit 1
  download_all "$stage" || { log_err "Download failed."; exit 1; }
  verify_all "$stage" || { log_err "Checksum verification failed."; exit 1; }
  deploy_all "$stage" "$INSTALL_DIR" || { log_err "Deploy failed."; exit 1; }
  print_next_steps "$INSTALL_DIR"
}

main
