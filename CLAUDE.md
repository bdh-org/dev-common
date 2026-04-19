## Workflow
- Never commit directly to main. Always work on a feature branch.
- Before starting work, find or create a GitHub issue for the change.
- Branch naming: `<issue-number>-<short-description>` (e.g., `42-fix-login-bug`).
- Create the branch from main, do the work, commit to the branch.
- When done, create a PR that links the issue (e.g., `Closes #42`).

## Git Commits
Use conventional commit style.

Example: `fix: resolve null pointer in data loader`

## Pull Requests
Use a concise, descriptive title.

Example: `feat: add user authentication`

## Package Management
- Install packages with `conda` (conda-forge) into the dev environment when possible.
- Use `pip` only as a fallback when a package is not available on conda-forge.
- Flag potential conflicts when mixing pip and conda in the same environment.

## Stack Architecture Patterns

### P1: Primary repo
Every stack has one primary repo that orchestrates the others. It owns the
`docker-compose.yml`, deploys all services, and serves as the entry point for
`prod-deploy-all`. In the home-site stack, `home-site` is the primary repo.

### P2a: Full service
Long-running container (API, dashboard) with its own Dockerfile, served via
Apache vhost proxy. Examples: panoptikon, freddyb, canary, hog.

### P2b: Static site
Built frontend assets served directly by Apache with no container.
Example: oleo.

### P3: Submodule hierarchy
Two-tier shared infrastructure via git submodules:
- `common/` (dev-common) — dev tooling used by all projects: version.mk,
  python.mk, utils.mk, devcontainer.mk, devcontainer setup scripts.
- `stack-common/` (home-site-common) — stack-specific: deploy.mk, airflow.mk.
  Has dev-common as a nested submodule.

All repos include both with `-include` (tolerates missing submodules on fresh clone).

### P4: Conda-dev / pip-prod dependency split
Development and production use different package managers:
- **Dev**: `conda-packages.txt` installed via conda in the devcontainer.
- **Prod**: `requirements-prod.txt` installed via pip in the Dockerfile.
- **Bridge**: `make requirements` (python.mk) generates `requirements-prod.txt`
  by scanning imports and pinning to versions from the active conda environment.

Never delete one thinking it duplicates the other — they serve different purposes.

### P5: Service composition via extends
The primary repo's `docker-compose.yml` uses `extends` to pull service
definitions from stub files in each service's directory
(e.g. `./panoptikon/docker-compose.stub.yml`). All services join the shared
`minerva` bridge network.

### P6: Service discovery
Services find each other by container name on the minerva Docker network
(e.g. `http://freddyb:8000`, `http://hog:8000`). Environment variables like
`FBENDPOINT` and `HOG_ENDPOINT` pass these URLs to services that need them.

### P7: DAG management
DAGs live in each service's `dags/` directory. `make dags-install` (airflow.mk)
copies them to the central Airflow DAGs directory. `make dags-reserialize`
triggers Airflow to reload. `prod-deploy-all` runs both for every service that
has a `dags/` directory. Services with DAGs typically also have a Dockerfile
for the container that DAG tasks call into.

### P8: Version propagation
Each repo has `VERSION=x.y.z` in its Makefile. The primary repo extracts
service versions at build time and exports them as environment variables for
docker-compose image tagging. `make bump-patch` increments and auto-commits.
The `tag-version.yml` workflow (reusable from dev-common) creates git tags
on push to main.

### P9: Devcontainer setup chain
Four sequential steps initialize the development environment:
1. `init-host.sh` — runs on HOST: creates credential dirs, extracts macOS
   Keychain tokens.
2. `setup-base.sh` — installs Miniforge, tmux, shell config, git aliases.
3. `setup-python-dev.sh` — conda dev tools (ruff, pytest, jupyter) + project
   packages from `conda-packages.txt`.
4. `setup-claude.sh` — Claude Code CLI.
5. `setup-waterbrother.sh` — waterbrother CLI (optional; projects that
   don't need it simply don't source this script).

Services that don't need Python (e.g. home-site) skip step 3.

### P10: Production deployment with retry
`prod-deploy-all` deploys the full stack from the primary repo via SSH.
All git operations use `git_retry` (make define/call macro) — 5 attempts with
10s backoff to handle transient DNS failures (Tailscale MagicDNS).

### P11: Project scaffolding (devtemplate)
New repos are created by cloning `devtemplate`, which embeds the standard
patterns: dev-common submodule, conda-packages.txt, ruff.toml, devcontainer
setup chain, Makefile includes. Run `make init` after renaming the directory
to finalize the scaffold.
