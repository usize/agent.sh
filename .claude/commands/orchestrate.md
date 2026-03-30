Spin up sandboxed agents to work on tasks in parallel. Each agent gets its own git worktree and Docker sandbox.

## Commands Available

`agent.sh` must be on PATH. It can be called directly as a script — it does not need to be sourced.

```
agent.sh start [-wvh] [agent_type] <name> [-- args]   # create + start an agent
agent.sh ls                                            # list agents
agent.sh kill <name> | --all                           # stop agents
agent.sh clean <name> | --all                          # remove agents + worktrees
```

Layout flags: `-w` new window, `-v` vertical split, `-h` horizontal split, omit for current pane.

Agent types: `claude` (default), `codex`, `gemini`, `opencode`.

## Workflow

1. **Plan the work split.** Decide how to divide the user's request into independent tasks, each suitable for one agent. Name agents after their task (e.g., `auth`, `tests`, `docs`).

2. **Prepare worktrees (optional).** If an agent needs to start from a specific branch or with staged changes, create the worktree first:
   ```bash
   # The worktree is created automatically by `agent.sh start`, but to prep it:
   git worktree add -b agent/<name> .agents/<name> HEAD
   cd .agents/<name> && git checkout -b feature/<name>
   ```

3. **Start agents.** Ask the user which layout they prefer before starting:
   - `-v` vertical split (stacked top/bottom)
   - `-h` horizontal split (side by side)
   - `-w` new tmux window
   ```bash
   agent.sh start -v claude <name> -- --continue
   ```

4. **Give instructions.** After starting, the agent is interactive in its tmux window. Write a clear prompt file into the worktree before starting, or pass instructions via `-- args`.

5. **Monitor.** Use `agent.sh ls` to check status. Use tmux to switch between windows and review progress.

6. **Clean up.** When done: `agent.sh clean --all` removes everything.

## Example

User asks: "Refactor auth and add tests for it."

```bash
# Start two agents as vertical splits
agent.sh start -v claude auth
agent.sh start -v claude auth-tests
```

## Rules

- Always ask the user which layout they prefer (`-v`, `-h`, or `-w`) before starting agents.
- Name agents with short, descriptive names (no spaces or special characters).
- Each agent works on its own worktree branch — they won't conflict.
- Never start more agents than the task requires.
- Report back to the user what agents were started and what each is working on.
