#!/usr/bin/env bash
# agents.sh — tmux panes for sandboxed Claude Code agents
# source /path/to/agents.sh

: "${AGENT_DIR:=.agents}"
: "${AGENT_SANDBOX_ARGS:=}"
: "${AGENT_DEFAULT_MODEL:=opus}"

# Environment variables to forward into sandboxes when set.
# Override with: AGENT_SANDBOX_ENV_VARS=(MY_VAR OTHER_VAR)
if [[ -z "${AGENT_SANDBOX_ENV_VARS+x}" ]]; then
  AGENT_SANDBOX_ENV_VARS=(
    CLAUDE_CODE_USE_VERTEX
    CLOUD_ML_REGION
    ANTHROPIC_VERTEX_PROJECT_ID
    ANTHROPIC_MODEL
    GOOGLE_CLOUD_PROJECT
  )
fi

_a_load_env_file() {
  local file="$1"
  [[ -f "$file" ]] || return 0
  local flags="" line key value
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line#"${line%%[![:space:]]*}"}"   # trim leading whitespace
    [[ -z "$line" || "$line" == \#* ]] && continue
    line="${line#export }"                       # strip optional 'export' prefix
    [[ "$line" == *=* ]] || continue
    key="${line%%=*}"
    value="${line#*=}"
    # strip surrounding quotes
    if [[ "$value" =~ ^\"(.*)\"$ ]]; then
      value="${BASH_REMATCH[1]}"
    elif [[ "$value" =~ ^\'(.*)\'$ ]]; then
      value="${BASH_REMATCH[1]}"
    fi
    # only forward variables present in the allowlist
    local allowed=0
    for var in "${AGENT_SANDBOX_ENV_VARS[@]}"; do
      [[ "$var" == "$key" ]] && { allowed=1; break; }
    done
    [[ $allowed -eq 1 ]] || continue
    flags+=" -e ${key}=${value}"
  done < "$file"
  echo "$flags"
}

_a_env_flags() {
  local flags=""

  # 1. Global defaults (~/.agentsh.rc)
  flags+="$(_a_load_env_file "${HOME}/.agentsh.rc")"

  # 2. Project-level overrides ({repo}/.agentsh.env)
  local root
  root="$(git rev-parse --show-toplevel 2>/dev/null)" \
    && flags+="$(_a_load_env_file "${root}/.agentsh.env")"

  # 3. Shell environment (highest priority)
  local val
  for var in "${AGENT_SANDBOX_ENV_VARS[@]}"; do
    val="$(printenv "$var" 2>/dev/null)" || continue
    [[ -n "$val" ]] && flags+=" -e ${var}=${val}"
  done

  echo "$flags"
}

_a_err()  { printf "\033[31m[agents] %s\033[0m\n" "$*" >&2; }
_a_info() { printf "\033[34m[agents] %s\033[0m\n" "$*" >&2; }

# Sandbox names are scoped to the repo to avoid cross-project collisions.
_a_sandbox_name() {
  local name="$1" root="$2"
  local repo; repo="$(basename "$root")"
  echo "${repo}-${name}"
}

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

  # Detached mode works without being inside tmux
  if [[ "$layout" == "detach" ]]; then
    tmux new-session -d -x 200 -y 50 -n "$label" "$cmd"
    return
  fi

  if [[ -z "${TMUX:-}" ]]; then eval "$cmd"; return; fi

  local border_status; border_status="$(tmux show-option -gqv pane-border-status 2>/dev/null)"
  if [[ "$border_status" == "off" || -z "$border_status" ]]; then
    _a_err "tmux pane-border-status is off — pane titles won't be visible"
    _a_err "add to .tmux.conf: set -g pane-border-status top"
  fi

  case "$layout" in
    here)   eval "$cmd" ;;
    window) tmux new-window -n "$label" "$cmd" ;;
    vsplit) tmux split-window -v "$cmd"; tmux select-pane -T "$label"; tmux select-layout even-vertical ;;
    hsplit) tmux split-window -h "$cmd"; tmux select-pane -T "$label"; tmux select-layout even-horizontal ;;
  esac
}

_a_find_target() {
  local label="$1"
  local target
  target=$(tmux list-windows -a -F '#{session_id}:#{window_index} #{window_name}' \
    | grep " ${label}$" | head -1 | awk '{print $1}')
  if [[ -z "$target" ]]; then
    target=$(tmux list-panes -a -F '#{session_id}:#{window_index}.#{pane_index} #{pane_title}' \
      | grep " ${label}$" | head -1 | awk '{print $1}')
  fi
  echo "$target"
}

_a_wait_for_text() {
  local target="$1" text="$2" timeout="${3:-30}"
  local logfile="${AGENT_SETUP_LOG:-/dev/null}"
  local elapsed=0
  while (( elapsed < timeout )); do
    local pane_content
    pane_content="$(tmux capture-pane -t "$target" -p 2>/dev/null)" || true
    if echo "$pane_content" | grep -qF "$text"; then
      echo "[setup] found '$text' after ${elapsed}s on target $target" >> "$logfile"
      return 0
    fi
    sleep 2
    elapsed=$((elapsed + 2))
  done
  echo "[setup] TIMEOUT waiting for '$text' after ${timeout}s on target $target" >> "$logfile"
  echo "[setup] last pane content:" >> "$logfile"
  tmux capture-pane -t "$target" -p 2>/dev/null >> "$logfile" || true
  return 1
}

_a_inject_prompt() {
  local target="$1" prompt="$2"
  local logfile="${AGENT_SETUP_LOG:-/dev/null}"
  _a_wait_for_text "$target" "bypass permissions" 60 || return 1
  sleep 1
  tmux send-keys -t "$target" -l "$prompt"
  tmux send-keys -t "$target" Enter
  echo "[setup] injected prompt" >> "$logfile"
}

_a_first_run_setup() {
  local target="$1" model="${2:-opus}" prompt="${3:-}"
  local logfile="${AGENT_SETUP_LOG:-/dev/null}"
  echo "[setup] starting first-run setup: target=$target model=$model" >> "$logfile"

  # Screen 1: Theme — confirm default (dark mode is pre-selected)
  _a_wait_for_text "$target" "Choose the text style" 120 || return 1
  sleep 1
  tmux send-keys -t "$target" Enter
  echo "[setup] sent Enter for theme screen" >> "$logfile"

  # Screen 2: Security notice — press Enter
  _a_wait_for_text "$target" "Press Enter to continue" 30 || return 1
  sleep 1
  tmux send-keys -t "$target" Enter
  echo "[setup] sent Enter for security screen" >> "$logfile"

  # Screen 3: Trust workspace — press Enter
  _a_wait_for_text "$target" "trust this folder" 30 || return 1
  sleep 1
  tmux send-keys -t "$target" Enter
  echo "[setup] sent Enter for trust screen" >> "$logfile"

  # Screen 4: Main prompt — set the model
  _a_wait_for_text "$target" "bypass permissions" 30 || return 1
  sleep 1
  tmux send-keys -t "$target" "/model $model" Enter
  echo "[setup] sent /model $model for prompt screen" >> "$logfile"
  echo "[setup] first-run setup complete" >> "$logfile"

  # Inject prompt if provided
  if [[ -n "$prompt" ]]; then
    _a_wait_for_text "$target" "Set model to" 30 || return 1
    sleep 1
    tmux send-keys -t "$target" -l "$prompt"
    tmux send-keys -t "$target" Enter
    echo "[setup] injected prompt" >> "$logfile"
  fi
}

agents() {
  local cmd="${1:-help}"; shift 2>/dev/null
  case "$cmd" in

  start)
    local layout="here" agent_type="claude" name="" extra="" prompt="" model=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        -d) layout="detach"; shift;;
        -w) layout="window"; shift;;
        -v) layout="vsplit"; shift;;
        -h) layout="hsplit"; shift;;
        -p) prompt="$2"; shift 2;;
        -m) model="$2"; shift 2;;
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

    [[ -z "$name" ]] && { _a_err "usage: agents start [-dwvh] [-p prompt] [-m model] [agent] <name> [-- args]"; return 1; }
    
    _a_info "starting agent..."
    _a_info "creating worktree..."
    local ws; ws="$(_a_worktree "$name")" || return 1
    _a_info "worktree at: ${ws}"
    
    _a_info "checking sandbox status..."
    local root; root="$(git rev-parse --show-toplevel 2>/dev/null)"
    local sbox; sbox="$(_a_sandbox_name "$name" "$root")"
    local existing_sandbox
    existing_sandbox=$(docker sandbox ls -q | grep "^${sbox}$" || true)

    if [[ -z "$existing_sandbox" ]]; then
      _a_info "creating sandbox..."
      docker sandbox create ${AGENT_SANDBOX_ARGS} --name "${sbox}" "${agent_type}" "${ws}" "${root}/.git" \
        || { _a_err "sandbox create failed"; return 1; }
    fi

    # persist agent type for ls
    echo "${agent_type}" > "${ws}/.agent-type"

    # copy gcloud ADC into workspace so the sandbox can find them
    local adc="${HOME}/.config/gcloud/application_default_credentials.json"
    if [[ -f "$adc" ]]; then
      mkdir -p "${ws}/.gcloud"
      cp "$adc" "${ws}/.gcloud/application_default_credentials.json"
      # .gitignore it
      grep -qxF "/.gcloud/" "${ws}/.gitignore" 2>/dev/null \
        || echo "/.gcloud/" >> "${ws}/.gitignore"
    fi

    local env_flags; env_flags="$(_a_env_flags)"
    # -m flag overrides all config layers
    [[ -n "$model" ]] && env_flags+=" -e ANTHROPIC_MODEL=${model}"
    # point credentials at the workspace copy
    if [[ -f "${ws}/.gcloud/application_default_credentials.json" ]]; then
      env_flags+=" -e GOOGLE_APPLICATION_CREDENTIALS=${ws}/.gcloud/application_default_credentials.json"
    fi
    local resume_flag=""
    [[ -n "$existing_sandbox" ]] && resume_flag=" --continue"

    local base_flags="--dangerously-skip-permissions"
    [[ -n "$extra" ]] && base_flags="${base_flags} ${extra}"

    # write prompt as CLAUDE.md so the agent sees it on startup
    if [[ -n "$prompt" ]]; then
      printf '# Task\n\n%s\n' "$prompt" > "${ws}/CLAUDE.md"
    fi

    local sandbox_cmd
    if [[ -n "$env_flags" ]]; then
      local exec_prefix="docker sandbox exec -it -w '${ws}'${env_flags} ${sbox} ${agent_type}"
      if [[ -n "$resume_flag" ]]; then
        sandbox_cmd="${exec_prefix} ${base_flags} --continue || ${exec_prefix} ${base_flags}"
      else
        sandbox_cmd="${exec_prefix} ${base_flags}"
      fi
    else
      sandbox_cmd="docker sandbox run ${sbox}"
      if [[ -n "$resume_flag" ]]; then
        sandbox_cmd="${sandbox_cmd} -- ${base_flags} --continue || docker sandbox run ${sbox} -- ${base_flags}"
      elif [[ -n "$extra" ]]; then
        sandbox_cmd="${sandbox_cmd} -- ${base_flags}"
      fi
    fi
    local redacted_cmd
    redacted_cmd="$(printf '%s' "$sandbox_cmd" | sed 's/-e \([A-Za-z_][A-Za-z_0-9]*\)=[^ ]*/-e \1=***/g')"
    _a_info "sandbox command: ${redacted_cmd}"

    _a_info "launching in tmux..."

    # Auto-navigate first-run setup and inject prompt
    local setup_model="${model:-$AGENT_DEFAULT_MODEL}"
    local can_setup=false
    [[ -n "${TMUX:-}" || "$layout" == "detach" ]] && can_setup=true

    if [[ "$can_setup" == "true" && "$layout" == "here" ]]; then
      local here_target
      here_target="$(tmux display-message -p '#{session_id}:#{window_index}.#{pane_index}')"
      if [[ -z "$existing_sandbox" ]]; then
        _a_first_run_setup "$here_target" "$setup_model" "$prompt" &
      elif [[ -n "$prompt" ]]; then
        _a_inject_prompt "$here_target" "$prompt" &
      fi
    fi

    _a_tmux "${agent_type}:${name}" "$layout" "$sandbox_cmd"

    # For non-'here' layouts, _a_tmux returns immediately so start poller after
    if [[ "$can_setup" == "true" && "$layout" != "here" ]]; then
      local label="${agent_type}:${name}"
      local target; target="$(_a_find_target "$label")"
      if [[ -n "$target" ]]; then
        if [[ -z "$existing_sandbox" ]]; then
          _a_first_run_setup "$target" "$setup_model" "$prompt" &
        elif [[ -n "$prompt" ]]; then
          _a_inject_prompt "$target" "$prompt" &
        fi
      fi
    fi

    _a_info "tmux command finished."
    ;;

  ls)
    local root; root="$(git rev-parse --show-toplevel 2>/dev/null)" || { _a_err "not in a repo"; return 1; }
    local found=0
    local sandbox_list; sandbox_list="$(docker sandbox ls -q 2>/dev/null)"

    printf "  %-20s %-10s %s\n" "NAME" "TYPE" "SANDBOX"
    for d in "${root}/${AGENT_DIR}"/*/; do
      [[ -d "$d" ]] || continue
      local n; n="$(basename "$d")"
      local atype="unknown"
      [[ -f "${d}/.agent-type" ]] && atype="$(<"${d}/.agent-type")"
      local sbox="none"
      local sbox_name; sbox_name="$(_a_sandbox_name "$n" "$root")"
      echo "$sandbox_list" | grep -qx "$sbox_name" && sbox="created"
      printf "  %-20s %-10s %s\n" "$n" "$atype" "$sbox"
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
    local name="${1:?usage: agents kill <name> | --all}"

    if [[ "$name" == "--all" ]]; then
      local root; root="$(git rev-parse --show-toplevel 2>/dev/null)" || { _a_err "not in a repo"; return 1; }
      for d in "${root}/${AGENT_DIR}"/*/; do
        [[ -d "$d" ]] || continue
        agents kill "$(basename "$d")"
      done
      return
    fi

    local root; root="$(git rev-parse --show-toplevel 2>/dev/null)" || { _a_err "not in a repo"; return 1; }
    local sbox; sbox="$(_a_sandbox_name "$name" "$root")"
    docker sandbox stop "${sbox}" 2>/dev/null
    _a_info "killed: $name"
    ;;

  msg|send)
    local name="${1:?usage: agents msg <name> | --all <message>}"
    shift

    if [[ "$name" == "--all" ]]; then
      local msg="$*"
      [[ -z "$msg" ]] && { _a_err "usage: agents msg --all <message>"; return 1; }
      local root; root="$(git rev-parse --show-toplevel 2>/dev/null)" || { _a_err "not in a repo"; return 1; }
      for d in "${root}/${AGENT_DIR}"/*/; do
        [[ -d "$d" ]] || continue
        agents msg "$(basename "$d")" "$msg"
      done
      return
    fi

    local msg="$*"
    [[ -z "$msg" ]] && { _a_err "usage: agents msg <name> <message>"; return 1; }

    # Find the tmux target by window name first, then fall back to pane title
    # (splits set pane title, new-window sets window name)
    local target
    target=$(tmux list-windows -a -F '#{session_id}:#{window_index} #{window_name}' \
      | grep " [^:]*:${name}$" | head -1 | awk '{print $1}')

    if [[ -z "$target" ]]; then
      target=$(tmux list-panes -a -F '#{session_id}:#{window_index}.#{pane_index} #{pane_title}' \
        | grep " [^:]*:${name}$" | head -1 | awk '{print $1}')
    fi

    if [[ -z "$target" ]]; then
      _a_err "no tmux window or pane found for agent: $name"
      return 1
    fi

    tmux send-keys -t "$target" "$msg" Enter
    _a_info "sent to $name"
    ;;

  clean)
    local name="${1:-}"
    if [[ -z "$name" ]]; then
      _a_err "usage: agents clean <name> | --all"
      return 1
    fi

    local root; root="$(git rev-parse --show-toplevel 2>/dev/null)" || { _a_err "not in a repo"; return 1; }

    if [[ "$name" == "--all" ]]; then
      agents kill --all 2>/dev/null
      for d in "${root}/${AGENT_DIR}"/*/; do
        [[ -d "$d" ]] || continue
        local n; n="$(basename "$d")"
        local sbox_n; sbox_n="$(_a_sandbox_name "$n" "$root")"
        docker sandbox rm "${sbox_n}" 2>/dev/null
        git worktree remove --force "$d" 2>/dev/null
        git branch -D "agent/${n}" 2>/dev/null
        _a_info "  $n"
      done
      rmdir "${root}/${AGENT_DIR}" 2>/dev/null
      _a_info "done"
    else
      local sbox; sbox="$(_a_sandbox_name "$name" "$root")"
      docker sandbox rm "${sbox}" 2>/dev/null
      git worktree remove --force "${root}/${AGENT_DIR}/${name}" 2>/dev/null
      git branch -D "agent/${name}" 2>/dev/null
      _a_info "cleaned: $name"
    fi
    ;;

  help|--help|-\?)
    cat <<'EOF'
agents — tmux panes for sandboxed Claude Code agents

  agents start [-dwvh] [-p prompt] [-m model] [agent] <name> [-- args]
  agents ls
  agents kill  <name> | --all
  agents msg   <name> | --all <message>
  agents clean <name> | --all

Layout: (default) here  -d detach  -w window  -v vsplit  -h hsplit
Model:  -m model  override ANTHROPIC_MODEL (e.g., -m claude-opus-4-6)
Env:    AGENT_DIR (.agents)  AGENT_SANDBOX_ARGS (extra docker sandbox flags)
        AGENT_DEFAULT_MODEL (opus)  model for /model command on first run
Config: ~/.agentsh.rc (global)  {repo}/.agentsh.env (project)
        KEY=VALUE pairs injected as container env vars
EOF
    ;;

  *) _a_err "unknown: $cmd"; agents help ;;
  esac
}

# If executed directly (not sourced), dispatch to the agents function
if [[ "${BASH_SOURCE[0]}" == "${0}" ]] 2>/dev/null || [[ "$ZSH_EVAL_CONTEXT" == "toplevel" ]] 2>/dev/null; then
  agents "$@"
fi
