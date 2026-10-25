#!/usr/bin/env bash
# version-bumped.test.sh -- the "Version bumped" gate, in BOTH workflows that
# embed it: .github/workflows/ci.yml AND .github/workflows/self-hosted-ci.yml
# (bdh-org/dev-common#124, #180, #182; bdh-org/home-infra#617).
#
# IT RUNS EVERY CASE AGAINST BOTH FILES, and that is the whole point of the
# rewrite. This file used to hardcode ci.yml. #182 then tightened the comparison
# from "differs" to "strictly greater" in ci.yml ONLY, and this suite went green
# for ten days while every repo in the stack -- all of which call
# self-hosted-ci.yml@main -- ran the weaker test. The fix looked shipped and had
# reached nothing.
#
# The gate's own comment in self-hosted-ci.yml already said "It has to be in
# BOTH", citing an earlier incident that made the same argument. So the class had
# been learned, written down at the exact site, and repeated anyway six weeks
# later. A comment cannot enforce agreement between two files; a test can, and
# refusing to hardcode one of the two is the enforcement.
#
# The gate used to ask whether VERSION *differed* from the base branch's. That
# passes every branch in a parallel set: on 2026-08-14 three panoptikon PRs each
# branched from 2.12.105 and each ran `make bump-patch` to 2.12.106. All three
# differed from their base, all three went green, all three merged. The first
# took the 2.12.106 tag; the other two rode onto main under a version whose tag
# pointed two commits behind them, and `tag-version.yml` never fired again
# because VERSION had not changed. Nothing was red at any point.
#
# So the gate now asks for STRICTLY GREATER. That catches the second and third
# PR -- but only when their CI re-runs against the moved base, which is what
# "Require branches to be up to date before merging" enforces at the branch
# settings. That rollout is recorded in bdh-org/home-infra#414's comments and
# tracked for drift by #623. This file tests the half that lives in code; the
# other half is a repo setting and cannot be tested here -- and, since the
# branch-protection API 403s for the bdh-ai account, cannot currently be
# OBSERVED from here either, which is #623's problem rather than this file's.
#
# The cases run the REAL step body, extracted from the workflow, against
# throwaway git repos -- not a re-implementation of its logic, which would pass
# while the workflow shipped something else.
#
# Usage:  bash tests/version-bumped.test.sh      (or: make test)

set -uo pipefail   # deliberately NOT -e: every case runs, then we report

HERE="$(cd "$(dirname "$0")" && pwd)"
# Every workflow that embeds the gate. Adding a third is one line here, and a
# file that stops carrying the step fails the "extractable" case rather than
# silently dropping out of coverage.
WORKFLOWS="ci.yml self-hosted-ci.yml version-guard.yml"
STEP_NAME="Version bumped"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass=0; fail=0
ok()    { echo "ok   - $CASE: $1"; pass=$((pass+1)); }
notok() { echo "NOT OK - $CASE: $1"; fail=$((fail+1)); }

export GIT_TERMINAL_PROMPT=0
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t

# The named step's `run: |` body, dedented out of the workflow. Same idiom as
# ci-submodules.test.sh; a renamed step makes this empty and the first case red.
extract() { # workflow-file step-name
  awk -v name="      - name: $2" '
    $0 == name          { instep = 1; next }
    instep && /^        run: \|$/ { inbody = 1; instep = 0; next }
    inbody {
      if ($0 == "") { print ""; next }
      if ($0 !~ /^          /) { exit }
      print substr($0, 11)
    }
  ' "$1"
}

for WF_NAME in $WORKFLOWS; do
  WF="$HERE/../.github/workflows/$WF_NAME"
  if [ ! -f "$WF" ]; then
    CASE="[$WF_NAME] the workflow exists"
    notok "no such workflow -- WORKFLOWS names a file that is not here"
    continue
  fi

  SCRIPT="$TMP/version-bumped-$WF_NAME.sh"
  extract "$WF" "$STEP_NAME" > "$SCRIPT"

  # `${{ github.base_ref }}` is GitHub's templating, not shell. Substitute the
  # branch name the way Actions would before running the body.
  sed -i 's/\${{ github\.base_ref }}/main/g' "$SCRIPT"

  CASE="[$WF_NAME] the step is extractable"
  if [ -s "$SCRIPT" ]; then ok "$WF_NAME carries a '$STEP_NAME' step with a body"
  else notok "$WF_NAME has no '$STEP_NAME' step -- renamed or removed"; fi

  # A repo with `main` at $1, a branch at $2, and (optionally) a code change.
  # Origin is a local clone of itself, because the step does `git fetch origin`.
  make_repo() { # base_version head_version [extra_file]
    local base="$1" head="$2" extra="${3:-}" d="$(mktemp -d "$TMP/repo-XXXXXX")"
    mkdir -p "$d" && cd "$d" || return 1
    git init -q -b main .
    printf 'VERSION=%s\n' "$base" > Makefile
    git add Makefile && git commit -qm base
    git clone -q --bare . "$d/origin.git" && git remote add origin "$d/origin.git"
    git fetch -q origin
    git checkout -qb pr
    [ -n "$extra" ] && { echo change > "$extra"; git add "$extra"; }
    printf 'VERSION=%s\n' "$head" > Makefile
    git add Makefile
    # --allow-empty: the "nothing changed at all" case has nothing to commit, and
    # git's complaint would otherwise land on stdout and corrupt the path below.
    git commit -qm pr --allow-empty >/dev/null 2>&1
    echo "$d"
  }

  # The dev-common#208 shape, which make_repo CANNOT build: the branch really did
  # bump (fork -> taken) and the base has SINCE reached that same number. Only
  # then does the merge base's version differ from HEAD's, and that difference is
  # the only thing separating a collision from a missing bump.
  #
  # make_repo's "collision" case sets base == head == merge base, so it never
  # reaches the collision branch at all -- which is how dev-common#232 hid.
  make_collision_repo() { # fork_version taken_version
    local fork="$1" taken="$2" d="$(mktemp -d "$TMP/collide-XXXXXX")"
    mkdir -p "$d" && cd "$d" || return 1
    git init -q -b main .
    printf 'VERSION=%s\n' "$fork" > Makefile
    git add Makefile && git commit -qm base
    git clone -q --bare . "$d/origin.git" && git remote add origin "$d/origin.git"
    git checkout -qb pr
    echo change > src.py && git add src.py
    printf 'VERSION=%s\n' "$taken" > Makefile && git add Makefile
    git commit -qm "pr bumps $fork -> $taken"
    git checkout -q main
    printf 'VERSION=%s\n' "$taken" > Makefile
    git commit -qam "another PR took $taken first"
    git push -q origin main
    git checkout -q pr
    git fetch -q origin
    echo "$d"
  }

  run_step() { ( cd "$1" && bash "$SCRIPT" 2>&1 ); }

  CASE="[$WF_NAME] a real bump"
  d=$(make_repo 2.12.105 2.12.106 src.py)
  if out=$(run_step "$d"); then ok "2.12.105 -> 2.12.106 with a code change passes"
  else notok "a genuine bump was rejected: $out"; fi

  CASE="[$WF_NAME] the collision that shipped"
  # The exact #728/#729/#730 shape: base has MOVED to the version this PR chose.
  d=$(make_repo 2.12.106 2.12.106 src.py)
  if out=$(run_step "$d"); then notok "base 2.12.106 == head 2.12.106 with a code change PASSED -- #180 is not fixed"
  else ok "a PR whose version equals the base's is rejected"; fi

  CASE="[$WF_NAME] a collision is NAMED a collision"
  # dev-common#232. Both files reject this input, so an exit-code-only assertion
  # went green while ci.yml told the author to run `make bump-patch` -- the command
  # they had ALREADY run, which is the one instruction that looks wrong and is
  # right. The message is the deliverable here, so the message is what is asserted.
  d=$(make_collision_repo 2.12.105 2.12.106)
  if out=$(run_step "$d"); then
    notok "a version the base has already taken PASSED"
  else
    case "$out" in
      *"VERSION COLLISION"*) ok "a taken version is named a collision and carries the re-bump recipe" ;;
      *) notok "rejected with the missing-bump message: the author is told to re-run the bump they already ran -- $out" ;;
    esac
  fi

  CASE="[$WF_NAME] the colliding branch MERGES CLEANLY, and is still rejected"
  # The case a conflict-based heuristic cannot catch, and the reason this gate
  # has to ask "is VERSION strictly greater than base RIGHT NOW" rather than
  # "did this branch need a rebase".
  #
  # Both sides make the IDENTICAL edit to the Makefile -- 2.12.105 -> 2.12.106 --
  # and git merges an identical change as AGREEMENT, not as a conflict. So the PR
  # goes on reporting mergeable/CLEAN while its version is stale, and anything
  # keying on conflict leaves it alone.
  #
  # Live example, 2026-09-03: four heller PRs each bumped 1.3.221 -> 1.3.222.
  # Three of them touch overlapping sections and conflict with each other after
  # the first merge, so they announce themselves. The fourth (finzeug/heller#488)
  # touches a different section and conflicts with NOTHING in either direction --
  # it stays textually clean while its version goes stale. The well-separated PR
  # is the dangerous one, precisely because it is tidy.
  d=$(make_collision_repo 2.12.105 2.12.106)
  if ( cd "$d" && git merge --no-commit --no-ff origin/main >/dev/null 2>&1 ); then
    ( cd "$d" && git merge --abort >/dev/null 2>&1 || true )
    if out=$(run_step "$d"); then
      notok "the fixture merges cleanly AND passed the gate -- a clean merge is being read as a correct version"
    else
      ok "a branch that merges cleanly is still rejected when its version is taken"
    fi
  else
    ( cd "$d" && git merge --abort >/dev/null 2>&1 || true )
    notok "the fixture CONFLICTS, so it no longer covers the clean-merge case -- the identical-bump-as-agreement property has been lost"
  fi

  CASE="[$WF_NAME] a version that goes backwards"
  d=$(make_repo 2.12.110 2.12.109 src.py)
  if out=$(run_step "$d"); then notok "2.12.110 -> 2.12.109 passed"
  else
    case "$out" in *BACKWARDS*) ok "a decreasing version is rejected, and says so" ;;
                   *) notok "rejected, but not for the stated reason: $out" ;; esac
  fi

  CASE="[$WF_NAME] numeric ordering, not lexical"
  # sort -V, not sort: lexically "2.12.9" > "2.12.10", which would reject a real bump.
  d=$(make_repo 2.12.9 2.12.10 src.py)
  if out=$(run_step "$d"); then ok "2.12.9 -> 2.12.10 passes (version sort, not string sort)"
  else notok "a real bump was rejected by lexical comparison: $out"; fi

  CASE="[$WF_NAME] a pure bump PR"
  d=$(make_repo 2.12.105 2.12.106)   # no other file touched
  if out=$(run_step "$d"); then ok "a bump-only PR passes"
  else notok "the fix for a missed bump was itself rejected: $out"; fi

  CASE="[$WF_NAME] nothing to version"
  d=$(make_repo 2.12.105 2.12.105)   # unchanged version, nothing else changed
  if out=$(run_step "$d"); then ok "an unchanged version with no other change passes"
  else notok "a no-op PR was rejected: $out"; fi

  CASE="[$WF_NAME] a repo that does not version here"
  # Per-workflow dir: a fixed path collides on the second loop iteration, and
  # the collided case still reports ok -- git's errors go to stderr and the step
  # skips a repo with no VERSION either way. It passed for the wrong reason.
  d="$TMP/noversion-$WF_NAME"; mkdir -p "$d"; cd "$d" || exit 1
  git init -q -b main .; echo hi > README.md; git add README.md; git commit -qm base
  git clone -q --bare . "$d/origin.git"; git remote add origin "$d/origin.git"; git fetch -q origin
  git checkout -qb pr; echo more >> README.md; git commit -qam pr
  if out=$(run_step "$d"); then ok "a repo with no VERSION line is skipped, not failed"
  else notok "a repo that does not version this way was failed: $out"; fi

done

# The cheapest of these checks and the strongest. Every case above asks each copy
# to BEHAVE; this asks them to be ONE THING. The two inline copies drifted twice
# under a comment telling them not to -- dev-common#182 tightened one and not the
# other, then #208's collision message landed in self-hosted-ci.yml alone
# (dev-common#232) -- and both times the behavioural cases stayed green, because
# they compared exit codes and the divergence was in a MESSAGE.
#
# A comment cannot make two files agree. This can.
CASE="[all] every copy of the step is byte-identical"
ref=""; ref_name=""; identical=1
for WF_NAME in $WORKFLOWS; do
  body="$(extract "$HERE/../.github/workflows/$WF_NAME" "$STEP_NAME")"
  if [ -z "$ref_name" ]; then ref="$body"; ref_name="$WF_NAME"; continue; fi
  if [ "$body" != "$ref" ]; then
    identical=0
    echo "--- $ref_name vs $WF_NAME ---"
    diff <(printf '%s\n' "$ref") <(printf '%s\n' "$body") || true
  fi
done
if [ "$identical" -eq 1 ]; then
  ok "all $(set -- $WORKFLOWS; echo $#) copies carry the same body"
else
  notok "the copies have drifted -- see the diff above"
fi

echo
echo "passed: $pass   failed: $fail"
[ "$fail" -eq 0 ]
