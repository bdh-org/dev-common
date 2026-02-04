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
  "features": {
    "ghcr.io/devcontainers/features/node:1": {},
    "ghcr.io/devcontainers/features/github-cli:1": {}
  },
  "mounts": [
    "source=${localEnv:HOME}/.claude,target=/home/vscode/.claude,type=bind,consistency=cached"
  ],
  "remoteEnv": {
    "ANTHROPIC_API_KEY": "${localEnv:ANTHROPIC_API_KEY}"
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

## Design Principles

1. **Composable** - Source individual scripts as needed
2. **Miniforge for conda** - Replaces /opt/conda, uses conda-forge, lighter than Anaconda
3. **Production uses pip** - Multi-stage Docker builds with requirements-prod.txt for small images
4. **pipreqs for imports** - Use `make list-imports` to identify imports for minimal production requirements
