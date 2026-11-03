#!/usr/bin/env bash
# The "Version claimed by another open PR" gate. See action.yml for why this is a
# composite action called as a step rather than a sibling job, and
# tests/version-claimed.test.sh for the cases that run this file.
#
# THE HALF OF THE COLLISION THAT version-bumped.sh CANNOT SEE. That gate compares
# this branch against its BASE, so it notices a collision only once the other PR
# has MERGED -- by which time both branches claimed the number and one of them is
# being repaired by hand. While the two PRs are merely OPEN, each one's base is
# untouched and each one is individually, verifiably correct. There is nothing for
# a reviewer to see on either diff.
#
# Nor will git object. Two branches cut from the same main each run
# `make bump-patch`, each writes the IDENTICAL VERSION line, and git merges an
# identical edit as AGREEMENT rather than as a conflict. Both land, and one of the
# two versions silently never exists. While tag-version.yml triggered on
# `paths: ['Makefile']`, a bump whose Makefile ended up byte-identical got no tag
# run either -- silent at both ends (bdh-org/home-infra#617). That filter is gone
# (bdh-org/home-infra#625), so the tag run now goes red on main; this gate still
# catches it earlier, at the PR.
#
# Three in one afternoon, 2026-09-20, all in finzeug/heller, all repaired by hand:
# #558 carried 1.3.268 against a main at 1.3.267; #559 was a submodule bump
# carrying no version change at all; #563 carried 1.3.268 against a main already
# at 1.3.269. It scales with how many branches are open at once, which is rising
# as the headless agent is used more (bdh-org/dev-common#255,
# bdh-org/home-infra#674 and #675).
#
# curl AND jq, NOT `gh`. The specifying issue said "a few lines against
# `gh pr list`". There is no `gh` on the forge self-hosted runner, and
# self-hosted-ci.yml is what most of this fleet actually calls -- so a `gh`
# implementation would be green on ubuntu-latest and command-not-found everywhere
# that matters. curl and jq are present on both. Both calls reach curl by NAME
# rather than by absolute path, which is what lets tests/version-claimed.test.sh
# stub it on PATH -- worth preserving if this is ever rewritten.
#
# THE LOWEST PR NUMBER WINS, and only the later PR goes red. Failing both
# deadlocks a pair that is each other's only problem, and blocks the PR that did
# nothing wrong. The tiebreak needs no stored state and reads the same way from
# either side.
#
# A TOKEN THAT CANNOT LIST PRs WARNS RATHER THAN FAILS. This action is consumed at
# @main by the whole fleet, so a hard failure here would turn every caller red at
# once over a permission none of them had been asked for. The warning names the
# exact remedy instead. It is still never a SILENT pass: every path prints what it
# concluded.
#
# Inputs, all from the environment: GITHUB_TOKEN (set by action.yml from
# `github.token`, never interpolated into a command line), PR_NUMBER, BASE_REF,
# plus the runner's own GITHUB_REPOSITORY and GITHUB_API_URL. Passing them in
# rather than templating them into the body is what lets the suite run this exact
# file (bdh-org/dev-common#338).

# `-euo pipefail` reproduces the shell Actions gave this body while it was a
# `run: |` block (`bash --noprofile --norc -eo pipefail`, plus the body's own
# `set -eu`). Spelled out here because `bash script.sh` does NOT inherit the
# calling shell's options, so dropping it would silently relax the gate.
set -euo pipefail

if ! grep -qE '^VERSION[[:space:]]*=' Makefile 2>/dev/null; then
  echo "no VERSION in Makefile -- this repo does not version here, skipping"
  exit 0
fi
head_v=$(grep -m1 -E '^VERSION[[:space:]]*=' Makefile \
  | sed -E 's/^VERSION[[:space:]]*=[[:space:]]*//' | tr -d ' \r')
if [ -z "$head_v" ]; then
  echo "VERSION line is empty -- nothing to compare, skipping"
  exit 0
fi

pr="${PR_NUMBER:-}"
base="${BASE_REF:-}"
repo="${GITHUB_REPOSITORY:-}"
api="${GITHUB_API_URL:-https://api.github.com}"

# KEPT although action.yml always sets GITHUB_TOKEN from `github.token`: an empty
# token is what a caller running this script directly, or a context where
# `github.token` does not resolve, would hand over -- and `curl -H "Authorization:
# Bearer "` returns a 401 whose message explains nothing. Naming the scope here is
# the difference between a reader fixing it in one step and chasing an auth error.
if [ -z "${GITHUB_TOKEN:-}" ]; then
  echo "::warning::No GITHUB_TOKEN, so this repo's other open PRs cannot be"
  echo "::warning::listed and a version one of them already claims will NOT be"
  echo "::warning::detected. Add to the workflow or job that runs this check:"
  echo "::warning::    permissions:"
  echo "::warning::      pull-requests: read"
  exit 0
fi
case "$pr" in
  ''|*[!0-9]*)
    echo "::warning::PR number '$pr' is not numeric -- skipping the open-PR check."
    exit 0 ;;
esac
if [ -z "$repo" ] || [ -z "$base" ]; then
  echo "::warning::No repository/base context -- skipping the open-PR check."
  exit 0
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# `base=` narrows to PRs targeting the same branch: a PR aimed at some
# other base is not competing for this lineage's next number.
if ! status=$(curl -sS -o "$tmp/prs.json" -w '%{http_code}' \
      -H "Authorization: Bearer $GITHUB_TOKEN" \
      -H "Accept: application/vnd.github+json" \
      -H "X-GitHub-Api-Version: 2022-11-28" \
      "$api/repos/$repo/pulls?state=open&base=$base&per_page=100" \
      2>"$tmp/err"); then
  status="000"
fi
if [ "$status" != "200" ]; then
  # The SERVER's own words, never a parser's. A 403 reading "Resource
  # not accessible by integration" ends this in one step; a jq error
  # about a missing key sends the reader somewhere else entirely.
  echo "::warning::Could not list open PRs (HTTP $status). The server said:"
  head -c 400 "$tmp/err" 2>/dev/null | sed 's/^/  /' || true
  head -c 400 "$tmp/prs.json" 2>/dev/null | sed 's/^/  /' || true
  echo ""
  echo "::warning::Most likely the calling job lacks 'pull-requests: read'."
  echo "::warning::A version already claimed by an open PR was NOT checked."
  exit 0
fi

if ! others=$(jq -r --argjson me "$pr" '
      .[] | select(.number != $me)
          | [ (.number|tostring), .head.sha,
              (.draft|tostring), .title ] | @tsv
      ' "$tmp/prs.json" 2>"$tmp/jqerr"); then
  echo "::warning::Could not parse the open-PR list:"
  sed 's/^/  /' "$tmp/jqerr" 2>/dev/null || true
  echo "::warning::A version already claimed by an open PR was NOT checked."
  exit 0
fi
if [ -z "$others" ]; then
  echo "no other open PR against $base -- $head_v is uncontested"
  exit 0
fi

# A DRAFT still counts. It holds the number and can be marked ready at
# any moment, so excluding drafts would reintroduce the silent
# collision this step exists to remove. It is labelled, so the author
# can judge whether to chase it.
earliest=""
lower=""
higher=""
while IFS="$(printf '\t')" read -r n sha draft title; do
  [ -n "${n:-}" ] || continue
  if ! st=$(curl -sS -o "$tmp/mk" -w '%{http_code}' \
        -H "Authorization: Bearer $GITHUB_TOKEN" \
        -H "Accept: application/vnd.github.raw" \
        "$api/repos/$repo/contents/Makefile?ref=$sha" \
        2>/dev/null); then
    st="000"
  fi
  if [ "$st" != "200" ]; then
    echo "  PR #$n: no readable Makefile at $sha (HTTP $st) -- not compared"
    continue
  fi
  v=$(grep -m1 -E '^VERSION[[:space:]]*=' "$tmp/mk" 2>/dev/null \
    | sed -E 's/^VERSION[[:space:]]*=[[:space:]]*//' | tr -d ' \r' || true)
  if [ -z "$v" ]; then
    echo "  PR #$n: no VERSION line -- not compared"
    continue
  fi
  if [ "$v" != "$head_v" ]; then
    echo "  PR #$n: $v -- no collision"
    continue
  fi
  label="#$n"
  if [ "$draft" = "true" ]; then
    label="$label (draft)"
  fi
  title=$(printf '%.60s' "$title")
  if [ "$n" -lt "$pr" ]; then
    lower="${lower}PR ${label} already claims ${head_v}: ${title}"$'\n'
    if [ -z "$earliest" ] || [ "$n" -lt "$earliest" ]; then
      earliest="$n"
    fi
  else
    higher="${higher}PR ${label} also carries ${head_v}: ${title}"$'\n'
  fi
done <<< "$others"

if [ -n "$lower" ]; then
  echo "::error::VERSION COLLISION WITH AN OPEN PR -- this PR carries $head_v, and so does:"
  printf '%s' "$lower" | sed 's/^/::error::  /'
  echo "::error::"
  echo "::error::Both branches were cut from the same $base and each ran"
  echo "::error::'make bump-patch', so each computed the SAME next number. git"
  echo "::error::merges two identical VERSION lines as AGREEMENT rather than as a"
  echo "::error::conflict, so nothing would stop both landing -- and one of the two"
  echo "::error::versions would silently never exist."
  echo "::error::"
  echo "::error::PR #$earliest opened first, so it keeps $head_v and THIS PR re-bumps:"
  echo "::error::    git fetch origin $base && git merge origin/$base"
  echo "::error::    make bump-patch && git push"
  echo "::error::"
  echo "::error::Do NOT edit the version by hand, and do NOT simply re-run this job"
  echo "::error::-- the number stays taken until this branch moves."
  exit 1
fi

if [ -n "$higher" ]; then
  # Reported, not failed: this PR opened first, so it keeps the number
  # and the other one re-bumps. That PR's own run is where it is red.
  echo "::warning::Another open PR carries $head_v as well:"
  printf '%s' "$higher" | sed 's/^/::warning::  /'
  echo "::warning::This PR opened first, so it keeps $head_v and the other re-bumps."
  echo "::warning::Nothing to do here."
fi

echo "no earlier open PR claims $head_v"

