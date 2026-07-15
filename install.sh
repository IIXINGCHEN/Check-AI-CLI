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

is_commit_sha() {
  [[ "${1:-}" =~ ^[a-fA-F0-9]{40}$ ]]
}

is_release_tag() {
  [[ "${1:-}" =~ ^v[0-9]+\.[0-9]+\.[0-9]+([-+][0-9A-Za-z.-]+)?$ ]]
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
  local requested stable main_commit
  if has_explicit_ref; then
    requested="$(get_requested_ref)"
    if is_commit_sha "$requested"; then
      printf '%s' "$requested" | tr '[:upper:]' '[:lower:]'
      return 0
    fi
    if is_release_tag "$requested"; then
      printf '%s' "$requested"
      return 0
    fi
    if [ "$requested" = 'main' ]; then
      main_commit="$(get_latest_main_commit_ref || true)"
      if is_commit_sha "$main_commit"; then
        printf '%s' "$main_commit" | tr '[:upper:]' '[:lower:]'
        return 0
      fi
      log_err 'Failed to resolve CHECK_AI_CLI_REF=main to an immutable commit SHA.' >&2
      return 1
    fi
    log_err "CHECK_AI_CLI_REF must be a semantic-version tag, a 40-character commit SHA, or main: $requested" >&2
    return 1
  fi
  stable="$(get_latest_stable_ref || true)"
  if is_release_tag "$stable"; then printf '%s' "$stable"; return 0; fi
  main_commit="$(get_latest_main_commit_ref || true)"
  if is_commit_sha "$main_commit"; then printf '%s' "$main_commit" | tr '[:upper:]' '[:lower:]'; return 0; fi
  log_err 'Failed to resolve an immutable release tag or main commit. Refusing mutable main fallback.' >&2
  return 1
}

resolve_base() {
  local base resolved_ref
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
  resolved_ref="$(get_resolved_ref)" || return 1
  echo "https://raw.githubusercontent.com/IIXINGCHEN/Check-AI-CLI/$resolved_ref"
}

clamp_retry
BASE=""
INSTALL_DIR="${CHECK_AI_CLI_INSTALL_DIR:-.}"
SCRIPT_ROOT=""
if [ -f "${BASH_SOURCE[0]:-}" ]; then
  SCRIPT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fi

log_info() { printf "[INFO] %s\n" "$*" >&2; }
log_ok() { printf "[SUCCESS] %s\n" "$*" >&2; }
log_warn() { printf "[WARNING] %s\n" "$*" >&2; }
log_err() { printf "[ERROR] %s\n" "$*" >&2; }

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

fetch_to_temp() {
  local url="$1" tmp="$2"
  if command_exists curl; then
    curl -fSL --progress-bar "$url" -o "$tmp"
    return 0
  fi
  if command_exists wget; then
    wget --progress=bar:force:noscroll -O "$tmp" "$url" || wget -O "$tmp" "$url"
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

assert_manifest_anchor() {
  local manifest="$1" expected actual
  expected="$(printf '%s' "${CHECK_AI_CLI_EXPECTED_MANIFEST_SHA256:-}" | tr '[:upper:]' '[:lower:]')"
  [ -n "$expected" ] || return 0
  if [[ ! "$expected" =~ ^[a-f0-9]{64}$ ]]; then
    log_err 'CHECK_AI_CLI_EXPECTED_MANIFEST_SHA256 must contain exactly 64 hexadecimal characters.'
    return 1
  fi
  actual="$(sha256_file "$manifest" 2>/dev/null | tr '[:upper:]' '[:lower:]')" || actual=''
  if [ "$actual" != "$expected" ]; then
    log_err 'checksums.sha256 does not match CHECK_AI_CLI_EXPECTED_MANIFEST_SHA256.'
    return 1
  fi
  log_ok 'Manifest SHA-256 pin verified.'
}

validate_distribution_path() {
  local path="$1" segment
  [ -n "$path" ] || { log_err 'Distribution path is empty.'; return 1; }
  [[ "$path" != /* && "$path" != *'\'* && "$path" != *:* ]] || {
    log_err "Invalid distribution path: $path"
    return 1
  }
  [[ "$path" != *$'\n'* && "$path" != *$'\r'* && "$path" != *[[:space:]]* && "$path" != *'|'* ]] || {
    log_err "Invalid distribution path: $path"
    return 1
  }
  IFS='/' read -r -a segments <<< "$path"
  for segment in "${segments[@]}"; do
    if [ -z "$segment" ] || [ "$segment" = '.' ] || [ "$segment" = '..' ]; then
      log_err "Invalid distribution path: $path"
      return 1
    fi
  done
}

validate_manifest() {
  local manifest="$1" line hash path extra count=0
  local seen=""
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%$'\r'}"
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [ -n "$line" ] || continue
    [[ "$line" = \#* ]] && continue
    read -r hash path extra <<< "$line"
    if [ -z "${hash:-}" ] || [ -z "${path:-}" ] || [ -n "${extra:-}" ] ||
      [[ ! "$hash" =~ ^[a-fA-F0-9]{64}$ ]]; then
      log_err "Malformed checksum manifest line: $line"
      return 1
    fi
    validate_distribution_path "$path" || return 1
    case "|$seen|" in
      *"|$path|"*)
      log_err "Duplicate checksum entry: $path"
      return 1
      ;;
    esac
    seen="$seen|$path"
    count=$((count + 1))
  done < "$manifest"
  [ "$count" -gt 0 ] || { log_err 'Checksum manifest has no entries.'; return 1; }
}

list_manifest_paths() {
  local manifest="$1"
  awk 'NF>=2 && $1 !~ /^#/ {print $2}' "$manifest"
}

distribution_list_path() {
  printf '%s' 'distribution-files.txt'
}

list_distribution_paths() {
  local file_list="$1" line path
  local seen=""
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%$'\r'}"
    line="${line%%#*}"
    line="${line#${line%%[![:space:]]*}}"
    line="${line%${line##*[![:space:]]}}"
    [ -n "$line" ] || continue
    path="$line"
    validate_distribution_path "$path" || return 1
    case "|$seen|" in
      *"|$path|"*)
      log_err "Duplicate distribution path: $path"
      return 1
      ;;
    esac
    seen="$seen|$path"
    printf '%s\n' "$path"
  done < "$file_list"
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
  local stage="$1" f paths
  mkdir -p "$stage/scripts" "$stage/bin"
  paths="$(list_distribution_paths "$stage/$(distribution_list_path)")" || return 1
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    log_info "Downloading: $f"
    download_with_retry "$BASE/$f" "$stage/$f" || return 1
  done <<< "$paths"
}

download_manifest() {
  local stage="$1"
  download_with_retry "$BASE/checksums.sha256" "$stage/checksums.sha256"
}

download_distribution_list() {
  local stage="$1" rel
  rel="$(distribution_list_path)"
  download_with_retry "$BASE/$rel" "$stage/$rel"
  verify_hash "$stage/checksums.sha256" "$rel" "$stage/$rel"
}

verify_all() {
  local stage="$1" f paths
  paths="$(list_distribution_paths "$stage/$(distribution_list_path)")" || return 1
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    verify_hash "$stage/checksums.sha256" "$f" "$stage/$f" || return 1
  done <<< "$paths"
}

write_install_marker() {
  local dir="$1"
  printf 'Check-AI-CLI\n' > "$dir/.check-ai-cli-installed"
}

resolve_install_dir() {
  local dir="$1"
  [[ "$dir" != *$'\n'* && "$dir" != *$'\r'* && "$dir" != *$'\t'* && -n "$dir" ]] || {
    log_err 'CHECK_AI_CLI_INSTALL_DIR must be a non-empty path without newlines.'
    return 1
  }
  mkdir -p "$dir"
  (cd "$dir" && pwd)
}

restore_deploy() {
  local records="$1" existed backup target
  while IFS=$'\t' read -r existed backup target; do
    [ -n "$target" ] || continue
    if [ "$existed" = "1" ]; then
      cp -a "$backup" "$target" 2>/dev/null || true
    else
      rm -f -- "$target" 2>/dev/null || true
    fi
  done < "$records"
}

deploy_one() {
  local stage="$1" dir="$2" rel="$3" src dst tmp
  src="$stage/$rel"
  dst="$dir/$rel"
  tmp="$dst.new"
  ensure_parent_dir "$dst"
  cp -f "$src" "$tmp" || { rm -f -- "$tmp"; return 1; }
  mv -f "$tmp" "$dst" || { rm -f -- "$tmp"; return 1; }
}

deploy_all() {
  local stage="$1" dir="$2" f paths rollback records backup target existed rc idx=0
  mkdir -p "$dir/scripts" "$dir/bin"
  rollback="$(mktemp -d)" || return 1
  records="$rollback/records"
  : > "$records"
  paths="$(list_distribution_paths "$stage/$(distribution_list_path)")" || {
    rm -rf -- "$rollback"
    return 1
  }
  while read -r f; do
    [ -n "$f" ] || continue
    target="$dir/$f"
    if [ -e "$target" ]; then
      backup="$rollback/$idx"
      cp -a "$target" "$backup" || {
        restore_deploy "$records"
        rm -rf -- "$rollback"
        return 1
      }
      existed="1"
    else
      backup=""
      existed="0"
    fi
    printf '%s\t%s\t%s\n' "$existed" "$backup" "$target" >> "$records"
    deploy_one "$stage" "$dir" "$f" || {
      rc=$?
      restore_deploy "$records"
      rm -rf -- "$rollback"
      return "$rc"
    }
    idx=$((idx + 1))
  done <<< "$paths"
  rm -rf -- "$rollback"
}

get_profile_file() {
  local shell_name
  shell_name="$(basename "${SHELL:-bash}")"
  case "$shell_name" in
    fish) printf '%s\n' "$HOME/.config/fish/config.fish" ;;
    zsh) printf '%s\n' "${ZDOTDIR:-$HOME}/.zshrc" ;;
    bash) [ -f "$HOME/.bashrc" ] && printf '%s\n' "$HOME/.bashrc" || printf '%s\n' "$HOME/.profile" ;;
    *) printf '%s\n' "$HOME/.profile" ;;
  esac
}

add_to_path() {
  local dir="$1" file marker tmp shell_name
  file="$(get_profile_file)"
  marker="check-ai-cli:path:$(printf '%s' "$dir" | tr '/\\: .' '_')"
  mkdir -p "$(dirname "$file")"
  [ -f "$file" ] || : > "$file"
  if grep -qF "$marker" "$file" 2>/dev/null; then
    log_info "PATH entry already present for $dir"
    return 0
  fi
  tmp="$file.tmp.$$"
  grep -Fv "$marker" "$file" > "$tmp" 2>/dev/null || true
  shell_name="$(basename "${SHELL:-bash}")"
  if [ "$shell_name" = "fish" ]; then
    printf "fish_add_path -m '%s' # %s\n" "$(printf '%s' "$dir" | sed "s/'/'\\\\''/g")" "$marker" >> "$tmp"
  else
    printf "export PATH='%s':\$PATH # %s\n" "$(printf '%s' "$dir" | sed "s/'/'\\\\''/g")" "$marker" >> "$tmp"
  fi
  mv "$tmp" "$file"
  export PATH="$dir:$PATH"
  log_info "Added $dir to PATH permanently"
}

print_next_steps() {
  local dir="$1"
  chmod +x "$dir/scripts/check-ai-cli-versions.sh" 2>/dev/null || true
  chmod +x "$dir/bin/check-ai-cli" 2>/dev/null || true
  chmod +x "$dir/uninstall.sh" 2>/dev/null || true
  log_ok "Installed to: $dir"
  add_to_path "$dir/bin"
  printf "\nNext:\n  check-ai-cli\n\n"
  log_warn "Tip: set CHECK_AI_CLI_REF to pin a tag/commit for stability."
  log_warn "Tip: prefer HTTP_PROXY/HTTPS_PROXY instead of third-party mirrors."
}

skip_main() {
  [ "${CHECK_AI_CLI_SKIP_MAIN:-0}" = "1" ]
}

get_local_payload_root() {
  [ -n "$SCRIPT_ROOT" ] || return 1
  [ -d "$SCRIPT_ROOT/.git" ] && return 1
  [ -f "$SCRIPT_ROOT/checksums.sha256" ] || return 1
  [ -f "$SCRIPT_ROOT/distribution-files.txt" ] || return 1
  printf '%s\n' "$SCRIPT_ROOT"
}

install_local_payload() {
  local root="$1"
  require_sha256_tool || return 1
  validate_manifest "$root/checksums.sha256" || return 1
  verify_all "$root" || return 1
  INSTALL_DIR="$(resolve_install_dir "$INSTALL_DIR")" || return 1
  write_install_marker "$INSTALL_DIR"
  deploy_all "$root" "$INSTALL_DIR" || return 1
  print_next_steps "$INSTALL_DIR"
}

main() {
  local stage local_root
  local_root="$(get_local_payload_root || true)"
  if [ -n "$local_root" ]; then
    install_local_payload "$local_root" || { log_err "Local payload verification or deployment failed."; exit 1; }
    return 0
  fi
  BASE="$(resolve_base)"
  stage="$(mktemp -d 2>/dev/null || mktemp -d -t check-ai-cli)"
  trap "rm -rf \"$stage\" >/dev/null 2>&1 || true" EXIT

  require_fetch_tool || exit 1
  download_manifest "$stage" || { log_err "Failed to download checksums.sha256"; exit 1; }
  require_sha256_tool || exit 1
  assert_manifest_anchor "$stage/checksums.sha256" || exit 1
  validate_manifest "$stage/checksums.sha256" || exit 1
  download_distribution_list "$stage" || { log_err "Failed to download distribution-files.txt"; exit 1; }
  download_all "$stage" || { log_err "Download failed."; exit 1; }
  verify_all "$stage" || { log_err "Checksum verification failed."; exit 1; }
  INSTALL_DIR="$(resolve_install_dir "$INSTALL_DIR")"
  write_install_marker "$INSTALL_DIR"
  deploy_all "$stage" "$INSTALL_DIR" || { log_err "Deploy failed."; exit 1; }
  print_next_steps "$INSTALL_DIR"
}

if ! skip_main; then
  main
fi
