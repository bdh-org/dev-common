#!/usr/bin/env bash
# setup-claude-identity.sh - point ~/.gitconfig and ~/.config/gh at Claude's
# host-managed identity tree.
#
# Identity files live on the host at ~/.config/ai/claude/identity/ and are
# bind-mounted into the container at the same path. This script symlinks the
# standard tool locations (~/.gitconfig, ~/.config/gh) into that tree so git
# and gh find Claude's config at default paths without environment-variable
# indirection. Bootstraps the identity files on a fresh host.
#
# Why ~/.config/ai/claude/ rather than ~/.claude/: ~/.claude/ is Claude Code's
# own state directory (session creds, project memory, settings). User-curated
# config for what Claude SHOULD use is separate, under ~/.config/ai/claude/.
# Forward-compatible with the multi-AI devcontainer concept (devtemplate#36).
#
# Usage (from your project's .devcontainer/setup.sh):
#   source "$COMMON/setup-claude-identity.sh"
#
# Replaces the older host-gitconfig-seed mechanism for Claude devcontainers.
# See devtemplate#35 for rationale and dev-common#54 for rollout.

set -euo pipefail

IDENTITY_DIR="$HOME/.config/ai/claude/identity"
GITCONFIG="$IDENTITY_DIR/.gitconfig"
GH_DIR="$IDENTITY_DIR/gh"

mkdir -p "$IDENTITY_DIR" "$GH_DIR"

# Bootstrap gitconfig if missing (fresh-host case; otherwise it's already
# on the host, bind-mounted in, and we just symlink to it).
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

# Bootstrap gh config.yml if missing.
if [ ! -f "$GH_DIR/config.yml" ]; then
  echo "==> Bootstrapping gh config at $GH_DIR/config.yml..."
  cat > "$GH_DIR/config.yml" <<'EOF'
# gh CLI preferences for the bdh-ai identity.
# Auth state is intentionally absent — gh authenticates per call via
# GH_TOKEN, using the org-scoped PATs at ~/.config/ai/claude/credentials/.

git_protocol: https
prompt: disabled
pager: cat
EOF
fi

# Point standard tool paths at Claude's identity tree. ln -sfn replaces an
# existing symlink atomically; for ~/.config/gh we explicitly remove a
# pre-existing real directory (gh creates one on first invocation if it
# beat us here).
ln -sfn "$GITCONFIG" "$HOME/.gitconfig"
mkdir -p "$HOME/.config"
if [ -e "$HOME/.config/gh" ] && [ ! -L "$HOME/.config/gh" ]; then
  rm -rf "$HOME/.config/gh"
fi
ln -sfn "$GH_DIR" "$HOME/.config/gh"

echo "==> ~/.gitconfig -> $GITCONFIG"
echo "==> ~/.config/gh -> $GH_DIR"
echo "    user.name = $(git config --get user.name)"
echo "    user.email = $(git config --get user.email)"
