# dev-common

Shared development infrastructure: Makefile targets, GitHub Actions, devcontainer configs, and more.

## Usage

Add as a submodule to your repo:

```bash
git submodule add https://github.com/brianholland/dev-common.git common
```

Then include what you need in your Makefile:

```makefile
VERSION=1.0.0
IMAGE_NAME=myapp

include common/make/version.mk
include common/make/utils.mk

# Your project-specific targets...
build:
    docker build -t $(IMAGE_NAME):$(VERSION) .
```

## Contents

### make/

Shared Makefile targets. Requires `VERSION` variable in your Makefile.

| File | Targets | Description |
|------|---------|-------------|
| `version.mk` | `bump-patch`, `bump-minor`, `bump-major`, `tag` | Semantic version management |
| `utils.mk` | `show`, `list`, `ls`, `claude-install` | Common utilities |
| `python.mk` | `env`, `env-info`, `list-imports`, `requirements`, `lint`, `lint-fix`, `format`, `format-check` | Python dev tools, conda env, production requirements |
| `devcontainer.mk` | `dc-install`, `dc-up`, `dc-shell`, `dc-exec`, `dc-stop`, `dc-rm`, `dc-nuke`, `setup-verify`, `setup-fix` | Devcontainer lifecycle management via CLI; setup doctor for the global git config |

#### Opting in to `format-check`

`format-check` fails when `ruff format` would change anything. It is
**not** a prerequisite of `lint`: every consumer carries its own
formatter debt, and wiring it into the shared `lint` would turn them all
red at once. A repo opts in, once its debt is paid, from its own
Makefile:

```make
lint: format-check
```

A target declared with a prerequisite and **no recipe** adds to the
inherited rule instead of overriding it — no `warning: overriding
recipe`, the dev-common recipe still runs, and `format-check` runs
first. CI needs no change if it already invokes `make lint`.

The rollout order that makes paying the debt safe, one commit each:

1. config only — `line-length`, `[format]`, and an `exclude` for the
   submodules
2. one pure `ruff format` commit, nothing else in it
3. `.git-blame-ignore-revs` naming that commit
4. opt in with `lint: format-check`

Two traps:

- **`make format` is unsafe until the submodules are excluded.** `ruff
  format .` descends into `common/` and `stack-common/` and rewrites
  them in place.
- **Verify the reformat by AST, not by test suite.** Comparing
  `ast.dump` before and after each changed file proves the diff is
  semantics-free; a green suite only suggests it.

### github/ vs .github/

The `github/` directory contains workflow templates for consumer repos — copy these to your repo's `.github/workflows/` directory. The `.github/` directory contains workflows that run on this repo itself.

Most of `.github/workflows/` is `workflow_call`-only — reusable implementations
that fire on *other* repos' events. `shell-tests.yml` is the exception: it is
dev-common's own PR gate over the shell it ships, and should not be copied into
a consumer repo. `issue-to-pr.yml`, `pr-revise.yml` and `submodule-bump.yml` are
dev-common's own *wrappers*: this repo is a consumer of its own pipelines, so it
carries a trigger for each, exactly like every other repo does.

**A reusable workflow lives with the code it runs, and here that means public.**
A public repo can never call a workflow from a private one, and a reusable's
`actions/checkout` lands in the *caller's* workspace — so a script sitting
beside a reusable in another repo is simply not on disk when the job runs. Both
bit at once in bdh-org/home-infra#368, which is why `bump-submodule-pins.yml`
and its engine live here rather than in the (private) architect repo. A
reusable that needs code from this repo must name it:
`repository: bdh-org/dev-common` with `ref: ${{ github.job_workflow_sha }}`.

### scripts/

Shell that dev-common's *own* workflows run — not consumer tooling, which is
`make/` and `devcontainer/`.

| File | Description |
|------|-------------|
| `bump-submodule-pins.sh` | The fleet pin sweep: one PR per consumer moving a stale submodule pin to the source's head. Never merges, never pushes to a consumer's `main` (bdh-org/home-infra#362) |
| `fleet-consumers.txt` | The one expected list of repos carrying pins. Read by the sweep here, and by `audit-submodule-pins.sh` in home-infra through its `common/` submodule — the same file, not a copy |

### tests/

dev-common's own tests, run by `make test` and by `shell-tests.yml` on every PR.

| File | Covers |
|------|--------|
| `setup-claude-identity.test.sh` | `devcontainer/setup-claude-identity.sh` — role naming per `PROJECT_NAME`, `user.email` left alone, the `~/.gitconfig-seat` → `~/.gitconfig-role` migration, and idempotency across repeated runs |
| `submodule-bump.test.sh` | `scripts/bump-submodule-pins.sh` — driven end to end against a journalling stub API and real bare repos, asserting the negative space: no merge call, every consumer's `main` byte-identical after every case, and no version moved by anything but `make bump-patch` |

Each case runs the real script against a throwaway `$HOME` — the script's only
inputs are `$HOME` and `$PROJECT_NAME`, so nothing needs stubbing and nothing
touches the machine running the test. That script executes in every devcontainer
across the fleet and writes to a gitconfig shared by all of them, so a defect in
it is a fleet-wide one (bdh-org/dev-common#157, bdh-org/home-infra#317).

### github/workflows/

Copy to your repo's `.github/workflows/` directory.

| File | Description |
|------|-------------|
| `tag-version.yml` | Auto-create git tags when Makefile VERSION changes on main |

#### Tag push rejected: "without `workflows` permission"

A tag run can fail at the push with:

```
! [remote rejected] 1.3.97 -> 1.3.97 (refusing to allow a GitHub App to
create or update workflow `.github/workflows/<file>.yml` without
`workflows` permission)
```

This is not a problem with the tag. GitHub evaluates a **new ref's**
workflow files against the current default branch, so when a commit
touching `.github/workflows/` lands on main next to (typically seconds
after) the version-bump merge, creating the tag trips the
workflows-permission check. `GITHUB_TOKEN` can never be granted
`workflows`, so no `permissions:` block helps and re-running the job
cannot succeed. The workflow-change merge itself produces no tag run of
its own — the `paths: Makefile` filter skips it — so the symptom is just
a missing tag (bdh-org/dev-common#122; seen on finzeug/heller
2026-07-22).

The tag step detects this rejection and prints the remediation as a run
annotation and job summary. The fix is a one-line manual push, from a
clone authenticated with a PAT that has workflow scope, pointing the tag
at the bump commit:

```bash
git tag 1.3.97 <bump-sha> && git push origin 1.3.97
```

### devcontainer/

Composable scripts for setting up development containers. See [devcontainer/README.md](devcontainer/README.md) for details.

| File | Description |
|------|-------------|
| `setup-base.sh` | Core setup: tmux, Miniforge, shell aliases |
| `git-hygiene.sh` | Global git config (`fetch.prune`, `git gone` alias); shared by the host and container setup, `--check` mode backs `make setup-verify` |
| `setup-node.sh` | Claude Code CLI via npm |
| `setup-python-dev.sh` | Python dev tools: ruff, pytest, jupyter, pipreqs |
| `base-conda-packages.txt` | Minimal common packages |

## Updating

To update the submodule to the latest version:

```bash
make common-update
```

Or manually:

```bash
cd common && git pull origin main && cd ..
git add common && git commit -m "[CC] chore: update dev-common"
```
