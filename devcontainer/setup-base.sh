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

# -----------------------------------------------------------------------------
# Title trap off (its OWN marker, and placed BEFORE the block below, on purpose)
# -----------------------------------------------------------------------------
# The devcontainers base image's ~/.bashrc, when TERM is exactly "xterm",
# installs `trap 'preexec' DEBUG`, and preexec runs
#     echo -ne "\033]0;${USER}@${HOSTNAME}: ${BASH_COMMAND}\007"
# before EVERY command, to put the running command in the terminal title. The
# trap is live for the rest of ~/.bashrc too, including the PS1 assignment in
# the block below -- whose text contains literal \033[..m colour codes. `echo -e`
# turns those into real ESC bytes INSIDE the title sequence; the terminal aborts
# the title at the first one and prints the remainder of the PS1 line as text:
#     01;32m\]\u@host:proj\[\]:\[\]\w\[\] \[\]$(__git_ps1 "(%s)")\[\]\$ '
# in front of the first prompt of every shell.
#
# TERM=xterm is not exotic: it is what `docker exec -t` injects when nothing
# sets TERM, and `devcontainer exec` (so `make dc-shell`) forwards only
# remoteEnv, never the host's TERM. tmux and VS Code set their own, which is
# why this showed up on one machine and not the others.
#
# Order is the whole fix: the trap has to be gone BEFORE the PS1 line runs. So a
# fresh ~/.bashrc gets this appended ahead of $MARKER's block, and an
# already-built container -- which has that block already -- gets it INSERTED in
# front of the marker line instead of appended after it. Its own marker, for the
# same reason as the PATH dedupe below: $MARKER's guard means nothing added
# inside that block ever reaches an existing container.
# >>> title-trap install >>>
TITLE_MARKER="# --- devcontainer title trap off ---"
if ! grep -qF -- "$TITLE_MARKER" "$BASHRC"; then
  _title_snippet="$(mktemp)"
  cat > "$_title_snippet" <<'EOF'

# --- devcontainer title trap off ---
# The base image's block above sets `trap 'preexec' DEBUG` when TERM is exactly
# "xterm" (docker exec -t's default) and echoes every command into the terminal
# title with `echo -ne`. That mangles any later line holding a literal \033 --
# the PS1 below -- into junk printed before the first prompt. Remove the trap,
# and the precmd it paired with, before anything else runs. Matched on the exact
# trap text so a DEBUG trap someone else installed is left alone.
if [ "$(trap -p DEBUG)" = "trap -- 'preexec' DEBUG" ]; then
  trap - DEBUG
  PROMPT_COMMAND="${PROMPT_COMMAND%precmd}"
  PROMPT_COMMAND="${PROMPT_COMMAND%; }"
fi
EOF
  if grep -qxF -- "$MARKER" "$BASHRC"; then
    _title_tmp="$(mktemp)"
    awk -v m="$MARKER" -v f="$_title_snippet" '
      $0 == m && !done { while ((getline l < f) > 0) print l; print ""; done = 1 }
      { print }
    ' "$BASHRC" > "$_title_tmp"
    # cat, not mv: keep ~/.bashrc's inode, owner and mode exactly as they were.
    cat "$_title_tmp" > "$BASHRC"
    rm -f "$_title_tmp"
  else
    cat "$_title_snippet" >> "$BASHRC"
  fi
  rm -f "$_title_snippet"
  unset _title_snippet _title_tmp
fi
# <<< title-trap install <<<

if ! grep -q "$MARKER" "$BASHRC"; then
  # Build prompt host label: "host:project" if available, else default \h
  _HOST=$(cat "${HOSTNAME_FILE:-/dev/null}" 2>/dev/null || true)
  if [ -n "$_HOST" ] && [ -n "${PROJECT_NAME:-}" ]; then
    PS1_HOST="${_HOST}:${PROJECT_NAME}"
  else
    PS1_HOST='\h'
  fi

  cat >> "$BASHRC" <<EOF

# --- devcontainer setup ---
# UTF-8 locale so tmux + other tools render Unicode correctly. C.UTF-8 is
# available in glibc without locale-gen; works on every dev image we use.
# Without this, tmux mangles non-ASCII bytes on output (em-dash -> "_" etc).
# See brianholland/dev-common#48.
export LANG=C.UTF-8
export LC_ALL=C.UTF-8

# Conda takes priority over ~/.local/bin to avoid pip packages shadowing conda.
# Unconditional on purpose: the dedupe below makes re-sourcing a no-op, and
# prepending first is what keeps this ordering authoritative (dev-common#224).
export PATH="\$HOME/miniforge3/bin:\$HOME/.local/bin:\$PATH"

# Git
alias gl='git log --oneline --graph --all --decorate'
if [ -f /usr/lib/git-core/git-sh-prompt ]; then
  . /usr/lib/git-core/git-sh-prompt
  export GIT_PS1_SHOWDIRTYSTATE=1
  PS1='\${debian_chroot:+(\$debian_chroot)}\[\033[01;32m\]\u@${PS1_HOST}\[\033[00m\]:\[\033[01;34m\]\w\[\033[00m\] \[\033[33m\]\$(__git_ps1 "(%s)")\[\033[00m\]\\\$ '
fi

# ls
alias l='ls -CFT'
alias la='ls -AT'
alias ll='ls -alFT'
EOF
fi

# -----------------------------------------------------------------------------
# PATH dedupe (its OWN marker, on purpose)
# -----------------------------------------------------------------------------
# This is appended independently of the block above because that one is guarded
# by $MARKER, which every already-built container already has -- so anything
# added inside it reaches no existing container, ever. A second marker is what
# lets a container that was set up before this change still receive the fix on
# its next build. See bdh-org/dev-common#224.
PATH_MARKER="# --- devcontainer PATH dedupe ---"
if ! grep -q "$PATH_MARKER" "$BASHRC"; then
  cat >> "$BASHRC" <<'EOF'

# --- devcontainer PATH dedupe ---
# PATH resolution is first-match-wins, so a duplicated entry is a latent
# precedence bug: once two directories hold the same binary name, which one runs
# depends on how many times each got prepended, and therefore on shell nesting
# depth. That differs between an interactive shell and a script, and it stays
# invisible until it bites.
#
# Three files prepend unconditionally and are re-sourced once per nested shell:
# /etc/profile.d/00-restore-env.sh (root-owned, regenerated by the base image on
# every rebuild, and it lists nvm/current/bin TWICE on its single line),
# ~/.profile, and the devcontainer block above. Measured before this fix, PATH
# grew by 8 entries per level -- 10, 18, 26 at depths 1, 2, 3 -- without bound.
#
# Deduping here rather than guarding each prepend is deliberate: two of those
# three files are not ours to edit, and a guard only fixes the line it guards.
# This runs last and fixes all of them at once.
#
# Keeps the FIRST occurrence, so the ordering established above survives intact
# and re-sourcing this file is a genuine no-op. Empty entries are dropped, which
# also removes the implicit "current directory" that a stray leading, trailing
# or doubled colon would otherwise put on PATH.
_dc_dedup_path() {
  local new= entry rest="$PATH"
  while [ -n "$rest" ]; do
    entry="${rest%%:*}"
    case "$rest" in
      *:*) rest="${rest#*:}" ;;
      *)   rest= ;;
    esac
    [ -n "$entry" ] || continue
    case ":$new:" in
      *":$entry:"*) continue ;;
    esac
    new="${new:+$new:}$entry"
  done
  export PATH="$new"
}
_dc_dedup_path
unset -f _dc_dedup_path
EOF
fi

# Git hygiene (idempotent): fetch.prune + the `git gone` alias. The definitions
# live in git-hygiene.sh so the container and the HOST (init-host.sh) assert the
# same thing -- see dev-common#97. Run as a child process, not sourced: it sets
# its own shell options.
echo "==> Configuring git hygiene..."
bash "$(dirname "${BASH_SOURCE[0]}")/git-hygiene.sh"

echo "==> Base setup complete"
