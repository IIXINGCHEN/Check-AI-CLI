#!/usr/bin/env bash
# Purge GitHub raw.githubusercontent.com CDN cache
# Usage: ./purge-github-cache.sh [-a|--all] [-w|--wait] [-v|--verify]
#
# GitHub CDN caches raw files for ~5 minutes. This script helps purge the cache
# by making requests with cache-busting headers.

set -e

REPO_OWNER="IIXINGCHEN"
REPO_NAME="Check-AI-CLI"
BRANCH="main"

BASE_URL="https://raw.githubusercontent.com/$REPO_OWNER/$REPO_NAME/$BRANCH"
PURGE_JSDELIVR_URL="https://purge.jsdelivr.net/gh/$REPO_OWNER/$REPO_NAME@$BRANCH"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m'

info() { echo -e "${CYAN}[INFO]${NC} $1"; }
success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
fail() { echo -e "${RED}[ERROR]${NC} $1"; }

# Critical files (default)
CRITICAL_FILES=(
  "checksums.sha256"
)

# All files
ALL_FILES=(
  "checksums.sha256"
  "install.ps1"
  "install.sh"
  "uninstall.ps1"
  "uninstall.sh"
  "bin/check-ai-cli"
  "bin/check-ai-cli.cmd"
  "bin/check-ai-cli.ps1"
  "scripts/Check-AI-CLI-Versions.ps1"
  "scripts/check-ai-cli-versions.sh"
)

get_local_hash() {
  local file="$1"
  local local_path="$REPO_ROOT/$file"
  if [[ ! -f "$local_path" ]]; then
    echo ""
    return
  fi
  if command -v sha256sum &>/dev/null; then
    sha256sum "$local_path" | cut -d' ' -f1
  elif command -v shasum &>/dev/null; then
    shasum -a 256 "$local_path" | cut -d' ' -f1
  else
    echo ""
  fi
}

get_remote_hash() {
  local url="$1"
  local content
  content=$(curl -fsSL -H "Cache-Control: no-cache" -H "Pragma: no-cache" "$url" 2>/dev/null) || return 1
  if command -v sha256sum &>/dev/null; then
    echo "$content" | sha256sum | cut -d' ' -f1
  elif command -v shasum &>/dev/null; then
    echo "$content" | shasum -a 256 | cut -d' ' -f1
  else
    echo ""
  fi
}

purge_github_raw() {
  local file="$1"
  local url="$BASE_URL/$file"
  info "Purging: $url"
  
  # Request with cache-busting headers
  local timestamp
  timestamp=$(date +%s%N 2>/dev/null || date +%s)
  curl -fsSL -H "Cache-Control: no-cache, no-store, must-revalidate, max-age=0" \
       -H "Pragma: no-cache" \
       -H "User-Agent: check-ai-cli-cache-purger/$timestamp" \
       "$url?t=$timestamp" >/dev/null 2>&1 || true
  
  # Request with random query string
  local rand
  rand=$(openssl rand -hex 8 2>/dev/null || echo "$RANDOM$RANDOM")
  curl -fsSL "$url?purge=$rand" >/dev/null 2>&1 || true
}

purge_jsdelivr() {
  local file="$1"
  local purge_url="$PURGE_JSDELIVR_URL/$file"
  info "Purging jsDelivr: $file"
  if curl -fsSL "$purge_url" >/dev/null 2>&1; then
    success "jsDelivr cache purged: $file"
  else
    warn "jsDelivr purge failed: $file"
  fi
}

test_cache_sync() {
  local file="$1"
  local local_hash remote_hash
  
  local_hash=$(get_local_hash "$file")
  if [[ -z "$local_hash" ]]; then
    warn "Local file not found: $file"
    return 1
  fi
  
  remote_hash=$(get_remote_hash "$BASE_URL/$file")
  if [[ -z "$remote_hash" ]]; then
    warn "Remote file not accessible: $file"
    return 1
  fi
  
  if [[ "$local_hash" == "$remote_hash" ]]; then
    success "Synced: $file"
    return 0
  else
    warn "Not synced: $file"
    warn "  Local:  $local_hash"
    warn "  Remote: $remote_hash"
    return 1
  fi
}

wait_for_sync() {
  local max_wait=300
  local interval=10
  local elapsed=0
  
  info "Waiting for CDN cache to sync (max $max_wait seconds)..."
  
  while [[ $elapsed -lt $max_wait ]]; do
    local all_synced=true
    for file in "${FILES_TO_PURGE[@]}"; do
      if ! test_cache_sync "$file"; then
        all_synced=false
      fi
    done
    
    if $all_synced; then
      success "All files synced!"
      return 0
    fi
    
    local remaining=$((max_wait - elapsed))
    info "Waiting $interval seconds... ($remaining seconds remaining)"
    sleep $interval
    elapsed=$((elapsed + interval))
  done
  
  fail "Timeout waiting for cache sync"
  return 1
}

usage() {
  echo "Usage: $0 [-a|--all] [-w|--wait] [-v|--verify]"
  echo ""
  echo "Options:"
  echo "  -a, --all     Purge all files (default: only checksums.sha256)"
  echo "  -w, --wait    Wait until cache is synced"
  echo "  -v, --verify  Only verify sync status, don't purge"
  echo "  -h, --help    Show this help"
  echo ""
}

# Parse arguments
PURGE_ALL=false
WAIT=false
VERIFY_ONLY=false

while [[ $# -gt 0 ]]; do
  case $1 in
    -a|--all) PURGE_ALL=true; shift ;;
    -w|--wait) WAIT=true; shift ;;
    -v|--verify) VERIFY_ONLY=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1"; usage; exit 1 ;;
  esac
done

# Select files to purge
if $PURGE_ALL; then
  FILES_TO_PURGE=("${ALL_FILES[@]}")
else
  FILES_TO_PURGE=("${CRITICAL_FILES[@]}")
fi

# Main
echo ""
echo "=========================================="
echo " GitHub CDN Cache Purge Tool"
echo "=========================================="
echo ""

if $VERIFY_ONLY; then
  info "Verifying cache sync status..."
  all_ok=true
  for file in "${FILES_TO_PURGE[@]}"; do
    if ! test_cache_sync "$file"; then
      all_ok=false
    fi
  done
  if $all_ok; then
    success "All files are in sync!"
    exit 0
  else
    fail "Some files are not in sync"
    exit 1
  fi
fi

info "Purging ${#FILES_TO_PURGE[@]} file(s)..."

for file in "${FILES_TO_PURGE[@]}"; do
  purge_github_raw "$file"
  purge_jsdelivr "$file"
done

echo ""
info "Verifying cache status..."
for file in "${FILES_TO_PURGE[@]}"; do
  test_cache_sync "$file" || true
done

if $WAIT; then
  echo ""
  wait_for_sync
fi

echo ""
info "Tips:"
echo "  - GitHub CDN cache typically expires in ~5 minutes"
echo "  - Use -w/--wait to wait until cache is synced"
echo "  - Use -v/--verify to only check sync status"
echo "  - Use -a/--all to purge all files (not just checksums)"
echo ""
