#!/usr/bin/env bash
# Canonical init-host.sh template for devcontainer repos.
# Runs on the HOST before the container starts.
# Creates bind-mount source dirs and extracts credentials
# that macOS stores in the Keychain rather than on disk.
set -euo pipefail

mkdir -p "${HOME}/.claude" "${HOME}/.config/ai/claude/identity/gh" "${HOME}/.config/ai/claude/credentials" "${HOME}/data"

# Save host hostname for the container to use
hostname > "$(dirname "$0")/.hostname"

# Ensure bind-mount source dirs exist (Docker fails if a mount source is
# missing). Note: ~/.claude.json is intentionally NOT created/mounted anymore
# — each container seeds its own copy in setup-claude.sh.
mkdir -p "${HOME}/.config/ai/xai"

# Extract the stable identity/onboarding keys from the host ~/.claude.json
# into a seed file inside the mounted ~/.claude dir. setup-claude.sh copies it
# to the container-private ~/.claude.json so fresh containers skip the welcome
# flow: Claude Code's logged-in check needs oauthAccount/userID in
# ~/.claude.json, not just the tokens in ~/.claude/.credentials.json.
if [ -s "${HOME}/.claude.json" ]; then
  if python3 - "${HOME}/.claude.json" "${HOME}/.claude/.claude.json.seed" <<'PYEOF'
import json, sys
keep = ("hasCompletedOnboarding", "installMethod", "theme",
        "oauthAccount", "userID", "lastOnboardingVersion")
with open(sys.argv[1]) as f:
    data = json.load(f)
seed = {k: data[k] for k in keep if k in data}
seed["hasCompletedOnboarding"] = True
with open(sys.argv[2], "w") as f:
    json.dump(seed, f)
PYEOF
  then
    chmod 600 "${HOME}/.claude/.claude.json.seed"
  else
    echo "WARN: could not extract ~/.claude/.claude.json.seed; fresh containers will prompt for login" >&2
  fi
fi

# macOS: Claude Code stores OAuth tokens in the system Keychain,
# not in ~/.claude/.credentials.json. Extract them so the bind
# mount makes them available inside the container.
if command -v security &>/dev/null; then
  if creds=$(security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null); then
    echo "$creds" > "${HOME}/.claude/.credentials.json"
    chmod 600 "${HOME}/.claude/.credentials.json"
  fi
fi
