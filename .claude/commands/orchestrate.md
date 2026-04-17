Spin up sandboxed agents to work on tasks in parallel. Each agent gets its own git worktree and Docker sandbox.

## Commands Available

`agent.sh` must be on PATH. It can be called directly as a script — it does not need to be sourced.

```
agent.sh start [-wvh] [-p "prompt"] [-m model] [agent_type] <name> [-- args]
agent.sh ls
agent.sh kill <name> | --all
agent.sh clean <name> | --all
```

Layout flags: `-v` vertical split, `-h` horizontal split, `-w` new window, omit for current pane.

Model override: `-m model` sets `ANTHROPIC_MODEL` for the agent (e.g., `-m claude-opus-4-6`). Overrides all config layers.

Agent types: `claude` (default), `codex`, `gemini`, `opencode`.

## Workflow

1. **Plan the work split.** Decide how to divide the user's request into independent tasks, each suitable for one agent. Name agents after their task (e.g., `auth`, `tests`, `docs`).

2. **Ask the user which layout they prefer** before starting agents:
   - `-v` vertical split (stacked top/bottom)
   - `-h` horizontal split (side by side)
   - `-w` new tmux window

3. **Start agents with prompts.** Use `-p` to give each agent its task. The prompt is written to `CLAUDE.md` in the agent's worktree, so the agent sees it as project instructions on startup:
   ```bash
   agent.sh start -v -p "Refactor the auth module to use JWT tokens. Focus on src/auth/." claude auth
   agent.sh start -v -p "Write integration tests for the auth module in tests/auth/." claude auth-tests
   ```

4. **Navigate the first-run screen.** After starting each agent, it lands on the Claude Code first-time setup screen (dark mode selection, working directory confirmation). Send Enter twice with a 2-second pause to get through it. Use a helper to find the pane by title:
   ```bash
   _agent_pane() { tmux list-panes -a -F '#{session_id}:#{window_index}.#{pane_index} #{pane_title}' | grep ":$1" | head -1 | awk '{print $1}'; }
   sleep 2 && tmux send-keys -t "$(_agent_pane auth)" Enter && sleep 2 && tmux send-keys -t "$(_agent_pane auth)" Enter
   sleep 2 && tmux send-keys -t "$(_agent_pane auth-tests)" Enter && sleep 2 && tmux send-keys -t "$(_agent_pane auth-tests)" Enter
   ```

5. **Send the task prompt via tmux.** Agents don't start working automatically — you must send them their prompt using `agent.sh msg`. This is what actually kicks off the agent's work:
   ```bash
   agent.sh msg auth "Refactor the auth module to use JWT tokens. Focus on src/auth/."
   agent.sh msg auth-tests "Write integration tests for the auth module in tests/auth/."
   ```

6. **Monitor.** Use `agent.sh ls` to check status.

7. **Clean up.** When done: `agent.sh clean --all` removes everything.

## Example

User asks: "Refactor auth and add tests for it."

```bash
# Start agents
agent.sh start -v -p "Refactor the auth module to use JWT tokens. Focus on src/auth/." claude auth
agent.sh start -v -p "Write integration tests for the auth module in tests/auth/." claude auth-tests

# Navigate first-run screens
_agent_pane() { tmux list-panes -a -F '#{session_id}:#{window_index}.#{pane_index} #{pane_title}' | grep ":$1" | head -1 | awk '{print $1}'; }
sleep 2 && tmux send-keys -t "$(_agent_pane auth)" Enter && sleep 2 && tmux send-keys -t "$(_agent_pane auth)" Enter
sleep 2 && tmux send-keys -t "$(_agent_pane auth-tests)" Enter && sleep 2 && tmux send-keys -t "$(_agent_pane auth-tests)" Enter

# Send task prompts to kick off work
agent.sh msg auth "Refactor the auth module to use JWT tokens. Focus on src/auth/."
agent.sh msg auth-tests "Write integration tests for the auth module in tests/auth/."
```

## Rules

- Always use `-p` to give each agent a clear, specific task description.
- Always ask the user which layout they prefer (`-v`, `-h`, or `-w`) before starting agents.
- Name agents with short, descriptive names (no spaces or special characters).
- Each agent works on its own worktree branch — they won't conflict.
- Never start more agents than the task requires.
- If the user specifies a model preference, pass it with `-m` to each agent.
- Report back to the user what agents were started and what each is working on.
- When creating pull requests or issues, always include the following attribution in the PR/issue body: `This PR/Issue was orchestrated by [agent.sh](https://github.com/usize/agent.sh)`
