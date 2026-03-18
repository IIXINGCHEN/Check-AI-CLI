#!/usr/bin/env bash
set -euo pipefail

# This script supports "curl | bash" to install/update this repo's files
# Env vars:
# - CHECK_AI_CLI_REF: pin tag/commit/main; unset => latest stable release, else latest main commit, fallback main
# - CHECK_AI_CLI_RAW_BASE: raw base URL (mirror). Default trusts GitHub official raw only
# - CHECK_AI_CLI_ALLOW_UNTRUSTED_MIRROR: set to 1 to allow untrusted mirrors
# - CHECK_AI_CLI_INSTALL_DIR: install directory, default current dir
# - CHECK_AI_CLI_RETRY: download retry count, default 3

DEFAULT_REF="main"
REF="${CHECK_AI_CLI_REF:-}"
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

has_explicit_ref() { [ -n "$REF" ]; }

get_requested_ref() {
  if has_explicit_ref; then printf '%s' "$REF"; return 0; fi
  printf '%s' "$DEFAULT_REF"
}

get_latest_release_api_url() {
  printf '%s' 'https://api.github.com/repos/IIXINGCHEN/Check-AI-CLI/releases/latest'
}

get_latest_main_ref_api_url() {
  printf '%s' 'https://api.github.com/repos/IIXINGCHEN/Check-AI-CLI/git/ref/heads/main'
}

fetch_text() {
  local url="$1"
  if command_exists curl; then curl -fsSL "$url"; return 0; fi
  if command_exists wget; then wget -qO- "$url"; return 0; fi
  return 1
}

extract_release_tag() {
  tr -d '\r\n' | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p'
}

extract_main_ref_sha() {
  tr -d '\r\n' | sed -n 's/.*"object"[[:space:]]*:[[:space:]]*{[^}]*"sha"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p'
}

get_latest_stable_ref() {
  local text tag
  text="$(fetch_text "$(get_latest_release_api_url)" 2>/dev/null || true)"
  tag="$(printf '%s' "$text" | extract_release_tag)"
  [ -n "$tag" ] || return 1
  printf '%s' "$tag"
}

get_latest_main_commit_ref() {
  local text sha
  text="$(fetch_text "$(get_latest_main_ref_api_url)" 2>/dev/null || true)"
  sha="$(printf '%s' "$text" | extract_main_ref_sha)"
  [ -n "$sha" ] || return 1
  printf '%s' "$sha"
}

get_resolved_ref() {
  local stable main_commit fallback
  if has_explicit_ref; then get_requested_ref; return 0; fi
  stable="$(get_latest_stable_ref || true)"
  if [ -n "$stable" ]; then printf '%s' "$stable"; return 0; fi
  main_commit="$(get_latest_main_commit_ref || true)"
  if [ -n "$main_commit" ]; then printf '%s' "$main_commit"; return 0; fi
  fallback="$(get_requested_ref)"
  log_warn "Latest stable release ref unavailable. Falling back to $fallback." >&2
  printf '%s' "$fallback"
}

resolve_base() {
  local base
  if [ -n "$RAW_BASE" ]; then
    base="${RAW_BASE%/}"
    if ! is_trusted_base "$base"; then
      if [ "$ALLOW_UNTRUSTED" != "1" ]; then
        log_err "Untrusted mirror base: $base"
        log_err "Set CHECK_AI_CLI_ALLOW_UNTRUSTED_MIRROR=1 to allow."
        exit 1
      fi
      # Show security warning for untrusted mirror
      echo "" >&2
      log_warn "┌─────────────────────────────────────────────────────────────┐"
      log_warn "│ SECURITY WARNING: Untrusted Mirror Enabled                  │"
      log_warn "└─────────────────────────────────────────────────────────────┘"
      log_warn "Mirror URL: $base"
      log_warn "You have enabled CHECK_AI_CLI_ALLOW_UNTRUSTED_MIRROR=1"
      log_warn "Files will be downloaded from an untrusted source."
      log_warn "This could expose you to supply chain attacks."
      echo "" >&2
      sleep 3
    fi
    echo "$base"
    return 0
  fi
  echo "https://raw.githubusercontent.com/IIXINGCHEN/Check-AI-CLI/$(get_resolved_ref)"
}

clamp_retry
BASE=""
INSTALL_DIR="${CHECK_AI_CLI_INSTALL_DIR:-.}"

log_info() { printf "[INFO] %s\n" "$*"; }
log_ok() { printf "[SUCCESS] %s\n" "$*"; }
log_warn() { printf "[WARNING] %s\n" "$*"; }
log_err() { printf "[ERROR] %s\n" "$*"; }

PROGRESS_ACTIVE=0
PROGRESS_WIDTH=20
PROGRESS_TOTAL_BYTES=1
PROGRESS_CURRENT_BYTES=0
PROGRESS_SIZE_PLAN=""

command_exists() { command -v "$1" >/dev/null 2>&1; }

require_fetch_tool() {
  if command_exists curl || command_exists wget; then return 0; fi
  log_err "curl/wget not found. Install curl or wget first."
  return 1
}

ensure_parent_dir() {
  local path="$1"
  mkdir -p "$(dirname "$path")"
}

show_progress_enabled() {
  [ "${CHECK_AI_CLI_SHOW_PROGRESS:-0}" = "1" ] && [ -t 1 ]
}

repeat_char() {
  local char="$1" count="$2" text=""
  while [ "$count" -gt 0 ]; do
    text="${text}${char}"
    count=$((count - 1))
  done
  printf '%s' "$text"
}

byte_progress_percent() {
  local current="$1" total="$2" percent=0
  if ! is_number "$total" || [ "$total" -lt 1 ]; then printf '0'; return 0; fi
  if ! is_number "$current" || [ "$current" -lt 0 ]; then current=0; fi
  percent=$((current * 100 / total))
  if [ "$percent" -gt 100 ]; then percent=100; fi
  printf '%s' "$percent"
}

render_byte_progress() {
  local current="$1" total="$2" width="${3:-20}" percent fill empty
  percent="$(byte_progress_percent "$current" "$total")"
  fill=$((percent * width / 100))
  empty=$((width - fill))
  printf '[%s%s] %s%%' \
    "$(repeat_char '#' "$fill")" \
    "$(repeat_char '.' "$empty")" \
    "$percent"
}

write_byte_progress() {
  [ "$PROGRESS_ACTIVE" -eq 1 ] || return 0
  printf '\r%s' "$(render_byte_progress "$PROGRESS_CURRENT_BYTES" "$PROGRESS_TOTAL_BYTES" "$PROGRESS_WIDTH")"
}

close_byte_progress() {
  [ "$PROGRESS_ACTIVE" -eq 1 ] || return 0
  printf '\r%s\n' "$(render_byte_progress "$PROGRESS_CURRENT_BYTES" "$PROGRESS_TOTAL_BYTES" "$PROGRESS_WIDTH")"
  PROGRESS_ACTIVE=0
}

start_byte_progress() {
  show_progress_enabled || return 1
  PROGRESS_ACTIVE=1
  PROGRESS_CURRENT_BYTES=0
  PROGRESS_TOTAL_BYTES=1
  return 0
}

set_byte_progress_total() {
  local total="$1"
  is_number "$total" || return 1
  [ "$total" -gt 0 ] || return 1
  PROGRESS_TOTAL_BYTES="$total"
}

add_byte_progress() {
  local bytes="$1"
  is_number "$bytes" || bytes=0
  PROGRESS_CURRENT_BYTES=$((PROGRESS_CURRENT_BYTES + bytes))
  if [ "$PROGRESS_CURRENT_BYTES" -gt "$PROGRESS_TOTAL_BYTES" ]; then
    PROGRESS_CURRENT_BYTES="$PROGRESS_TOTAL_BYTES"
  fi
  write_byte_progress
}

file_size() {
  local path="$1"
  wc -c < "$path" | tr -d '[:space:]'
}

extract_content_length() {
  awk 'tolower($1)=="content-length:" {gsub("\r","",$2); value=$2} END {if (value ~ /^[0-9]+$/) print value}'
}

get_remote_file_size() {
  local url="$1" size=""
  if command_exists curl; then size="$(curl -fsSLI "$url" 2>/dev/null | extract_content_length || true)"; fi
  if [ -z "$size" ] && command_exists wget; then
    size="$(wget --server-response --spider "$url" 2>&1 | extract_content_length || true)"
  fi
  is_number "$size" || return 1
  [ "$size" -gt 0 ] || return 1
  printf '%s' "$size"
}

write_size_plan() {
  local manifest="$1" plan="$2" path size total=0
  : > "$plan"
  while read -r path; do
    [ -n "$path" ] || continue
    size="$(get_remote_file_size "$BASE/$path")" || return 1
    printf '%s\t%s\n' "$size" "$path" >> "$plan"
    total=$((total + size))
  done < <(list_manifest_paths "$manifest")
  printf '%s' "$total"
}

get_planned_size() {
  local plan="$1" path="$2"
  awk -F '\t' -v target="$path" '$2==target {print $1; exit 0}' "$plan"
}

prepare_byte_progress() {
  local manifest="$1" plan="$2" manifest_bytes payload_bytes total
  [ "$PROGRESS_ACTIVE" -eq 1 ] || return 1
  manifest_bytes="$(file_size "$manifest")"
  is_number "$manifest_bytes" || return 1
  payload_bytes="$(write_size_plan "$manifest" "$plan")" || return 1
  total=$((manifest_bytes + payload_bytes))
  set_byte_progress_total "$total" || return 1
  write_byte_progress
  add_byte_progress "$manifest_bytes"
}

fetch_to_temp() {
  local url="$1" tmp="$2"
  if command_exists curl; then
    curl -fsSL "$url" -o "$tmp"
    return 0
  fi
  if command_exists wget; then
    wget -qO "$tmp" "$url"
    return 0
  fi
  return 1
}

download_with_retry() {
  local url="$1" out="$2" tmp=""
  tmp="${out}.download"
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
  local stage="$1" f size
  mkdir -p "$stage/scripts" "$stage/bin"
  while read -r f; do
    [ -n "$f" ] || continue
    if [ "$PROGRESS_ACTIVE" -ne 1 ]; then log_info "Downloading: $f"; fi
    download_with_retry "$BASE/$f" "$stage/$f" || return 1
    if [ "$PROGRESS_ACTIVE" -eq 1 ]; then
      size="$(get_planned_size "$PROGRESS_SIZE_PLAN" "$f")"
      if ! is_number "$size"; then size="$(file_size "$stage/$f")"; fi
      add_byte_progress "$size"
    fi
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
  log_warn "Tip: set CHECK_AI_CLI_SHOW_PROGRESS=1 to view byte progress."
}

skip_main() {
  [ "${CHECK_AI_CLI_SKIP_MAIN:-0}" = "1" ]
}

main() {
  local stage
  BASE="$(resolve_base)"
  stage="$(mktemp -d 2>/dev/null || mktemp -d -t check-ai-cli)"
  trap "rm -rf \"$stage\" >/dev/null 2>&1 || true" EXIT

  require_fetch_tool || exit 1
  download_manifest "$stage" || { log_err "Failed to download checksums.sha256"; exit 1; }
  require_sha256_tool || exit 1
  if start_byte_progress; then
    PROGRESS_SIZE_PLAN="$stage/download-sizes.tsv"
    if ! prepare_byte_progress "$stage/checksums.sha256" "$PROGRESS_SIZE_PLAN"; then
      PROGRESS_ACTIVE=0
      rm -f "$PROGRESS_SIZE_PLAN" >/dev/null 2>&1 || true
      log_warn "Progress disabled: could not resolve remote content lengths."
    fi
  fi
  download_all "$stage" || { close_byte_progress || true; log_err "Download failed."; exit 1; }
  close_byte_progress || true
  verify_all "$stage" || { log_err "Checksum verification failed."; exit 1; }
  deploy_all "$stage" "$INSTALL_DIR" || { log_err "Deploy failed."; exit 1; }
  print_next_steps "$INSTALL_DIR"
}

if ! skip_main; then
  main
fi
