Update the `common` submodule to latest and bump patch version across all repos in /workspaces.

**This is now the escape hatch, not the process.** Since bdh-org/home-infra#362 the
`submodule-bump` workflow sweeps every consumer of `common` and `stack-common` on every push
to the source's main, and daily as a backstop, opening one force-refreshed PR per repo. Use
this skill when you want ONE repo bumped right now, or when the workflow cannot run. It walks
`/workspaces/*`, so it only works in the architect devcontainer -- which is the other reason
it could never be the process.

It also does not cover `stack-common` at all.

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

#### f. Stop. Do not merge.

Leave the PR open for a human.

**Merging a bump is a deploy.** Merging to main runs `ci-build`, which ships an
image and restarts that service — so running this skill across the fleet and
merging as you go is a fleet deploy with nothing checking the fleet came back.
That is exactly what happened in bdh-org/home-infra#348: a routine
`update-common` restarted the reference database under ten services. This step
used to read `gh pr merge --squash --delete-branch`, and that line is why.

#### g. Cleanup

- `git checkout main`
- Leave the `update-common` branch alone — the PR is still open on it.

### 3. Confirm

After all repos are done, show a summary:

- Which repos were updated (with new version)
- Which repos were skipped (already up to date)
- Run `git log --oneline -3` in each updated repo

## Notes

- If a repo already has an `update-common` branch, delete it first and start fresh
- If any step fails, diagnose and fix rather than skipping
- Ask the user before proceeding if anything is ambiguous
