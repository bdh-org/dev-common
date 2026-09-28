#!/usr/bin/env bash
# install.sh -- install the Claude Code CLI under the host-wide install lock and
# hand back a PRIVATE copy of the binary (bdh-org/home-infra#881).
#
# THE CRITICAL SECTION IS THIS SCRIPT, AND ONLY THIS SCRIPT
#
#   The lock (../claude-install-lock/lock.sh) exists because every runner unit on
#   forge shares one HOME, and the official installer downloads to the hardcoded
#   $HOME/.claude/downloads/claude-<version>-<platform>, execs it, then deletes it.
#   Two concurrent installs therefore read each other's half-written file
#   ("Checksum verification failed") or exec a file the peer still holds open for
#   writing (ETXTBSY) -- bdh-org/home-infra#541. Nothing about RUNNING Claude
#   needs mutual exclusion: before that lock existed, concurrent agent runs failed
#   only in the install. So the lock is taken here, released on exit, and the
#   long claude-code-action step runs with no lock at all.
#
# WHY A PRIVATE COPY, NOT THE SHARED ~/.local/bin/claude
#
#   The installer lands the binary at ~/.local/share/claude/versions/<version>
#   and points ~/.local/bin/claude at it (measured, installer of 2026-09-28).
#   Those paths are SHARED: once the lock is released, the next run's install
#   may rewrite the symlink, rewrite that version file, or prune old versions --
#   while this run's agent is executing it. That would be #541 again, moved from
#   the download to the run, and it would appear 20 minutes into someone's
#   agent run rather than in its first second. So, still under the lock, the
#   binary is copied into $RUNNER_TEMP (per runner unit, emptied by the runner
#   for each job) and the copy is what claude-code-action executes. Nothing any
#   later install does can touch it. The native CLI is one self-contained file;
#   a copy runs (verified: `cp` then `--version` from an unrelated directory).
#
# WHY THE ACTION'S OWN PIN
#
#   claude-code-action pins the CLI version in its source (`const
#   claudeCodeVersion = "2.1.283"` in src/entrypoints/run.ts) and installs
#   exactly that. Installing anything else here would silently decouple the CLI
#   from the SDK the action was released against -- and the action's docs warn
#   about precisely that for path_to_claude_code_executable. The runner
#   downloads every `uses:` action at job setup, so the pin is read from that
#   download: it moves exactly when @v1 moves, with nothing here to bump. If it
#   cannot be read (upstream renamed the constant), this WARNS and installs
#   `stable` rather than failing every agent run in the fleet over a string.
#
# ENV:
#   LOCK_OWNER             identity recorded in the lock (required)
#   LOCK_SH                path to claude-install-lock/lock.sh (required)
#   CLAUDE_CODE_VERSION    explicit version; empty = the action's pin
#   CCA_DIR                claude-code-action's checkout on the runner
#                          (default: derived from GITHUB_WORKSPACE)
#   CLAUDE_OUT_DIR         where the private copy goes (default $RUNNER_TEMP/claude-code)
#   CLAUDE_INSTALL_CMD     installer command, run with the version as $1
#                          (tests override; default: the official install.sh)
#   INSTALL_RETRY_SLEEP    seconds between installer attempts (default 5)
#
# OUTPUT: path=<copy> and version=<version> to $GITHUB_OUTPUT.
# EXIT:   0 installed; 1 anything else -- and the lock is released either way.

set -uo pipefail

say()  { printf '%s\n' "$*"; }
warn() { printf '::warning::%s\n' "$*"; }
err()  { printf '::error::%s\n' "$*"; }

: "${LOCK_OWNER:?LOCK_OWNER is required}"
: "${LOCK_SH:?LOCK_SH is required}"
OUT_DIR="${CLAUDE_OUT_DIR:-${RUNNER_TEMP:-/tmp}/claude-code}"
RETRY_SLEEP="${INSTALL_RETRY_SLEEP:-5}"
# Same command claude-code-action runs, pipefail included (upstream #1136: without
# it a curl 403/429 is swallowed and the "install" succeeds with nothing installed).
DEFAULT_INSTALL_CMD='set -o pipefail; curl -fsSL https://claude.ai/install.sh | bash -s -- "$1"'
INSTALL_CMD="${CLAUDE_INSTALL_CMD:-$DEFAULT_INSTALL_CMD}"

# --- which version -------------------------------------------------------------

# The pinned version in a claude-code-action checkout, or nothing.
action_pin() { # dir
  local d="$1" f
  for f in "$d/src/entrypoints/run.ts" "$d/base-action/src/run-claude.ts"; do
    [ -r "$f" ] || continue
    sed -nE 's/.*claudeCodeVersion[[:space:]]*=[[:space:]]*"([0-9]+\.[0-9]+\.[0-9]+[^"]*)".*/\1/p' "$f" | head -1
    return 0
  done
}

resolve_version() {
  if [ -n "${CLAUDE_CODE_VERSION:-}" ]; then
    say "claude-code-install: version ${CLAUDE_CODE_VERSION} (given explicitly)" >&2
    echo "$CLAUDE_CODE_VERSION"; return
  fi
  local dir="${CCA_DIR:-}" pin=""
  if [ -z "$dir" ] && [ -n "${GITHUB_WORKSPACE:-}" ]; then
    # GITHUB_WORKSPACE is <runner>/_work/<repo>/<repo>; actions live in _work/_actions.
    dir="$(dirname "$(dirname "$GITHUB_WORKSPACE")")/_actions/anthropics/claude-code-action/v1"
  fi
  [ -n "$dir" ] && pin="$(action_pin "$dir")"
  if [ -n "$pin" ]; then
    say "claude-code-install: version ${pin} (claude-code-action's own pin, read from ${dir})" >&2
    echo "$pin"
  else
    warn "claude-code-install: could not read claude-code-action's pinned CLI version under '${dir:-<no GITHUB_WORKSPACE>}' -- installing 'stable' instead. The agent will run, but on a CLI version the action was not released against; fix the pin lookup in dev-common/.github/actions/claude-code-install/install.sh (bdh-org/home-infra#881)." >&2
    echo stable
  fi
}

VERSION="$(resolve_version)"
case "$VERSION" in
  stable|latest) EXACT="" ;;
  [0-9]*.[0-9]*.[0-9]*) EXACT="$VERSION" ;;
  *) err "claude-code-install: '$VERSION' is not a Claude Code version (want X.Y.Z, stable or latest)"; exit 1 ;;
esac

# --- the critical section --------------------------------------------------------

lock() { LOCK_MODE="$1" LOCK_OWNER="$LOCK_OWNER" bash "$LOCK_SH"; }

lock acquire || exit 1
# Released on EVERY exit path, including the runner cancelling the step (SIGINT,
# then SIGTERM). Owner-checked in lock.sh, so a lock stolen from us as stale is
# never freed by our late release. A hard kill skips this; the stale window covers it.
trap 'lock release' EXIT
trap 'exit 130' INT TERM

SHARED_BIN="$HOME/.local/share/claude/versions/${EXACT:-none}"

# The first field of `claude --version` ("2.1.283 (Claude Code)"), or nothing.
version_of() { DISABLE_AUTOUPDATER=1 "$1" --version 2>/dev/null | awk 'NR==1 {print $1}'; }

if [ -n "$EXACT" ] && [ -x "$SHARED_BIN" ] && [ "$(version_of "$SHARED_BIN")" = "$EXACT" ]; then
  # Already on the host from an earlier run: no 240MB download, and the lock is
  # held for the length of one copy.
  say "claude-code-install: ${EXACT} is already installed at ${SHARED_BIN} -- reusing it"
  SRC="$SHARED_BIN"
else
  ok=""
  for attempt in 1 2 3; do
    say "claude-code-install: installing Claude Code ${VERSION} (attempt ${attempt} of 3)"
    if bash -c "$INSTALL_CMD" claude-install "$VERSION"; then ok=1; break; fi
    [ "$attempt" -lt 3 ] && sleep "$RETRY_SLEEP"
  done
  if [ -z "$ok" ]; then
    err "claude-code-install: the Claude Code installer failed 3 times for ${VERSION}. Nothing is running yet and no work was lost -- this is the install, not the issue. Re-run the job."
    exit 1
  fi
  if [ -n "$EXACT" ]; then
    SRC="$SHARED_BIN"
  else
    SRC="$(readlink -f "$HOME/.local/bin/claude" 2>/dev/null || true)"
  fi
fi

if [ -z "${SRC:-}" ] || [ ! -x "$SRC" ]; then
  err "claude-code-install: the installer reported success but there is no executable at '${SRC:-$HOME/.local/bin/claude}'. Its layout may have changed (expected ~/.local/share/claude/versions/<version> behind ~/.local/bin/claude)."
  exit 1
fi

mkdir -p "$OUT_DIR" || { err "claude-code-install: cannot create $OUT_DIR"; exit 1; }
# Copy to a temp name, then rename: a copy interrupted half-way never leaves a
# truncated `claude` for the agent step to exec.
if ! cp --reflink=auto "$SRC" "$OUT_DIR/claude.partial" 2>/dev/null \
   && ! cp "$SRC" "$OUT_DIR/claude.partial"; then
  err "claude-code-install: could not copy $SRC to $OUT_DIR"
  exit 1
fi
chmod +x "$OUT_DIR/claude.partial" && mv -f "$OUT_DIR/claude.partial" "$OUT_DIR/claude"

GOT="$(version_of "$OUT_DIR/claude")"
if [ -z "$GOT" ]; then
  err "claude-code-install: the copied binary at $OUT_DIR/claude does not run (\`--version\` printed nothing)"
  exit 1
fi
if [ -n "$EXACT" ] && [ "$GOT" != "$EXACT" ]; then
  err "claude-code-install: asked for ${EXACT} but the binary reports ${GOT}"
  exit 1
fi

say "claude-code-install: Claude Code ${GOT} ready at ${OUT_DIR}/claude (a private copy -- later installs on this host cannot touch it)"
if [ -n "${GITHUB_OUTPUT:-}" ]; then
  printf 'path=%s\nversion=%s\n' "$OUT_DIR/claude" "$GOT" >> "$GITHUB_OUTPUT"
fi
exit 0
