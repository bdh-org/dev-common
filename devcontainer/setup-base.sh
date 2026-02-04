#!/usr/bin/env bash
# setup-base.sh - Core devcontainer setup
# Source this script from your project's .devcontainer/setup.sh
#
# Usage:
#   source "$COMMON/setup-base.sh"
#
# Installs: tmux, Miniforge (conda-forge)
# Configures: shell aliases, PATH priority

set -euo pipefail

BASHRC="$HOME/.bashrc"
MINIFORGE_DIR="$HOME/miniforge3"

echo "==> Installing system packages..."
sudo apt-get update && sudo apt-get install -y --no-install-recommends tmux

# -----------------------------------------------------------------------------
# Miniforge (replaces bundled conda)
# -----------------------------------------------------------------------------
echo "==> Setting up Miniforge..."
if [ -d "/opt/conda" ]; then
  echo "    Removing /opt/conda..."
  sudo rm -rf /opt/conda
fi

if [ ! -x "$MINIFORGE_DIR/bin/conda" ]; then
  echo "    Installing Miniforge..."
  INSTALLER="/tmp/miniforge_installer.sh"
  curl -fsSL "https://github.com/conda-forge/miniforge/releases/latest/download/Miniforge3-Linux-$(uname -m).sh" -o "$INSTALLER"
  chmod +x "$INSTALLER"
  "$INSTALLER" -b -p "$MINIFORGE_DIR"
  rm -f "$INSTALLER"
else
  echo "    Miniforge already installed"
fi

export PATH="$MINIFORGE_DIR/bin:$PATH"

cat > "$HOME/.condarc" <<'EOF'
channels:
  - conda-forge
channel_priority: strict
EOF

# -----------------------------------------------------------------------------
# Shell config (only append once)
# -----------------------------------------------------------------------------
echo "==> Configuring shell..."
"$MINIFORGE_DIR/bin/conda" init bash

MARKER="# --- devcontainer setup ---"
if ! grep -q "$MARKER" "$BASHRC"; then
  cat >> "$BASHRC" <<'EOF'

# --- devcontainer setup ---
# Conda takes priority over ~/.local/bin to avoid pip packages shadowing conda
export PATH="$HOME/miniforge3/bin:$HOME/.local/bin:$PATH"

# Git
alias gl='git log --oneline --graph --all --decorate'

# ls
alias l='ls -CFT'
alias la='ls -AT'
alias ll='ls -alFT'
EOF
fi

echo "==> Base setup complete"
