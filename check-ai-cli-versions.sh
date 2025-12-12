#!/usr/bin/env bash
set -euo pipefail

# Legacy wrapper: real script is in scripts/
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "$DIR/scripts/check-ai-cli-versions.sh" "$@"
