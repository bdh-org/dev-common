Ship a fix or feature end-to-end: issue, branch, commit, version bump, PR, squash merge, and cleanup.

## Instructions

Run this workflow in the current repo working directory. Adapt to whatever state the work is in — if changes are already committed, skip to the next step. If there's already a branch, use it.

### 1. Issue
- If the user described the work, create a GitHub issue with `gh issue create`
- If an issue number was provided, use that
- Note the issue number for the branch name

### 2. Branch
- Create and checkout a branch named `<issue-number>-<short-description>` from main
- If already on a feature branch, use it

### 3. Commit
- Stage and commit changes with a conventional commit message (e.g. `fix:`, `feat:`, `chore:`)
- Include `Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>`

### 4. Version bump
- Run `make bump-patch` to increment the patch version
- The bump-patch target auto-commits (may include `[CC]` prefix from the make target — that's fine)

### 5. Push and PR
- Push the branch with `git push -u origin <branch>`
- Create a PR with `gh pr create` linking the issue (`Closes #<number>`)
- Use a clear, concise PR title (no `[CC]` prefix)

### 6. Squash merge
- Merge with `gh pr merge --squash --delete-branch`
- This deletes the remote branch automatically

### 7. Cleanup
- Switch to main: `git checkout main`
- Pull: `git pull`
- Delete local branch: `git branch -d <branch>`
- Prune: `git remote prune origin`

### 8. Confirm
- Run `git log --oneline -3` and `git branch -a` to show final state

## Notes
- Ask the user before proceeding if anything is ambiguous (e.g. patch vs minor bump)
- If any step fails, diagnose and fix rather than skipping
- The user may invoke this at any stage — detect where things are and pick up from there
