#!/usr/bin/env bash
# Run all tests in the tests/ directory.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOTAL_PASS=0
TOTAL_FAIL=0
SUITES=0
FAILED_SUITES=()

for t in "${SCRIPT_DIR}"/test_*.bash; do
  [[ -f "$t" ]] || continue
  suite="$(basename "$t" .bash)"
  ((SUITES++))
  echo "--- ${suite} ---"
  if bash "$t"; then
    echo ""
  else
    FAILED_SUITES+=("$suite")
    echo ""
  fi
done

echo "=== ${SUITES} suite(s) run ==="
if [[ ${#FAILED_SUITES[@]} -gt 0 ]]; then
  printf "\033[31mFailed: %s\033[0m\n" "${FAILED_SUITES[*]}"
  exit 1
else
  printf "\033[32mAll suites passed.\033[0m\n"
fi
