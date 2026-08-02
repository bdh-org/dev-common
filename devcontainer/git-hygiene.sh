#!/usr/bin/env bash
# git-hygiene.sh - assert this machine's global git hygiene config.
#
# Single source of truth for `fetch.prune` and the `git gone` alias, applied
# identically on the HOST (init-host.sh) and inside the container
# (setup-base.sh). The alias text used to be copy-pasted into both scripts,
# which is how hosts ended up running whichever revision of it they happened
# to be set up with -- and how hosts that predate the alias never got it at
# all (dev-common#97). Keeping it here means one place to fix and one place
# to check.
#
# Usage:
#   git-hygiene.sh            # apply (idempotent)
#   git-hygiene.sh --check    # report drift, change nothing, exit 1 if drifted
#
# Both modes are safe to run on any machine; nothing here touches a repo,
# only `git config --global`.

set -euo pipefail

# -----------------------------------------------------------------------------
# The `git gone` alias
# -----------------------------------------------------------------------------
# Drops local branches whose upstream was merged+deleted on the remote, so
# checkouts do not pile up stale branches after PRs merge on GitHub.
#
# It is written as a shell function rather than the original
# `git fetch -p && git branch -vv | awk ... | xargs -r git branch -D` chain,
# because that chain had two paths where it exited 0 having pruned nothing:
#
#   1. In a repo with no remote configured, `git fetch -p` itself exits 0
#      quietly, so the chain "succeeded" with nothing fetched and nothing
#      pruned.
#   2. Only the LAST command of a pipeline sets its status, and `xargs -r`
#      with empty input exits 0 -- so a failing `git branch -vv` (or awk) was
#      indistinguishable from "nothing to prune".
#
# A fetch that fails leaves the `: gone]` markers reflecting whatever the
# remote looked like the last time a fetch worked, so the alias now refuses
# to prune at all rather than deleting branches from stale state.
#
# It also skips branches git marks as checked out here (`*`) or in another
# worktree (`+`) with a note, instead of feeding them to `git branch -D` --
# the old awk printed `$1`, which on the current-branch line is the `*`.
#
# Assembled from parts for readability; git stores it as a single line. Note
# the `\$1`/`\$2`: they must reach awk as awk field references, not as the
# shell function's positional parameters. Each part is single-quoted, so keep
# the alias text itself free of single quotes.
GONE_ALIAS_PARTS=(
  '!f() {'
  'if [ -z "$(git remote)" ]; then'
  ' echo "git gone: no remote configured -- nothing to prune" >&2; return 1;'
  'fi;'
  'if ! git fetch -p; then'
  ' echo "git gone: fetch failed -- refusing to prune from stale upstream state" >&2; return 1;'
  'fi;'
  'b=$(git branch -vv) || return 1;'
  'held=$(echo "$b" | awk "/^[*+]/ && /: gone]/{print \$2}");'
  'gone=$(echo "$b" | awk "/^[^*+]/ && /: gone]/{print \$1}");'
  '[ -z "$held" ] || echo "git gone: $held has a gone upstream but is checked out -- switch away to prune it" >&2;'
  'if [ -z "$gone" ]; then echo "git gone: no prunable branches"; return 0; fi;'
  'echo "$gone" | xargs -r git branch -D;'
  '}; f'
)

MODE=apply
case "${1:-}" in
  --check) MODE=check ;;
  "") ;;
  *) echo "usage: $(basename "$0") [--check]" >&2; exit 2 ;;
esac

if ! command -v git >/dev/null 2>&1; then
  echo "git-hygiene: git not installed -- nothing to do" >&2
  # Not an error in --check either: a machine with no git has no drift.
  exit 0
fi

drift=0

# assert_config <key> <wanted-value>: compare against `git config --global`,
# then either report the difference (--check) or write it. Deliberately plain
# bash 3.2 -- no associative arrays -- because init-host.sh runs this on the
# HOST, and macOS still ships /bin/bash 3.2.
assert_config() {
  local key="$1" want="$2" have what
  have=$(git config --global --get "$key" || true)

  if [ "$have" = "$want" ]; then
    if [ "$MODE" = check ]; then echo "  ok      $key"; fi
    return 0
  fi

  drift=1
  if [ -z "$have" ]; then what="missing"; else what="outdated"; fi

  if [ "$MODE" = check ]; then
    echo "  DRIFT   $key ($what)"
  else
    git config --global "$key" "$want"
    echo "  set     $key ($what)"
  fi
}

# Auto-prune deleted remote branches on every fetch/pull.
assert_config fetch.prune true
assert_config alias.gone "${GONE_ALIAS_PARTS[*]}"

if [ "$MODE" = check ]; then
  if [ "$drift" = 0 ]; then
    echo "git hygiene OK"
  else
    echo "git hygiene DRIFT -- run 'make setup-fix' (or 'bash $0') to (re)assert it" >&2
    exit 1
  fi
fi
