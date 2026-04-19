#!/usr/bin/env bash
# setup-waterbrother.sh - waterbrother CLI setup
# Source this script from your project's .devcontainer/setup.sh
#
# Usage:
#   source "$COMMON/setup-waterbrother.sh"

set -euo pipefail

echo "==> Setting up waterbrother..."
if ! command -v waterbrother >/dev/null 2>&1; then
  npm install -g @tritard/waterbrother
  echo "    waterbrother installed"
else
  echo "    waterbrother already installed"
fi
