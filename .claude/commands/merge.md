Open GitHub PRs for agent branch work. Walk the user through reviewing and merging agent branches back upstream.

## Workflow

1. **Detect the base branch.** Run `gh repo view --json defaultBranchRef --jq '.defaultBranchRef.name'` to find the repo's default branch.

2. **Find agent branches with work.** List branches matching `agent/*` that have commits ahead of the base branch:
   ```bash
   git branch --list 'agent/*' --format='%(refname:short)'
   ```
   For each branch, check if it has commits ahead of the base:
   ```bash
   git rev-list --count <base>..<branch>
   ```
   Skip branches with zero commits ahead.

3. **Show summaries.** For each branch with work, display:
   - Commit log: `git log --oneline <base>..<branch>`
   - Diff stats: `git diff --stat <base>..<branch>`

4. **Check for existing PRs.** For each branch, check if a PR already exists:
   ```bash
   gh pr list --head <branch> --state open --json number,title,url
   ```
   Report any existing PRs and skip those branches.

5. **Ask the user.** Present the list of branches that need PRs and ask:
   - Which branches to open PRs for
   - A title and description for each PR

6. **Push and create PRs.** For each selected branch:
   ```bash
   git push -u origin <branch>
   gh pr create --head <branch> --base <base> --title "<title>" --body "<description>

   Generated with [agent.sh](https://github.com/usize/agent.sh)"
   ```

7. **Report results.** Show the URL of each created PR.

## Rules

- Always show commit summaries and diff stats before asking the user to create PRs.
- Always check for existing open PRs to avoid duplicates.
- Always prompt the user for a title and description before creating each PR.
- Never force-push.
- Every PR body must end with: `Generated with [agent.sh](https://github.com/usize/agent.sh)`
- If no agent branches have commits ahead, inform the user and stop.
