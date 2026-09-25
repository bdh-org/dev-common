#!/usr/bin/env bash
# setup-claude.sh - Claude Code CLI setup (native installer)
# Source this script from your project's .devcontainer/setup.sh
#
# Usage:
#   source "$COMMON/setup-claude.sh"

set -euo pipefail

echo "==> Setting up Claude Code CLI..."

# Seed ~/.claude.json so per-container Claude Code skips first-run onboarding.
# The host ~/.claude.json is no longer bind-mounted (sharing one file across
# containers caused concurrent-write corruption); each container now owns its
# own copy. Prefer the seed file that init-host.sh extracts from the host's
# ~/.claude.json into the mounted ~/.claude dir: the logged-in check needs the
# identity fields (oauthAccount, userID) in ~/.claude.json, not just tokens in
# ~/.claude/.credentials.json — without them Claude Code runs the full welcome
# flow (theme + login) despite hasCompletedOnboarding. Only seed when absent/
# empty so real state is never clobbered, and do it before the CLI install so
# no first run can beat the seed.
if [ ! -s "${HOME}/.claude.json" ]; then
  if [ -s "${HOME}/.claude/.claude.json.seed" ]; then
    cp "${HOME}/.claude/.claude.json.seed" "${HOME}/.claude.json"
    echo "    seeded ${HOME}/.claude.json from ~/.claude/.claude.json.seed"
  else
    echo '{"hasCompletedOnboarding":true,"installMethod":"native"}' > "${HOME}/.claude.json"
    echo "    seeded ${HOME}/.claude.json minimal stub (no seed file; login will be prompted)"
  fi
  chmod 600 "${HOME}/.claude.json"
fi

if ! command -v claude >/dev/null 2>&1; then
  curl -fsSL https://claude.ai/install.sh | bash
  echo "    Claude Code CLI installed"
else
  echo "    Claude Code CLI already installed"
fi

# Install shared Claude Code skills from dev-common/skills/ (P14). They are
# version-controlled here (one source of truth) and exposed to Claude Code as
# PROJECT-level skills via per-repo RELATIVE symlinks:
#     <repo>/.claude/skills/<name> -> ../../common/skills/<name>
# This is deliberate. We previously symlinked into ~/.claude/skills/ with the
# skill's workspace-ABSOLUTE path, but ~/.claude is bind-mounted from the host
# into every devcontainer, so those links were last-writer-wins: whichever
# container ran setup most recently repointed the shared links at its own
# workspace, dangling them in all others (skills silently vanished). A
# relative, in-workspace link instead:
#   - resolves regardless of the absolute workspace path, so it never collides
#     across containers that share one host ~/.claude;
#   - points at this repo's own common/skills, so `make update-common` (which
#     bumps the dev-common submodule) live-updates the skills with no copy and
#     no devcontainer rebuild.
echo "==> Installing shared Claude Code skills (project-level)..."
COMMON_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_ROOT="$(cd "${COMMON_DIR}/.." && pwd)"
SKILLS_SRC="${COMMON_DIR}/skills"
PROJ_SKILLS="${REPO_ROOT}/.claude/skills"
if [ -d "$SKILLS_SRC" ]; then
  mkdir -p "$PROJ_SKILLS"
  for d in "$SKILLS_SRC"/*/; do
    [ -d "$d" ] || continue
    name="$(basename "$d")"
    rm -rf "${PROJ_SKILLS:?}/${name}"
    ln -s "../../common/skills/${name}" "${PROJ_SKILLS}/${name}"
    echo "    linked project skill: ${name}"
    # Retire the legacy host-level link (workspace-absolute, shared across
    # containers) so it can't shadow the project-level skill or dangle.
    [ -L "${HOME}/.claude/skills/${name}" ] && rm -f "${HOME}/.claude/skills/${name}"
  done
else
  echo "    no skills/ dir at $SKILLS_SRC (skipping)"
fi

# Install the claude-prod shim that proxies to the prod wrapper over SSH.
# The corresponding server-side scripts and one-time setup live in
# bdh-org/home-infra:claude-access/.  The private key is expected at
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
  echo "claude-prod: run the one-time setup in home-infra/claude-access/INSTALL.md" >&2
  exit 2
fi
if [[ "$#" -eq 0 ]]; then
  echo "claude-prod: usage: claude-prod <verb> [args...]" >&2
  echo "claude-prod: e.g. claude-prod docker-logs hog --tail 200" >&2
  exit 2
fi

# An UNSET CLAUDE_PROD_HOST whose fallback does not resolve is a missing
# SETTING, not missing access -- and ssh reports it as "Could not resolve
# hostname prod", which reads as "production is unreachable from here".
# A session believed exactly that for a full day and routed every prod check
# through a human by hand; the scoped account had been usable throughout.
# Only diagnose when the variable is unset, so a configured host still goes
# straight to ssh and nothing that works today can regress.
if [[ -z "${CLAUDE_PROD_HOST:-}" ]] && ! getent hosts "$HOST" >/dev/null 2>&1; then
  echo "claude-prod: CLAUDE_PROD_HOST is not set and the default host '$HOST' does not resolve." >&2
  echo "claude-prod: this is a MISSING SETTING, not missing access -- prod is probably reachable." >&2
  echo "claude-prod: that variable is written under /etc/profile.d by stack-common's" >&2
  echo "claude-prod:   devcontainer/setup-stack-hosts.sh, which runs only in repos that carry the" >&2
  echo "claude-prod:   stack-common submodule. This repo appears not to." >&2
  echo "claude-prod: for one command:  CLAUDE_PROD_HOST=<prod-host> claude-prod $*" >&2
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
# bdh-org/home-infra:claude-access/INSTALL-dev.md.
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
  echo "claude-dev: run the one-time setup in home-infra/claude-access/INSTALL-dev.md" >&2
  exit 2
fi
if [[ "$#" -eq 0 ]]; then
  echo "claude-dev: usage: claude-dev <verb> [args...]" >&2
  echo "claude-dev: e.g. claude-dev docker-logs hog --tail 200" >&2
  exit 2
fi

# Same as claude-prod above: name the unset variable rather than letting ssh
# report a hostname that was never meant to be used literally. claude-dev has
# only ever been luckier, not more correct -- its fallback happens to be a real
# host on this stack, so the identical defect stays hidden here until it isn't.
if [[ -z "${CLAUDE_DEV_HOST:-}" ]] && ! getent hosts "$HOST" >/dev/null 2>&1; then
  echo "claude-dev: CLAUDE_DEV_HOST is not set and the default host '$HOST' does not resolve." >&2
  echo "claude-dev: this is a MISSING SETTING, not missing access -- dev is probably reachable." >&2
  echo "claude-dev: that variable is written under /etc/profile.d by stack-common's" >&2
  echo "claude-dev:   devcontainer/setup-stack-hosts.sh, which runs only in repos that carry the" >&2
  echo "claude-dev:   stack-common submodule. This repo appears not to." >&2
  echo "claude-dev: for one command:  CLAUDE_DEV_HOST=<dev-host> claude-dev $*" >&2
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

# gh-app-token: the per-command GitHub credential (CLAUDE.md -> "GitHub Authentication",
# bdh-org/dev-common#269). A SYMLINK into this repo's common/ checkout, not a copy, so a
# `common` bump updates it with no rebuild. It needs the App key+conf in the bind-mounted
# ~/.config/ai/claude/credentials/; a seat without them gets a clear "no App config" error.
sudo ln -sfn "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/gh-app-token.sh" /usr/local/bin/gh-app-token
echo "    gh-app-token linked at /usr/local/bin/gh-app-token"
