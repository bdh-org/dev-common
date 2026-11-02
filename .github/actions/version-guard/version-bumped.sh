#!/usr/bin/env bash
# The "Version bumped" gate. See action.yml for why this is a composite action
# called as a step rather than a sibling job, and tests/version-bumped.test.sh
# for the cases that run this file.
#
# A merge to main must be identifiable by version (bdh-org/dev-common#124).
# `make version-check` tests INTERNAL consistency -- Makefile VERSION against
# __init__.py / package.json / VERSION_TXT -- and has no notion of a base
# branch, so it passes happily on a PR that changed code and forgot to bump.
# finzeug/panoptikon#569 merged that way: VERSION stayed on a number #567 had
# already tagged, tag-version.yml (which then triggered only on Makefile
# changes) never fired, and the deployed image reported someone else's version.
#
# Skips a repo with no VERSION line, so this cannot break a repo that does not
# version this way. Allows a pure bump PR, which is the fix rather than a
# violation. Every path PRINTS what it concluded: a silent pass is
# indistinguishable from a check that never ran.
#
# Inputs, both from the environment: BASE_REF (the PR's base branch) and the
# working directory (the caller's checkout, at the PR head).

# `-euo pipefail` reproduces the shell Actions gave this body while it was a
# `run: |` block (`bash --noprofile --norc -eo pipefail`, plus the body's own
# `set -eu`). Spelled out here because `bash script.sh` does NOT inherit the
# calling shell's options, so dropping it would silently relax the gate.
set -euo pipefail

if ! grep -qE '^VERSION[[:space:]]*=' Makefile 2>/dev/null; then
  echo "no VERSION in Makefile -- this repo does not version here, skipping"
  exit 0
fi

# Empty on anything that is not a pull request. All three callers already guard
# the step with `if: github.event_name == 'pull_request'`, so reaching here with
# no base means a NEW caller wired it onto a push -- and `git fetch origin ""`
# would crash rather than judge. Say which it is instead (bdh-org/dev-common#235).
if [ -z "${BASE_REF:-}" ]; then
  echo "no BASE_REF -- this is not a pull request, so there is no base to"
  echo "compare against, skipping. Guard the step with:"
  echo "    if: github.event_name == 'pull_request'"
  exit 0
fi

base="origin/${BASE_REF}"
git fetch --quiet origin "${BASE_REF}"
head_v=$(grep -m1 -E '^VERSION[[:space:]]*=' Makefile | sed -E 's/^VERSION[[:space:]]*=[[:space:]]*//')
base_v=$(git show "$base:Makefile" 2>/dev/null | grep -m1 -E '^VERSION[[:space:]]*=' | sed -E 's/^VERSION[[:space:]]*=[[:space:]]*//' || echo "")
if [ -z "$base_v" ]; then
  echo "no VERSION on $base -- nothing to compare, skipping"
  exit 0
fi
if [ "$head_v" != "$base_v" ]; then
  # STRICTLY GREATER, not merely different (dev-common#180/#182).
  #
  # "Different" passes every branch in a parallel set: three panoptikon PRs
  # each branched from 2.12.105 and each bumped to 2.12.106, so each differed
  # from its base and each went green. The first merged and tagged 2.12.106;
  # the other two rode onto main under a version whose tag pointed two commits
  # behind them (finzeug/panoptikon#728/#729/#730).
  #
  # What `!=` alone lets through is a version that DECREASES -- which cannot be
  # tagged, and whose image tag collides with a build that has already shipped.
  if [ "$(printf '%s\n%s\n' "$base_v" "$head_v" | sort -V | tail -1)" = "$head_v" ]; then
    echo "version bumped: $base_v -> $head_v"
    exit 0
  fi
  echo "::error::VERSION went BACKWARDS: $base_v on ${BASE_REF}, $head_v here."
  echo "::error::Rebase and run 'make bump-patch' -- a version that decreases"
  echo "::error::cannot be tagged, and the image tag would collide with a build"
  echo "::error::that already shipped."
  exit 1
fi
changed=$(git diff --name-only "$base"...HEAD | grep -v '^Makefile$' || true)
if [ -z "$changed" ]; then
  echo "nothing changed but the Makefile -- nothing to version"
  exit 0
fi
# COLLISION, not a missing bump -- and they need opposite remedies, so they must
# not share a message. If this branch DID bump relative to the point it forked
# from, and the base has since reached that same version, then another PR merged
# the same number first. The author already ran `make bump-patch`; telling them
# to run it again is the one instruction that looks wrong and is right, so it
# has to say WHY.
#
# Two open PRs in one repo hit this by construction: each carries a bump
# computed when it was opened, and whichever merges first takes the number. A
# submodule-bump sweep that opens three PRs in a repo hits it twice.
# (bdh-org/dev-common#208, found merging seven bump PRs on 2026-08-16.)
#
# NOT fixed by comparing against the merge base instead: that would pass a stale
# bump and let two changes land on ONE version, which is the exact thing this
# check exists to prevent -- the deployed image would report a version belonging
# to another change.
mb="$(git merge-base "$base" HEAD 2>/dev/null || true)"
if [ -n "$mb" ]; then
  mb_v=$(git show "$mb:Makefile" 2>/dev/null | grep -m1 -E '^VERSION[[:space:]]*=' | sed -E 's/^VERSION[[:space:]]*=[[:space:]]*//' || echo "")
  if [ -n "$mb_v" ] && [ "$head_v" != "$mb_v" ]; then
    echo "::error::VERSION COLLISION -- this PR bumped $mb_v -> $head_v, but ${BASE_REF} has ALSO reached $head_v."
    echo "::error::Another PR merged that same version first. Your bump was fine; it is now taken."
    echo "::error::Re-bump on top of the updated base:"
    echo "::error::    git fetch origin ${BASE_REF} && git merge origin/${BASE_REF}"
    echo "::error::    make bump-patch && git push"
    echo "::error::Do NOT edit the version by hand, and do NOT re-run this job -- the"
    echo "::error::number is taken until the branch moves."
    exit 1
  fi
fi
echo "::error::VERSION is still $base_v but this PR changes:"
echo "$changed" | sed 's/^/  /'
echo "::error::Run 'make bump-patch' (or bump-minor, see P8) -- never edit the version by hand."
echo "::error::Without a bump, tag-version.yml fails on main with a VERSION"
echo "::error::COLLISION and the deployed image reports another change's version."
exit 1
