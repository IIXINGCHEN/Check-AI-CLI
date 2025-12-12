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

download_file_list() {
  echo "scripts/check-ai-cli-versions.sh"
}

download_all() {
  local dir="$1" f
  mkdir -p "$dir/scripts" "$dir/bin"
  while read -r f; do
    log_info "Downloading: $f"
    download_with_retry "$BASE/$f" "$dir/$f" || {
      log_err "Failed to download: $BASE/$f"
      return 1
    }
  done < <(download_file_list)
}

print_next_steps() {
  local dir="$1"
  chmod +x "$dir/scripts/check-ai-cli-versions.sh" 2>/dev/null || true
  cat > "$dir/bin/check-ai-cli" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$DIR/.." && pwd)"
exec "$ROOT/scripts/check-ai-cli-versions.sh" "$@"
EOF
  chmod +x "$dir/bin/check-ai-cli" 2>/dev/null || true
  log_ok "Installed to: $dir"
  printf "\nNext:\n  cd \"%s\"\n  ./bin/check-ai-cli\n\n" "$dir"
  log_warn "Tip: add \"$dir/bin\" to PATH for global usage."
  log_warn "Tip: set CHECK_AI_CLI_REF to pin a tag/commit for stability."
  log_warn "Tip: prefer HTTP_PROXY/HTTPS_PROXY instead of third-party mirrors."
}

download_all "$INSTALL_DIR"
print_next_steps "$INSTALL_DIR"
