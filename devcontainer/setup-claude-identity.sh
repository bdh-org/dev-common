#!/usr/bin/env bash
# setup-claude-identity.sh - establish Claude's git identity in the container.
# Bootstraps ~/.claude/identity/.gitconfig if missing (the file persists on
# the host via the ~/.claude bind mount, so subsequent containers reuse it),
# then symlinks ~/.gitconfig to it so every git invocation reads the same
# Claude-attributed config.
#
# Usage (from your project's .devcontainer/setup.sh):
#   source "$COMMON/setup-claude-identity.sh"
#
# Replaces the older host-gitconfig-seed mechanism for Claude devcontainers.
# See devtemplate#35 for rationale and dev-common#54 for rollout.

set -euo pipefail

IDENTITY_DIR="$HOME/.claude/identity"
GITCONFIG="$IDENTITY_DIR/.gitconfig"

mkdir -p "$IDENTITY_DIR"

if [ ! -f "$GITCONFIG" ]; then
  echo "==> Bootstrapping Claude gitconfig at $GITCONFIG..."
  cat > "$GITCONFIG" <<'EOF'
[user]
	name = bdh-ai
	email = 282552773+bdh-ai@users.noreply.github.com
[init]
	defaultBranch = main
[filter "lfs"]
	clean = git-lfs clean -- %f
	smudge = git-lfs smudge -- %f
	process = git-lfs filter-process
	required = true
[credential "https://github.com"]
	helper =
	helper = !/usr/bin/gh auth git-credential
[credential "https://gist.github.com"]
	helper =
	helper = !/usr/bin/gh auth git-credential
EOF
fi

ln -sfn "$GITCONFIG" "$HOME/.gitconfig"
echo "==> ~/.gitconfig -> $GITCONFIG (bdh-ai identity)"
