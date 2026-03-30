#!/usr/bin/env bash
# agents.sh — tmux panes for sandboxed Claude Code agents
# source /path/to/agents.sh

: "${AGENT_DIR:=.agents}"
: "${AGENT_SANDBOX_ARGS:=}"

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
    existing_sandbox=$(docker sandbox ls -q | grep "^agent-${name}$" || true)

    local sandbox_cmd
    if [[ -z "$existing_sandbox" ]]; then
      _a_info "creating new sandbox..."
      sandbox_cmd="docker sandbox run ${AGENT_SANDBOX_ARGS} --name agent-${name} ${agent_type} '${ws}'"
      [[ -n "$extra" ]] && sandbox_cmd="${sandbox_cmd} -- ${extra}"
    else
      _a_info "running existing sandbox..."
      sandbox_cmd="docker sandbox run agent-${name}"
      [[ -n "$extra" ]] && sandbox_cmd="${sandbox_cmd} -- ${extra}"
    fi
    _a_info "sandbox command: ${sandbox_cmd}"

    _a_info "launching in tmux..."
    _a_tmux "${agent_type}:${name}" "$layout" "$sandbox_cmd"
    _a_info "tmux command finished."
    ;;

  ls)
    if [[ -n "${TMUX:-}" ]]; then
      tmux list-windows -F '  #{window_index}: #{window_name}#{?window_active, *,}' \
        | grep -E 'agent:|claude:|gemini:|opencode:' || echo "  (no agent windows)"
      tmux list-panes -a -F '  #{window_name}/#{pane_index}: #{pane_title}' \
        | grep -E 'agent:|claude:|gemini:|opencode:' 2>/dev/null
    fi
    echo ""
    docker sandbox ls 2>/dev/null | grep -E 'agent-|NAME' || true
    echo ""
    git worktree list 2>/dev/null | grep "${AGENT_DIR}" || true
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
    docker sandbox stop "agent-${name}" 2>/dev/null
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
        docker sandbox rm "agent-${n}" 2>/dev/null
        git worktree remove --force "$d" 2>/dev/null
        git branch -D "agent/${n}" 2>/dev/null
        _a_info "  $n"
      done
      rmdir "${root}/${AGENT_DIR}" 2>/dev/null
      _a_info "done"
    else
      docker sandbox rm "agent-${name}" 2>/dev/null
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
