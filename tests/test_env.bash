#!/usr/bin/env bash
# Tests for env file loading, allowlist filtering, and sandbox naming.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/helpers.bash"
set +u  # agent.sh checks $ZSH_EVAL_CONTEXT which is unset in bash
source "${SCRIPT_DIR}/../agent.sh"
set -u

TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

# ---------------------------------------------------------------------------
echo "=== _a_load_env_file: allowlist filtering ==="

cat > "${TMPDIR}/mixed.env" <<'EOF'
CLAUDE_CODE_USE_VERTEX=1
CLOUD_ML_REGION=us-east5
export ANTHROPIC_VERTEX_PROJECT_ID="my-project"
ANTHROPIC_MODEL=claude-opus-4-6
AWS_API_KEY=AKIAIOSFODNN7EXAMPLE
OPENAI_API_KEY=sk-proj-secret
GITHUB_TOKEN=github_pat_secret
RANDOM_SECRET=supersecret
EOF

result="$(_a_load_env_file "${TMPDIR}/mixed.env")"

_assert_contains "allows CLAUDE_CODE_USE_VERTEX" "$result" "-e CLAUDE_CODE_USE_VERTEX=1"
_assert_contains "allows CLOUD_ML_REGION" "$result" "-e CLOUD_ML_REGION=us-east5"
_assert_contains "allows ANTHROPIC_VERTEX_PROJECT_ID" "$result" "-e ANTHROPIC_VERTEX_PROJECT_ID=my-project"
_assert_contains "allows ANTHROPIC_MODEL" "$result" "-e ANTHROPIC_MODEL=claude-opus-4-6"
_assert_not_contains "blocks AWS_API_KEY" "$result" "AWS_API_KEY"
_assert_not_contains "blocks OPENAI_API_KEY" "$result" "OPENAI_API_KEY"
_assert_not_contains "blocks GITHUB_TOKEN" "$result" "GITHUB_TOKEN"
_assert_not_contains "blocks RANDOM_SECRET" "$result" "RANDOM_SECRET"

# Count total flags
count=$(echo "$result" | grep -o '\-e ' | wc -l | tr -d ' ')
_assert "exactly 4 env flags" "$count" "4"

# ---------------------------------------------------------------------------
echo ""
echo "=== _a_load_env_file: empty/missing files ==="

result="$(_a_load_env_file "${TMPDIR}/nonexistent.env")"
_assert "missing file returns empty" "$result" ""

touch "${TMPDIR}/empty.env"
result="$(_a_load_env_file "${TMPDIR}/empty.env")"
_assert "empty file returns empty" "$result" ""

# ---------------------------------------------------------------------------
echo ""
echo "=== _a_load_env_file: comments and blank lines ==="

cat > "${TMPDIR}/comments.env" <<'EOF'
# This is a comment
  # Indented comment

CLAUDE_CODE_USE_VERTEX=1
   CLOUD_ML_REGION=us-west1
EOF

result="$(_a_load_env_file "${TMPDIR}/comments.env")"
_assert_contains "parses after comments" "$result" "-e CLAUDE_CODE_USE_VERTEX=1"
_assert_contains "trims leading whitespace" "$result" "-e CLOUD_ML_REGION=us-west1"
count=$(echo "$result" | grep -o '\-e ' | wc -l | tr -d ' ')
_assert "exactly 2 flags" "$count" "2"

# ---------------------------------------------------------------------------
echo ""
echo "=== _a_load_env_file: quote stripping ==="

cat > "${TMPDIR}/quotes.env" <<'EOF'
CLAUDE_CODE_USE_VERTEX="1"
CLOUD_ML_REGION='us-west1'
ANTHROPIC_MODEL=unquoted-value
EOF

result="$(_a_load_env_file "${TMPDIR}/quotes.env")"
_assert_contains "strips double quotes" "$result" "-e CLAUDE_CODE_USE_VERTEX=1"
_assert_contains "strips single quotes" "$result" "-e CLOUD_ML_REGION=us-west1"
_assert_contains "keeps unquoted value" "$result" "-e ANTHROPIC_MODEL=unquoted-value"

# ---------------------------------------------------------------------------
echo ""
echo "=== _a_load_env_file: custom allowlist ==="

AGENT_SANDBOX_ENV_VARS=(MY_CUSTOM_VAR ANOTHER_VAR)

cat > "${TMPDIR}/custom.env" <<'EOF'
MY_CUSTOM_VAR=hello
ANOTHER_VAR=world
CLAUDE_CODE_USE_VERTEX=1
EOF

result="$(_a_load_env_file "${TMPDIR}/custom.env")"
_assert_contains "allows custom var" "$result" "-e MY_CUSTOM_VAR=hello"
_assert_contains "allows second custom var" "$result" "-e ANOTHER_VAR=world"
_assert_not_contains "blocks non-custom var" "$result" "CLAUDE_CODE_USE_VERTEX"

# Restore default allowlist
AGENT_SANDBOX_ENV_VARS=(
  CLAUDE_CODE_USE_VERTEX
  CLOUD_ML_REGION
  ANTHROPIC_VERTEX_PROJECT_ID
  ANTHROPIC_MODEL
  GOOGLE_CLOUD_PROJECT
)

# ---------------------------------------------------------------------------
echo ""
echo "=== AGENT_DEFAULT_MODEL: config variable ==="

# default value
_assert "defaults to opus" "$AGENT_DEFAULT_MODEL" "opus"

# can be overridden
AGENT_DEFAULT_MODEL="sonnet"
_assert "accepts override" "$AGENT_DEFAULT_MODEL" "sonnet"

# restore
AGENT_DEFAULT_MODEL="opus"

# ---------------------------------------------------------------------------
echo ""
echo "=== _a_sandbox_name: repo-scoped naming ==="

_assert "scopes name with repo" "$(_a_sandbox_name "explorer" "/home/user/my-repo")" "my-repo-explorer"
_assert "scopes name with nested repo" "$(_a_sandbox_name "docs" "/a/b/kagenti-zoo")" "kagenti-zoo-docs"
_assert "handles hyphens in agent name" "$(_a_sandbox_name "my-agent" "/repo/root")" "root-my-agent"

# ---------------------------------------------------------------------------
_summary
