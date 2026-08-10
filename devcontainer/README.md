# Devcontainer Scripts

Composable scripts for setting up development containers. Projects source these scripts rather than using a monolithic template.

## Quick Start

Create `.devcontainer/setup.sh` in your project:

```bash
#!/usr/bin/env bash
set -euo pipefail

# Path to dev-common (adjust based on your submodule location)
COMMON="/workspaces/${PWD##*/}/common/devcontainer"

# Core setup: tmux, Miniforge, shell aliases
source "$COMMON/setup-base.sh"

# Python dev tools + project packages
source "$COMMON/setup-python-dev.sh" "conda-packages.txt"

# Claude Code CLI (native installer)
source "$COMMON/setup-claude.sh"

# waterbrother CLI (optional — omit this line to skip)
source "$COMMON/setup-waterbrother.sh"
```

## Scripts

### setup-base.sh

Core setup sourced by all projects:

- Installs tmux
- Removes `/opt/conda` if present
- Installs Miniforge to `~/miniforge3`
- Configures `.condarc` with conda-forge (strict channel priority)
- Adds shell aliases (`gl`, `l`, `la`, `ll`)
- Sets PATH priority (conda before `~/.local/bin`)
- Applies the global git hygiene config via `git-hygiene.sh`

### git-hygiene.sh

Single source of truth for the global git config the setup scripts own —
`fetch.prune` and the `git gone` alias. Run as a standalone script (not
sourced) by both `setup-base.sh` (container) and `init-host.sh` (host), so
the two can't drift apart.

```bash
bash "$COMMON/git-hygiene.sh"           # apply (idempotent)
bash "$COMMON/git-hygiene.sh" --check   # report drift, change nothing, exit 1 if drifted
```

`git gone` deletes local branches whose upstream was merged and deleted on
the remote. It **refuses to prune** — loudly, with a non-zero exit — when
`git fetch -p` fails or the repo has no remote, rather than reporting success
having done nothing from stale upstream state.

Because `init-host.sh` only runs on a devcontainer rebuild, a machine set up
before a config landed never receives it. `make setup-verify` / `make
setup-fix` (see below) are the doctor for that; both work on the host and
inside the container.

### setup-python-dev.sh

Python development tools:

- Installs base packages from `base-conda-packages.txt`
- Optionally installs project-specific packages (pass file path as argument)
- Installs dev tools: ruff, pytest, pytest-cov, ipykernel, jupyterlab, pipreqs

Usage:
```bash
source "$COMMON/setup-python-dev.sh"                      # base packages only
source "$COMMON/setup-python-dev.sh" "conda-packages.txt" # with project packages
```

### setup-claude.sh

Claude Code CLI setup:

- Installs Claude Code CLI via native installer (curl)
- Seeds a private `~/.claude.json` (onboarding stub) if absent, so each
  container keeps its own Claude Code state instead of sharing the host file

### setup-claude-identity.sh

Points `~/.gitconfig` and `~/.config/gh` at the host-managed identity tree
(`~/.config/ai/claude/identity/`), bootstrapping it on a fresh host:

- Symlinks the standard tool paths into that tree, so git and gh find Claude's
  config without environment-variable indirection
- Adds one `include.path = ~/.gitconfig-role` to the identity gitconfig and
  writes that container-local file with `user.name = bdh-ai (<role>)`, derived
  from `$PROJECT_NAME` — `architect` for home-infra, `contractor/<repo>`
  elsewhere. Only `user.name`; `user.email` stays `bdh-ai` everywhere
  (bdh-org/home-infra#317)

Its only inputs are `$HOME` and `$PROJECT_NAME`. Because it runs in every
devcontainer and writes to a gitconfig shared by all of them, it is gated by
`tests/setup-claude-identity.test.sh` on every PR — run it with `make test`
before changing this script (bdh-org/dev-common#157).

### setup-waterbrother.sh

waterbrother CLI setup:

- Installs `@tritard/waterbrother` globally via npm
- Optional — projects that don't want it simply don't source this script

## Package Files

### base-conda-packages.txt

Minimal packages installed for all projects:
- python=3.13, pip
- loguru, pandas, numpy, requests, pyyaml

### Project conda-packages.txt

Each project maintains its own `conda-packages.txt` with project-specific dependencies. Pass this to `setup-python-dev.sh`.

## Example devcontainer.json

```json
{
  "name": "My Project",
  "image": "mcr.microsoft.com/devcontainers/python:3.12",
  "updateRemoteUserUID": true,
  "features": {
    "ghcr.io/devcontainers/features/github-cli:1": {}
  },
  "initializeCommand": "bash .devcontainer/init-host.sh",
  "runArgs": [
    "--name=dc-my-project"
  ],
  "mounts": [
    "source=${localEnv:HOME}/.claude,target=/home/vscode/.claude,type=bind,consistency=cached",
    "source=${localEnv:HOME}/.config/ai/claude,target=/home/vscode/.config/ai/claude,type=bind,consistency=cached",
    "source=${localEnv:HOME}/.config/ai/xai,target=/home/vscode/.config/ai/xai,type=bind,consistency=cached"
  ],
  "remoteEnv": {
    "ANTHROPIC_API_KEY": "${localEnv:ANTHROPIC_API_KEY}",
    "GITHUB_TOKEN": "${localEnv:GITHUB_TOKEN}"
  },
  "postCreateCommand": "bash .devcontainer/setup.sh",
  "customizations": {
    "vscode": {
      "settings": {
        "python.defaultInterpreterPath": "/home/vscode/miniforge3/bin/python"
      }
    }
  }
}
```

## Make Targets

The setup scripts handle initial container creation. For ongoing environment management, use the Make targets from `make/python.mk`:

### Environment Management

| Target | Description |
|--------|-------------|
| `make env` | Install/refresh base conda packages, project packages, and dev tools |
| `make env-info` | Show conda environment info and installed packages |

### Setup Doctor

From `make/devcontainer.mk`. Re-asserts the global git config the setup
scripts install, without a devcontainer rebuild. Safe to run on the host.

| Target | Description |
|--------|-------------|
| `make setup-verify` | Report drift in the global git hygiene config; exit 1 if drifted |
| `make setup-fix` | (Re)assert it |

### Production Requirements

| Target | Description |
|--------|-------------|
| `make requirements` | Generate pinned `requirements-prod.txt` for production pip install |
| `make list-imports` | List imports (unpinned, stdout only) |

Configure in your Makefile:
```makefile
COMMON_DIR = common                          # path to dev-common submodule
PROJECT_CONDA_PACKAGES = conda-packages.txt  # project-specific packages (optional)

include common/make/python.mk
```

`make requirements` scans your code with pipreqs to find actual imports (excluding dev tools like ruff, pytest), then pins each package to the version installed in the conda env. The output file is ready for `pip install -r requirements-prod.txt` in a production Dockerfile.

## Design Principles

1. **Composable** - Source individual scripts as needed
2. **Miniforge for conda** - Replaces /opt/conda, uses conda-forge, lighter than Anaconda
3. **Base env only** - The devcontainer is the isolation boundary; no named conda environments needed
4. **Production uses pip** - Multi-stage Docker builds with requirements-prod.txt for small images
5. **pipreqs for imports** - Use `make requirements` to generate pinned production requirements
