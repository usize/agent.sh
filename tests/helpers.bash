#!/usr/bin/env bash
# Shared test helpers. Source this from each test_*.bash file.

PASS=0
FAIL=0

_assert() {
  local label="$1" result="$2" expected="$3"
  if [[ "$result" == "$expected" ]]; then
    printf "  \033[32mPASS\033[0m %s\n" "$label"
    ((PASS++)) || true
  else
    printf "  \033[31mFAIL\033[0m %s\n" "$label"
    printf "       expected: %s\n" "$expected"
    printf "       got:      %s\n" "$result"
    ((FAIL++)) || true
  fi
}

_assert_contains() {
  local label="$1" haystack="$2" needle="$3"
  if echo "$haystack" | grep -qF "$needle"; then
    printf "  \033[32mPASS\033[0m %s\n" "$label"
    ((PASS++)) || true
  else
    printf "  \033[31mFAIL\033[0m %s\n" "$label"
    printf "       expected to contain: %s\n" "$needle"
    ((FAIL++)) || true
  fi
}

_assert_not_contains() {
  local label="$1" haystack="$2" needle="$3"
  if echo "$haystack" | grep -qF "$needle"; then
    printf "  \033[31mFAIL\033[0m %s\n" "$label"
    printf "       should not contain: %s\n" "$needle"
    ((FAIL++)) || true
  else
    printf "  \033[32mPASS\033[0m %s\n" "$label"
    ((PASS++)) || true
  fi
}

_summary() {
  echo ""
  echo "=== summary ==="
  printf "  %d passed, %d failed\n" "$PASS" "$FAIL"
  [[ $FAIL -eq 0 ]]
}
