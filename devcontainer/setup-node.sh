#!/usr/bin/env bash
# setup-node.sh - Claude Code CLI setup (native installer)
# Source this script from your project's .devcontainer/setup.sh
#
# Usage:
#   source "$COMMON/setup-node.sh"
#
# Installs: Claude Code CLI via native installer

set -euo pipefail

echo "==> Setting up Claude Code CLI..."
if ! command -v claude >/dev/null 2>&1; then
  curl -fsSL https://claude.ai/install.sh | bash
  echo "    Claude Code CLI installed"
else
  echo "    Claude Code CLI already installed"
fi
