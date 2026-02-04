#!/usr/bin/env bash
# setup-node.sh - Node.js and Claude Code CLI setup
# Source this script from your project's .devcontainer/setup.sh
#
# Usage:
#   [ -x "$(command -v npm)" ] && source "$COMMON/setup-node.sh"
#
# Requires: Node.js/npm (use devcontainer feature ghcr.io/devcontainers/features/node:1)
# Installs: Claude Code CLI

set -euo pipefail

echo "==> Setting up Claude Code CLI..."
if ! command -v claude >/dev/null 2>&1; then
  npm install -g @anthropic-ai/claude-code
  echo "    Claude Code CLI installed"
else
  echo "    Claude Code CLI already installed"
fi
