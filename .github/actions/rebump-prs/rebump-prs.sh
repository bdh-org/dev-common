#!/usr/bin/env bash
# rebump-prs.sh -- after main moves, find every open PR whose VERSION is no longer
# above main's and say what it must be re-bumped to (bdh-org/dev-common#344).
#
# Every PR bumps VERSION from the main it branched from, so each merge leaves the
# other open PRs either in a version-line conflict or, when two picked the same
# number, merging cleanly as AGREEMENT under a number that is already taken. The
# trigger is therefore "PR version <= main version", not "git reports a conflict".
#
# THE NUMBER IS PROVISIONAL. A PR is re-bumped to main's version plus its own
# level (patch/minor/major, read from its version against its merge base -- an
# invariant that survives re-bumps, since a re-bumped branch's merge base is the
# main it was bumped from). Several open PRs may land on the same provisional
# number; the first to merge keeps it and the next run moves the rest. Assigning
# distinct numbers in queue order breaks the moment PRs merge out of order.
#
# STAGE 1: MODE=report only. It pushes nothing; it prints what it WOULD do so the
# numbering can be checked against real merges before anything writes. Stage 2
# (MODE=push) merges main, keeps main's side of version-only hunks, and runs the
# repo's own `make bump-<level>` -- so each repo's version files stay the business
# of its own version.mk, not of a second copy here.
#
# Env: GH_TOKEN (lists PRs; the checkout's own credential fetches their heads), REPO (owner/name),
#      MODE (report), BASE (default main). Runs inside a full-history checkout.
set -euo pipefail

MODE="${MODE:-report}"
BASE="${BASE:-main}"
: "${REPO:?REPO=owner/name is required}"
SUMMARY="${GITHUB_STEP_SUMMARY:-/dev/null}"

if [ "$MODE" != report ]; then
  echo "::error::MODE=$MODE is not built yet; only MODE=report exists (stage 1 of bdh-org/dev-common#344)"
  exit 2
fi

version_at() {  # the Makefile VERSION at a revision, empty if none
  git show "$1:Makefile" 2>/dev/null \
    | sed -nE 's/^VERSION[[:space:]]*=[[:space:]]*([0-9]+\.[0-9]+\.[0-9]+)[[:space:]]*$/\1/p' | head -n1
}

# -1, 0 or 1 as $1 is below, equal to or above $2.
compare_versions() {
  local a b i
  IFS=. read -ra a <<<"$1"; IFS=. read -ra b <<<"$2"
  for i in 0 1 2; do
    if (( a[i] > b[i] )); then echo 1; return; fi
    if (( a[i] < b[i] )); then echo -1; return; fi
  done
  echo 0
}

# The level a PR chose: how its version differs from the one it branched from.
bump_level() {
  local base pr
  IFS=. read -ra base <<<"$1"; IFS=. read -ra pr <<<"$2"
  if (( pr[0] > base[0] )); then echo major
  elif (( pr[0] == base[0] && pr[1] > base[1] )); then echo minor
  elif (( pr[0] == base[0] && pr[1] == base[1] && pr[2] > base[2] )); then echo patch
  else echo none
  fi
}

next_version() {
  local v
  IFS=. read -ra v <<<"$1"
  case "$2" in
    major) echo "$((v[0] + 1)).0.0" ;;
    minor) echo "${v[0]}.$((v[1] + 1)).0" ;;
    patch) echo "${v[0]}.${v[1]}.$((v[2] + 1))" ;;
  esac
}

# A line that only states a version: the Makefile line, __version__, a JSON
# "version" field, or a bare served version file (VERSION_TXT).
VERSION_LINE='^(VERSION[[:space:]]*=.*|[[:space:]]*__version__[[:space:]]*=.*|[[:space:]]*"version"[[:space:]]*:[[:space:]]*"[^"]*",?|[0-9]+\.[0-9]+\.[0-9]+)[[:space:]]*$'

# Reads one file's merged content (with conflict markers) on stdin. Succeeds
# only if every line inside every conflict block is a version line. Marker lines
# are matched as single lines, never across newlines: a resolver that matched
# them greedily once wiped most of a Makefile (2026-11-03, panoptikon#1084).
only_version_conflicts() {
  awk -v re="$VERSION_LINE" '
    /^<<<<<<< / { inside = 1; next }
    /^=======$/ && inside { next }
    /^>>>>>>> / { inside = 0; next }
    inside && $0 !~ /^[[:space:]]*$/ && $0 !~ re { bad = 1 }
    END { exit bad }'
}

# Prints the files git cannot merge for reasons other than version lines.
# Empty output: the PR merges with main cleanly or with version-only conflicts.
other_conflicts() {
  local head="$1" out tree file
  if out="$(git -c merge.conflictStyle=merge merge-tree --write-tree --name-only "origin/$BASE" "$head")"; then
    return 0
  fi
  tree="$(sed -n 1p <<<"$out")"
  # Lines 2.. up to the first blank line are the conflicted paths.
  while IFS= read -r file; do
    [ -n "$file" ] || break
    if ! git cat-file -p "$tree:$file" 2>/dev/null | only_version_conflicts; then
      echo "$file"
    fi
  done < <(sed -n '2,$p' <<<"$out")
}

git fetch -q origin "+refs/heads/$BASE:refs/remotes/origin/$BASE"
main_version="$(version_at "origin/$BASE")"
if [ -z "$main_version" ]; then
  echo "$BASE has no Makefile VERSION -- nothing to re-bump"
  exit 0
fi
echo "$BASE is at $main_version (mode: $MODE)"
{
  echo "### Re-bump report -- $BASE at \`$main_version\` (mode: $MODE, nothing pushed)"
  echo
  echo "| PR | version | verdict |"
  echo "| --- | --- | --- |"
} >>"$SUMMARY"

# curl and jq, not `gh`: forge's runner has no gh CLI (the first live run died
# on "gh: command not found"), the same reason version-claimed.sh uses curl.
# GraphQL, because REST has no reviewDecision.
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
query='query($o:String!,$n:String!,$b:String!){repository(owner:$o,name:$n){pullRequests(states:OPEN,baseRefName:$b,first:100){nodes{number isDraft isCrossRepository reviewDecision autoMergeRequest{enabledAt}}}}}'
jq -n --arg q "$query" --arg o "${REPO%%/*}" --arg n "${REPO#*/}" --arg b "$BASE" \
  '{query: $q, variables: {o: $o, n: $n, b: $b}}' >"$tmp/query.json"
status="$(curl -sS -o "$tmp/prs.json" -w '%{http_code}' -X POST \
  -H "Authorization: bearer $GH_TOKEN" --data @"$tmp/query.json" \
  "${GITHUB_GRAPHQL_URL:-https://api.github.com/graphql}")" || status=000
if [ "$status" != 200 ] || ! jq -e '.data.repository.pullRequests.nodes' "$tmp/prs.json" >/dev/null 2>&1; then
  echo "::error::could not list open PRs of $REPO (HTTP $status): $(head -c 400 "$tmp/prs.json" 2>/dev/null)"
  exit 1
fi
prs="$(jq '.data.repository.pullRequests.nodes' "$tmp/prs.json")"

while IFS=$'\t' read -r n draft fork review automerge; do
  verdict=""
  pr_version=""
  if [ "$draft" = true ]; then
    verdict="skipped: draft"
  elif [ "$fork" = true ]; then
    verdict="skipped: branch is in a fork"
  else
    git fetch -q origin "+refs/pull/$n/head:refs/rebump/pr/$n"
    head="refs/rebump/pr/$n"
    pr_version="$(version_at "$head")"
    base_version="$(version_at "$(git merge-base "origin/$BASE" "$head")")"
    if [ -z "$pr_version" ] || [ -z "$base_version" ]; then
      verdict="skipped: no Makefile VERSION on the PR or its base"
    elif [ "$(compare_versions "$pr_version" "$main_version")" = 1 ]; then
      verdict="ok: above $BASE"
    else
      level="$(bump_level "$base_version" "$pr_version")"
      if [ "$level" = none ]; then
        verdict="skipped: no bump of its own (the version guard reports it)"
      else
        new_version="$(next_version "$main_version" "$level")"
        others="$(other_conflicts "$head" | paste -sd, -)"
        if [ -n "$others" ]; then
          verdict="left alone: conflicts outside version lines in $others"
        elif [ "$review" = APPROVED ] || [ "$automerge" = true ]; then
          verdict="WOULD RE-BUMP to $new_version ($level)"
        else
          verdict="would re-bump to $new_version ($level) once approved or set to auto-merge"
        fi
      fi
    fi
  fi
  echo "#$n ${pr_version:-?}: $verdict"
  echo "| #$n | ${pr_version:-?} | $verdict |" >>"$SUMMARY"
done < <(jq -r 'sort_by(.number)[]
  | [.number, .isDraft, .isCrossRepository, (.reviewDecision // "-" | if . == "" then "-" else . end), (.autoMergeRequest != null)]
  | @tsv' <<<"$prs")
