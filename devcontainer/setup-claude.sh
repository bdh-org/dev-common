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

# Install the claude-prod shim that proxies to the prod wrapper over SSH.
# The corresponding server-side scripts and one-time setup live in
# brianholland/home-site:claude-access/.  The private key is expected at
# ~/.config/ai/claude/credentials/prod-readonly (host bind-mounted into every
# devcontainer per the bind mount in devtemplate's devcontainer.json).
echo "==> Installing claude-prod shim..."
sudo tee /usr/local/bin/claude-prod >/dev/null <<'CLAUDE_PROD_EOF'
#!/usr/bin/env bash
# claude-prod — devcontainer-side wrapper that ssh's the original command
# to the constrained `claude` account on prod (or another host via
# CLAUDE_PROD_HOST). The remote authorized_keys forces invocation of the
# server-side claude-prod wrapper, which validates against an allowlist.
set -euo pipefail

KEY="${HOME}/.config/ai/claude/credentials/prod-readonly"
HOST="${CLAUDE_PROD_HOST:-prod}"

if [[ ! -r "$KEY" ]]; then
  echo "claude-prod: missing key at $KEY" >&2
  echo "claude-prod: run the one-time setup in home-site/claude-access/INSTALL.md" >&2
  exit 2
fi
if [[ "$#" -eq 0 ]]; then
  echo "claude-prod: usage: claude-prod <verb> [args...]" >&2
  echo "claude-prod: e.g. claude-prod docker-logs hog --tail 200" >&2
  exit 2
fi

exec ssh \
  -i "$KEY" \
  -o IdentitiesOnly=yes \
  -o StrictHostKeyChecking=accept-new \
  -o BatchMode=yes \
  "claude@${HOST}" "$@"
CLAUDE_PROD_EOF
sudo chmod 0755 /usr/local/bin/claude-prod
echo "    claude-prod shim installed at /usr/local/bin/claude-prod"

# Install the claude-dev shim that proxies to the dev wrapper over SSH.
# Parallel to claude-prod above; targets twix (the dev host) by default.
# Server-side scripts and one-time setup live in
# brianholland/home-site:claude-access/INSTALL-dev.md.
echo "==> Installing claude-dev shim..."
sudo tee /usr/local/bin/claude-dev >/dev/null <<'CLAUDE_DEV_EOF'
#!/usr/bin/env bash
# claude-dev - devcontainer-side wrapper that ssh's the original command
# to the constrained `claude` account on the dev host (twix by default,
# or another host via CLAUDE_DEV_HOST). The remote authorized_keys forces
# invocation of the server-side claude-dev wrapper, which validates
# against an allowlist.
set -euo pipefail

KEY="${HOME}/.config/ai/claude/credentials/dev-readonly"
HOST="${CLAUDE_DEV_HOST:-twix}"

if [[ ! -r "$KEY" ]]; then
  echo "claude-dev: missing key at $KEY" >&2
  echo "claude-dev: run the one-time setup in home-site/claude-access/INSTALL-dev.md" >&2
  exit 2
fi
if [[ "$#" -eq 0 ]]; then
  echo "claude-dev: usage: claude-dev <verb> [args...]" >&2
  echo "claude-dev: e.g. claude-dev docker-logs hog --tail 200" >&2
  exit 2
fi

exec ssh \
  -i "$KEY" \
  -o IdentitiesOnly=yes \
  -o StrictHostKeyChecking=accept-new \
  -o BatchMode=yes \
  "claude@${HOST}" "$@"
CLAUDE_DEV_EOF
sudo chmod 0755 /usr/local/bin/claude-dev
echo "    claude-dev shim installed at /usr/local/bin/claude-dev"
