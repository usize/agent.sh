#!/usr/bin/env bash
# Tests for sandbox command redaction.
set -euo pipefail

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

# The redaction pattern used in agent.sh
_redact() {
  printf '%s' "$1" | sed 's/-e \([A-Za-z_][A-Za-z_0-9]*\)=[^ ]*/-e \1=***/g'
}

# ---------------------------------------------------------------------------
echo "=== redaction: basic ==="

input="docker sandbox exec -it -w /path -e FOO=bar -e SECRET=hunter2 mybox claude"
result="$(_redact "$input")"

_assert_contains "key FOO preserved" "$result" "-e FOO=***"
_assert_contains "key SECRET preserved" "$result" "-e SECRET=***"
_assert_not_contains "value bar hidden" "$result" "=bar"
_assert_not_contains "value hunter2 hidden" "$result" "hunter2"
_assert_contains "non-env parts intact" "$result" "docker sandbox exec -it -w /path"
_assert_contains "trailing args intact" "$result" "mybox claude"

# ---------------------------------------------------------------------------
echo ""
echo "=== redaction: complex values ==="

input="docker exec -e TOKEN=github_pat_11B2IYNNI0UWNuQ6GMBtjx -e PATH=/usr/bin:/usr/local/bin box cmd"
result="$(_redact "$input")"

_assert_not_contains "long token hidden" "$result" "github_pat"
_assert_not_contains "path value hidden" "$result" "/usr/bin"
_assert_contains "TOKEN key preserved" "$result" "-e TOKEN=***"
_assert_contains "PATH key preserved" "$result" "-e PATH=***"

# ---------------------------------------------------------------------------
echo ""
echo "=== redaction: fallback command (||) ==="

input="docker exec -e A=1 box cmd --continue || docker exec -e A=1 box cmd"
result="$(_redact "$input")"

_assert "both sides redacted" "$result" "docker exec -e A=*** box cmd --continue || docker exec -e A=*** box cmd"

# ---------------------------------------------------------------------------
echo ""
echo "=== redaction: no env vars ==="

input="docker sandbox run mybox -- --dangerously-skip-permissions"
result="$(_redact "$input")"

_assert "unchanged without -e flags" "$result" "$input"

# ---------------------------------------------------------------------------
echo ""
echo "=== summary ==="
printf "  %d passed, %d failed\n" "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
