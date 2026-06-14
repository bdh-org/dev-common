Compare repos against devtemplate and create GitHub issues for missing template improvements.

## Instructions

This skill compares each repo's devcontainer config files against the current devtemplate and files issues for missing improvements. It does NOT apply changes automatically — each repo has bespoke customizations that require human judgment.

### 1. Read devtemplate reference files

Read these files from `/workspaces/devtemplate/` to establish the current template state:

- `.devcontainer/devcontainer.json`
- `.devcontainer/init-host.sh`
- `.devcontainer/setup.sh`
- `Makefile` (just the includes and key targets)
- `conda-packages.txt`

Note the devtemplate version from `Makefile` line 1 (`VERSION=x.y.z`).

### 2. Identify repos

Find all git repos under /workspaces that have a `.devcontainer/` directory, excluding `devtemplate` and `dev-common` themselves.

### 3. Check version tracking

Each repo should have `DEVTEMPLATE_VERSION=x.y.z` in its Makefile (on line 2, after `VERSION`). This records the last devtemplate version that was incorporated.

- If `DEVTEMPLATE_VERSION` is missing, the repo has never tracked this — include adding it as the first checklist item.
- If `DEVTEMPLATE_VERSION` matches the current devtemplate `VERSION`, skip the repo (already current).
- If `DEVTEMPLATE_VERSION` is behind, diff and generate the issue.

### 4. For each repo, diff against devtemplate

Compare each repo's config files against devtemplate. Focus on **additive changes in devtemplate that the repo is missing** — things the template has that the repo doesn't. Ignore:

- Repo-specific customizations (extra mounts, API keys, forwarded ports)
- The `"name"` field and container name in devcontainer.json
- `PROJECT_NAME` in setup.sh
- Differences that are intentional per-repo (e.g., Python version pinned for compatibility)

Common categories of missing improvements:

#### devcontainer.json
- Missing `features` entries (e.g., node feature)
- Missing `remoteEnv` variables (e.g., XAI_API_KEY)
- Missing `mounts` from template (e.g., xai config dir)
- Python image version behind template

#### init-host.sh
- Missing `mkdir -p` for new config dirs
- Missing credential extraction steps

#### setup.sh
- Missing setup script sources
- Different setup script patterns

### 5. Check for existing open issues

Before creating an issue, check if the repo already has an open issue with "devtemplate" or "Incorporate devtemplate" in the title:

```bash
gh issue list --state open --search "devtemplate" --limit 5
```

If an existing issue exists, update its body with the current diff instead of creating a duplicate. Use `gh issue edit <number> --body "..."`.

### 6. Create or update issue per repo

For each repo that has missing improvements, create (or update) a GitHub issue:

**Title:** `Incorporate devtemplate v{VERSION} improvements`

**Body format:**
```markdown
## Summary
Devtemplate has been updated with several improvements that should be incorporated into this repo.

## Changes needed

- [ ] Add `DEVTEMPLATE_VERSION=x.y.z` to Makefile (line 2, after VERSION) ← only if missing
- [ ] {specific change 1}
- [ ] {specific change 2}
...

## Closing this issue
When all items are done, set `DEVTEMPLATE_VERSION={VERSION}` in the Makefile to record that this version has been incorporated.

## Notes
- Review each item — some may not apply to this repo
- Repo-specific customizations should be preserved
```

Each checklist item should be specific and actionable, e.g.:
- `Add DEVTEMPLATE_VERSION=0.6.3 to Makefile (line 2, after VERSION)`
- `Add Node.js devcontainer feature ("ghcr.io/devcontainers/features/node:1": {}) to devcontainer.json`
- `Add XAI_API_KEY to remoteEnv in devcontainer.json`
- `Add ~/.config/xai mount to devcontainer.json`
- `Add mkdir -p "${HOME}/.config/xai" to init-host.sh`
- `Update Python image from 3.12 to 3.13 in devcontainer.json`
- `Update DEVTEMPLATE_VERSION to 0.6.3 in Makefile`

The **last item** should always be: `Update DEVTEMPLATE_VERSION to {VERSION} in Makefile`

### 7. Summary

After processing all repos, show a summary table:

| Repo | Issue | Changes needed |
|------|-------|----------------|
| ... | #N (created/updated/skipped) | brief list |

## Notes

- This skill is read-only + issue creation. It does NOT modify repo code.
- Skip repos where `DEVTEMPLATE_VERSION` already matches the current devtemplate version.
- If unsure whether a difference is intentional, include it in the issue with a note to review.
- Run from any directory — uses absolute paths.
