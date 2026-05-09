#!/usr/bin/env bash
# setup-git-identity.sh - Set the bdh-ai git identity for Claude commits.
# Source from your project's .devcontainer/setup.sh AFTER the gitconfig seed
# copy, so this write is not overwritten by it.
#
# Usage:
#   [ -f "$GITCONFIG_SEED" ] && cp "$GITCONFIG_SEED" "${HOME}/.gitconfig"
#   source "$COMMON/setup-git-identity.sh"
#
# Devcontainers run Claude Code; commits should attribute to bdh-ai (Claude's
# dedicated GitHub identity), not the host user. Hardcoded for now — see
# devtemplate#35 for the rationale and dev-common#52 for the rollout.

set -euo pipefail

echo "==> Setting git identity to bdh-ai..."
git config --global user.name "bdh-ai"
git config --global user.email "282552773+bdh-ai@users.noreply.github.com"
echo "    user.name = $(git config --get user.name)"
echo "    user.email = $(git config --get user.email)"
