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

# Claude Code CLI (requires Node.js feature in devcontainer.json)
[ -x "$(command -v npm)" ] && source "$COMMON/setup-node.sh"
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

### setup-node.sh

Optional Node.js setup:

- Installs Claude Code CLI via npm

Requires Node.js feature in `devcontainer.json`:
```json
{
  "features": {
    "ghcr.io/devcontainers/features/node:1": {}
  }
}
```

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
    "ghcr.io/devcontainers/features/node:1": {},
    "ghcr.io/devcontainers/features/github-cli:1": {}
  },
  "initializeCommand": "mkdir -p ${HOME}/.config/gh ${HOME}/.claude ${HOME}/data",
  "mounts": [
    "source=${localEnv:HOME}/.config/gh,target=/home/vscode/.config/gh,type=bind,consistency=cached",
    "source=${localEnv:HOME}/.claude,target=/home/vscode/.claude,type=bind,consistency=cached"
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
