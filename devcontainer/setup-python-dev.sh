#!/usr/bin/env bash
# setup-python-dev.sh - Python development tools setup
# Source this script from your project's .devcontainer/setup.sh
#
# Usage:
#   source "$COMMON/setup-python-dev.sh"                    # base packages only
#   source "$COMMON/setup-python-dev.sh" "conda-packages.txt"  # with project packages
#
# Requires: setup-base.sh to have run first (Miniforge installed)
# Installs: ruff, pytest, pytest-cov, ipykernel, jupyterlab, pipreqs

set -euo pipefail

MINIFORGE_DIR="$HOME/miniforge3"
COMMON_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_PACKAGES="${1:-}"

export PATH="$MINIFORGE_DIR/bin:$PATH"

# -----------------------------------------------------------------------------
# Install base conda packages (shared across all projects)
# -----------------------------------------------------------------------------
echo "==> Installing base conda packages..."
conda install -y --file "$COMMON_DIR/base-conda-packages.txt"

# -----------------------------------------------------------------------------
# Install project-specific conda packages (if provided)
# -----------------------------------------------------------------------------
if [ -n "$PROJECT_PACKAGES" ] && [ -f "$PROJECT_PACKAGES" ]; then
  echo "==> Installing project conda packages from $PROJECT_PACKAGES..."
  conda install -y --file "$PROJECT_PACKAGES"
fi

# -----------------------------------------------------------------------------
# Install dev tools via conda
# -----------------------------------------------------------------------------
echo "==> Installing Python dev tools..."
# Ruff is PINNED from RUFF_VERSION so a devcontainer and CI format identically.
# `ruff format` output changes between patch releases, so an unpinned install makes
# `make format-check` passing locally predict nothing about CI -- caught by
# finzeug/ferret#41, where a locally-clean tree reported 2 files to reformat on its
# first CI run (dev-common 0.16.0 vs CI 0.16.3).
RUFF_V="$(tr -d '[:space:]' < "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/RUFF_VERSION" 2>/dev/null || true)"
[ -n "$RUFF_V" ] || { echo "!! RUFF_VERSION missing -- refusing to install an unpinned formatter" >&2; exit 1; }
echo "==> pinned ruff: ${RUFF_V}"
conda install -y "ruff=${RUFF_V}" pytest pytest-cov ipykernel jupyterlab pipreqs

echo "==> Python dev setup complete"
