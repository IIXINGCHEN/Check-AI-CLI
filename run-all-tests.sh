#!/usr/bin/env bash
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TESTS_DIR="$REPO_ROOT/tests"

echo "Test runner: bash"
echo ""

shopt -s nullglob
test_files=("$TESTS_DIR"/*.sh)
shopt -u nullglob

echo "Found ${#test_files[@]} shell test file(s)."
echo ""

passed=()
failed=()

for test_file in "${test_files[@]}"; do
  label="$(basename "$test_file")"
  echo "=== $label ==="
  exit_code=0
  bash "$test_file" 2>&1 || exit_code=$?
  if [ "$exit_code" -eq 0 ]; then
    echo "PASS: $label"
    passed+=("$label")
  else
    echo "FAIL: $label (exit code $exit_code)"
    failed+=("$label")
  fi
  echo ""
done

echo "==========================================="
echo "Results: ${#passed[@]} passed, ${#failed[@]} failed"

if [ "${#failed[@]}" -gt 0 ]; then
  echo ""
  echo "Failed tests:"
  for f in "${failed[@]}"; do echo "  - $f"; done
  exit 1
fi

echo "All tests passed."
