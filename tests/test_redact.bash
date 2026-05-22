#!/usr/bin/env bash
# Tests for sandbox command redaction.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/helpers.bash"

# Extract the actual sed pattern from agent.sh so tests stay in sync.
_redact() {
  local sed_pattern
  sed_pattern="$(grep -o "sed '[^']*'" "${SCRIPT_DIR}/../agent.sh" | head -1)"
  printf '%s' "$1" | eval "$sed_pattern"
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
_summary
