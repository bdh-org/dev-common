#!/usr/bin/env bash
# setup-claude.sh - Claude Code CLI setup (native installer)
# Source this script from your project's .devcontainer/setup.sh
#
# Usage:
#   source "$COMMON/setup-claude.sh"

set -euo pipefail

echo "==> Setting up Claude Code CLI..."
if ! command -v claude >/dev/null 2>&1; then
  curl -fsSL https://claude.ai/install.sh | bash
  echo "    Claude Code CLI installed"
else
  echo "    Claude Code CLI already installed"
fi
