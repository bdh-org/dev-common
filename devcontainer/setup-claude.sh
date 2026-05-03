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

# Install the claude-min shim that proxies to the prod-min wrapper over SSH.
# The corresponding server-side scripts and one-time setup live in
# brianholland/home-site:claude-access/.  The private key is expected at
# ~/.claude/credentials/claude-min-readonly (the host ~/.claude is bind-
# mounted into every devcontainer per devtemplate's devcontainer.json).
echo "==> Installing claude-min shim..."
sudo tee /usr/local/bin/claude-min >/dev/null <<'CLAUDE_MIN_EOF'
#!/usr/bin/env bash
# claude-min — devcontainer-side wrapper that ssh's the original command
# to the constrained `claude` account on min (or another host via
# CLAUDE_MIN_HOST). The remote authorized_keys forces invocation of the
# server-side claude-min wrapper, which validates against an allowlist.
set -euo pipefail

KEY="${HOME}/.claude/credentials/claude-min-readonly"
HOST="${CLAUDE_MIN_HOST:-min}"

if [[ ! -r "$KEY" ]]; then
  echo "claude-min: missing key at $KEY" >&2
  echo "claude-min: run the one-time setup in home-site/claude-access/INSTALL.md" >&2
  exit 2
fi
if [[ "$#" -eq 0 ]]; then
  echo "claude-min: usage: claude-min <verb> [args...]" >&2
  echo "claude-min: e.g. claude-min docker-logs hog --tail 200" >&2
  exit 2
fi

exec ssh \
  -i "$KEY" \
  -o IdentitiesOnly=yes \
  -o StrictHostKeyChecking=accept-new \
  -o BatchMode=yes \
  "claude@${HOST}" "$@"
CLAUDE_MIN_EOF
sudo chmod 0755 /usr/local/bin/claude-min
echo "    claude-min shim installed at /usr/local/bin/claude-min"
