#!/usr/bin/env bash
# claude-session-identity.sh -- a Claude Code SessionStart hook that stamps the
# SESSION into every commit the session makes (bdh-org/home-infra#755).
#
#   bdh-ai (architect)   ->   bdh-ai (architect, session 1a2b3c4d)
#
# WHY
#
#   setup-claude-identity.sh names the ROLE, from PROJECT_NAME, once per
#   container. With every session now running in one devcontainer, every
#   session in the fleet commits as `bdh-ai (architect)`, and two concurrent
#   sessions are indistinguishable after the fact -- the condition behind the
#   2026-08-05 incident, where two sessions made the byte-identical
#   SCRIPT_VERSION bump and git merged it as agreement.
#
# WHY THE SESSION ID, AND NOT THE BRANCH OR WORKTREE NAME
#
#   The issue proposed the branch. But a session changes branch and worktree
#   mid-conversation, and two sessions on one branch -- the collision case --
#   would carry the same stamp. The session id is the thing that is actually
#   unique, it never changes within a conversation, and it is traceable: it is
#   the name of the transcript, ~/.claude/projects/<project>/<id>.jsonl. The
#   branch is already on every PR and in every push; it did not need stamping.
#
# WHY GIT_AUTHOR_NAME IN THE SESSION'S ENVIRONMENT
#
#   Everything else considered writes somewhere shared or hijacks something:
#
#   * `git config --worktree user.name` needs `extensions.worktreeConfig` in the
#     repo's .git/config -- a bind mount of Brian's host checkout, the exact
#     file bdh-org/home-infra#317 says never to write -- and it changes how his
#     own git (and any libgit2 tool) reads that repo.
#   * A global `core.hooksPath` commit-msg hook silently disables every repo's
#     own .git/hooks, unless it re-implements dispatch for every hook name.
#   * ~/.gitconfig-role is written once per container and cannot know which
#     session is committing.
#
#   Claude Code gives SessionStart hooks a CLAUDE_ENV_FILE whose exports are
#   applied to every Bash command the session runs. That is per-session by
#   construction, lives in ~/.claude/session-env (container-local), and touches
#   no repo. git gives GIT_AUTHOR_NAME / GIT_COMMITTER_NAME precedence over
#   user.name, so the ROLE file stays the single source of the base name.
#   user.email is left alone: every session IS bdh-ai.
#
# WHERE IT DOES NOTHING (by design, and tested)
#
#   * GITHUB_ACTIONS is set: a headless agent run loads the same project hooks,
#     and its commits must stay `bdh-org-coder[bot]` (issues/862 in home-infra).
#   * The base user.name is not bdh-ai: a human's own Claude session on a host
#     is not a bdh-ai session and must not be renamed.
#   * No CLAUDE_ENV_FILE (an older Claude Code) or no session id: nothing to do.
#
# REVERSAL TRIGGERS
#
#   * A distinct identity per seat lands (bdh-org/home-infra#262) -- the account
#     then tells sessions apart and this suffix is redundant.
#   * A commit from a live session is found WITHOUT the suffix: CLAUDE_ENV_FILE
#     semantics changed, and the fallback is a commit-msg trailer via a
#     dispatching core.hooksPath.
#
# Wire it as a SessionStart hook (synchronous -- it must finish before the first
# Bash command), e.g. in a repo's .claude/settings.json:
#
#   { "type": "command", "timeout": 10,
#     "command": "f=\"${CLAUDE_PROJECT_DIR:-.}/common/devcontainer/claude-session-identity.sh\"; [ ! -f \"$f\" ] || bash \"$f\"" }
#
# Always exits 0: a hook that fails must never stop a session from starting.

set -uo pipefail

MARK="# claude-session-identity (bdh-org/home-infra#755)"

[ -z "${GITHUB_ACTIONS:-}" ] || exit 0
[ -n "${CLAUDE_ENV_FILE:-}" ] || exit 0

# The hook input is JSON on stdin carrying session_id; fall back to the
# environment variable Claude Code also exports. Read stdin only when it is not
# a terminal, so a hand-run for debugging does not hang.
input=""
[ -t 0 ] || input="$(cat 2>/dev/null || true)"
sid="$(printf '%s' "$input" | sed -nE 's/.*"session_id"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/p' | head -1)"
[ -n "$sid" ] || sid="${CLAUDE_CODE_SESSION_ID:-}"
# Hex and dashes only: this value is written into a file that gets sourced.
sid="$(printf '%s' "$sid" | tr -cd '0-9a-fA-F-' | cut -c1-8)"
[ -n "$sid" ] || exit 0

base="$(git config --global --includes --get user.name 2>/dev/null || true)"
case "$base" in
  "bdh-ai") name="bdh-ai (session $sid)" ;;
  "bdh-ai ("*")") name="${base%)}, session $sid)" ;;
  *) exit 0 ;;
esac
# The role comes from PROJECT_NAME via a container-local file, but refuse
# anything that could break out of the single quotes below.
case "$name" in *"'"*|*$'\n'*) exit 0 ;; esac

# Replace this hook's own earlier lines (a resumed or compacted session runs
# SessionStart again), leave anything another hook wrote.
if [ -f "$CLAUDE_ENV_FILE" ]; then
  tmp="$(mktemp "${CLAUDE_ENV_FILE}.XXXXXX")" || exit 0
  grep -vF "$MARK" "$CLAUDE_ENV_FILE" > "$tmp" || true
  mv -f "$tmp" "$CLAUDE_ENV_FILE" || { rm -f "$tmp"; exit 0; }
fi
{
  printf "export GIT_AUTHOR_NAME='%s' %s\n" "$name" "$MARK"
  printf "export GIT_COMMITTER_NAME='%s' %s\n" "$name" "$MARK"
} >> "$CLAUDE_ENV_FILE" || true
exit 0
