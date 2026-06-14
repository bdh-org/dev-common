Update the `common` submodule to latest and bump patch version across all repos in /workspaces.

## Instructions

This skill operates across multiple repos. Run it from /workspaces (not inside a single repo).

### 1. Identify repos

Find all git repos under /workspaces that have a `common` submodule:

```bash
for dir in /workspaces/*/; do
  if [ -f "$dir/.gitmodules" ] && grep -q 'common' "$dir/.gitmodules"; then
    echo "$dir"
  fi
done
```

### 2. For each repo, do the following

Run these steps sequentially in each repo. Complete one repo before moving to the next.

#### a. Ensure clean state

- `git checkout main && git pull`
- Confirm working tree is clean (`git status --porcelain` should be empty)
- If not clean, stop and ask the user

#### b. Create a branch

- Branch name: `update-common`
- `git checkout -b update-common`

#### c. Update the common submodule

```bash
git submodule update --remote common
git add common
```

- If there are no changes (submodule already at latest), skip this repo and clean up the branch
- If there are changes, commit: `chore: update common submodule`

#### d. Bump patch version

- Run `make bump-patch`

#### e. Push and create PR

- `git push -u origin update-common`
- Create PR with `gh pr create --title "chore: update common submodule" --body "Updates common submodule to latest and bumps patch version."`

#### f. Squash merge

- `gh pr merge --squash --delete-branch`

#### g. Cleanup

- `git checkout main && git pull`
- `git branch -d update-common 2>/dev/null`
- `git remote prune origin`

### 3. Confirm

After all repos are done, show a summary:

- Which repos were updated (with new version)
- Which repos were skipped (already up to date)
- Run `git log --oneline -3` in each updated repo

## Notes

- If a repo already has an `update-common` branch, delete it first and start fresh
- If any step fails, diagnose and fix rather than skipping
- Ask the user before proceeding if anything is ambiguous
