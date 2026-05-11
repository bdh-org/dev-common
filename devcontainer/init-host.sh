#!/usr/bin/env bash
# Canonical init-host.sh template for devcontainer repos.
# Runs on the HOST before the container starts.
# Creates bind-mount source dirs and extracts credentials
# that macOS stores in the Keychain rather than on disk.
set -euo pipefail

mkdir -p "${HOME}/.claude" "${HOME}/.config/ai/claude/identity/gh" "${HOME}/.config/ai/claude/credentials" "${HOME}/data"

# Save host hostname for the container to use
hostname > "$(dirname "$0")/.hostname"

# Ensure these files exist so bind mounts don't fail.
# Docker requires the source file to exist for file-level bind mounts.
[ -f "${HOME}/.claude.json" ] || touch "${HOME}/.claude.json"
mkdir -p "${HOME}/.config/ai/xai"

# macOS: Claude Code stores OAuth tokens in the system Keychain,
# not in ~/.claude/.credentials.json. Extract them so the bind
# mount makes them available inside the container.
if command -v security &>/dev/null; then
  if creds=$(security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null); then
    echo "$creds" > "${HOME}/.claude/.credentials.json"
    chmod 600 "${HOME}/.claude/.credentials.json"
  fi
fi
