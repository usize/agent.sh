#!/usr/bin/env bash
# agents.sh — tmux panes for sandboxed Claude Code agents
# source /path/to/agents.sh

: "${AGENT_DIR:=.agents}"
: "${AGENT_SANDBOX_ARGS:=}"

# Environment variables to forward into sandboxes when set.
# Override with: AGENT_SANDBOX_ENV_VARS=(MY_VAR OTHER_VAR)
if [[ -z "${AGENT_SANDBOX_ENV_VARS+x}" ]]; then
  AGENT_SANDBOX_ENV_VARS=(
    CLAUDE_CODE_USE_VERTEX
    CLOUD_ML_REGION
    ANTHROPIC_VERTEX_PROJECT_ID
    ANTHROPIC_MODEL
    GOOGLE_CLOUD_PROJECT
    GOOGLE_APPLICATION_CREDENTIALS
  )
fi

_a_env_flags() {
  local flags="" val
  for var in "${AGENT_SANDBOX_ENV_VARS[@]}"; do
    val="$(printenv "$var" 2>/dev/null)" || continue
    [[ -n "$val" ]] && flags+=" -e ${var}=${val}"
  done
  echo "$flags"
}

_a_err()  { printf "\033[31m[agents] %s\033[0m\n" "$*" >&2; }
_a_info() { printf "\033[34m[agents] %s\033[0m\n" "$*" >&2; }

_a_worktree() {
  local name="$1"
  local root; root="$(git rev-parse --show-toplevel 2>/dev/null)" || { _a_err "not in a git repo"; return 1; }
  local ws="${root}/${AGENT_DIR}/${name}"
  if [[ ! -d "$ws" ]]; then
    mkdir -p "${root}/${AGENT_DIR}"
    grep -qxF "/${AGENT_DIR}/" "${root}/.gitignore" 2>/dev/null \
      || echo "/${AGENT_DIR}/" >> "${root}/.gitignore"
    git worktree add -b "agent/${name}" "$ws" HEAD >/dev/null 2>&1 \
      || git worktree add "$ws" HEAD >/dev/null 2>&1 \
      || { _a_err "worktree failed"; return 1; }
  fi
  echo "$ws"
}

_a_tmux() {
  local label="$1" layout="$2" cmd="$3"
  if [[ -z "${TMUX:-}" ]]; then eval "$cmd"; return; fi
  case "$layout" in
    here)   tmux rename-window "$label"; eval "$cmd" ;;
    window) tmux new-window -n "$label" "$cmd" ;;
    vsplit) tmux split-window -v -p 50 "$cmd"; tmux select-pane -T "$label" ;;
    hsplit) tmux split-window -h -p 50 "$cmd"; tmux select-pane -T "$label" ;;
  esac
}

agents() {
  local cmd="${1:-help}"; shift 2>/dev/null
  case "$cmd" in

  start)
    local layout="here" agent_type="claude" name="" extra=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        -w) layout="window"; shift;;
        -v) layout="vsplit"; shift;;
        -h) layout="hsplit"; shift;;
        --) shift; extra="$*"; break;;
        -*) _a_err "unknown flag: $1"; return 1;;
        *) break;;
      esac
    done
    if [[ $# -gt 1 ]]; then
      agent_type="$1"; shift
      name="$1"; shift
      extra="$*"
    elif [[ $# -eq 1 ]]; then
      name="$1"; shift
    fi

    [[ -z "$name" ]] && { _a_err "usage: agents start [-wvh] [agent] <name> [-- args]"; return 1; }
    
    _a_info "starting agent..."
    _a_info "creating worktree..."
    local ws; ws="$(_a_worktree "$name")" || return 1
    _a_info "worktree at: ${ws}"
    
    _a_info "checking sandbox status..."
    local existing_sandbox
    existing_sandbox=$(docker sandbox ls -q | grep "^${name}$" || true)

    if [[ -z "$existing_sandbox" ]]; then
      _a_info "creating sandbox..."
      docker sandbox create ${AGENT_SANDBOX_ARGS} --name "${name}" "${agent_type}" "${ws}" \
        || { _a_err "sandbox create failed"; return 1; }
    fi

    # persist agent type for ls
    echo "${agent_type}" > "${ws}/.agent-type"

    local env_flags; env_flags="$(_a_env_flags)"
    local sandbox_cmd
    if [[ -n "$env_flags" ]]; then
      _a_info "starting with env vars..."
      sandbox_cmd="docker sandbox exec -it${env_flags} ${name} ${agent_type}"
      [[ -n "$extra" ]] && sandbox_cmd="${sandbox_cmd} ${extra}"
    else
      _a_info "starting sandbox..."
      sandbox_cmd="docker sandbox run ${name}"
      [[ -n "$extra" ]] && sandbox_cmd="${sandbox_cmd} -- ${extra}"
    fi
    _a_info "sandbox command: ${sandbox_cmd}"

    _a_info "launching in tmux..."
    _a_tmux "${agent_type}:${name}" "$layout" "$sandbox_cmd"
    _a_info "tmux command finished."
    ;;

  ls)
    local root; root="$(git rev-parse --show-toplevel 2>/dev/null)" || { _a_err "not in a repo"; return 1; }
    local found=0

    printf "  %-20s %-10s %s\n" "NAME" "TYPE" "SANDBOX"
    for d in "${root}/${AGENT_DIR}"/*/; do
      [[ -d "$d" ]] || continue
      local n; n="$(basename "$d")"
      local atype="unknown"
      [[ -f "${d}/.agent-type" ]] && atype="$(<"${d}/.agent-type")"
      local status="none"
      docker sandbox ls -q 2>/dev/null | grep -qx "$n" && status="created"
      printf "  %-20s %-10s %s\n" "$n" "$atype" "$status"
      found=1
    done
    [[ $found -eq 0 ]] && echo "  (no agents)"

    if [[ -n "${TMUX:-}" ]]; then
      echo ""
      echo "  tmux:"
      tmux list-windows -F '    #{window_index}: #{window_name}#{?window_active, *,}' \
        | grep -E 'claude:|gemini:|opencode:' || true
    fi
    ;;

  kill)
    local name="${1:?usage: agents kill <name>}"
    if [[ -n "${TMUX:-}" ]]; then
      local wid; wid=$(tmux list-windows -F '#{window_id} #{window_name}' \
        | grep ":${name}$" | awk '{print $1}' | head -1)
      if [[ -n "$wid" ]]; then tmux kill-window -t "$wid"
      else
        local pid; pid=$(tmux list-panes -a -F '#{pane_id} #{pane_title}' \
          | grep ":${name}$" | awk '{print $1}' | head -1)
        [[ -n "$pid" ]] && tmux kill-pane -t "$pid"
      fi
    fi
    docker sandbox stop "${name}" 2>/dev/null
    _a_info "killed: $name"
    ;;

  clean)
    local name="${1:-}"
    if [[ -z "$name" ]]; then
      _a_err "usage: agents clean <name> | --all"
      return 1
    fi

    local root; root="$(git rev-parse --show-toplevel 2>/dev/null)" || { _a_err "not in a repo"; return 1; }

    if [[ "$name" == "--all" ]]; then
      for d in "${root}/${AGENT_DIR}"/*/; do
        [[ -d "$d" ]] || continue
        local n; n="$(basename "$d")"
        docker sandbox rm "${n}" 2>/dev/null
        git worktree remove --force "$d" 2>/dev/null
        git branch -D "agent/${n}" 2>/dev/null
        _a_info "  $n"
      done
      rmdir "${root}/${AGENT_DIR}" 2>/dev/null
      _a_info "done"
    else
      docker sandbox rm "${name}" 2>/dev/null
      git worktree remove --force "${root}/${AGENT_DIR}/${name}" 2>/dev/null
      git branch -D "agent/${name}" 2>/dev/null
      _a_info "cleaned: $name"
    fi
    ;;

  help|--help|-\?)
    cat <<'EOF'
agents — tmux panes for sandboxed Claude Code agents

  agents start [-wvh] [agent] <name> [-- args]
  agents ls
  agents kill  <name>
  agents clean <name> | --all

Layout: (default) here  -w window  -v vsplit  -h hsplit
Env: AGENT_DIR (.agents)  AGENT_SANDBOX_ARGS (extra docker sandbox flags)
EOF
    ;;

  *) _a_err "unknown: $cmd"; agents help ;;
  esac
}
