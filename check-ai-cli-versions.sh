#!/usr/bin/env bash
set -euo pipefail

# 中文注释: 兼容入口, 实际脚本在 scripts 目录
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "$DIR/scripts/check-ai-cli-versions.sh" "$@"

