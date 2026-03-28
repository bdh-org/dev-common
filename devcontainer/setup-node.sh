#!/usr/bin/env bash
# setup-node.sh - Claude Code CLI setup (native installer)
# Source this script from your project's .devcontainer/setup.sh
#
# Usage:
#   source "$COMMON/setup-node.sh"
#
# Installs: Claude Code CLI via native installer, waterbrother

set -euo pipefail

echo "==> Setting up Claude Code CLI..."
if ! command -v claude >/dev/null 2>&1; then
  curl -fsSL https://claude.ai/install.sh | bash
  echo "    Claude Code CLI installed"
else
  echo "    Claude Code CLI already installed"
fi

echo "==> Setting up waterbrother..."
if ! command -v waterbrother >/dev/null 2>&1; then
  npm install -g @tritard/waterbrother
  echo "    waterbrother installed"
else
  echo "    waterbrother already installed"
fi
