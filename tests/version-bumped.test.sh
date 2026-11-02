#!/usr/bin/env bash
# version-bumped.test.sh -- the "Version bumped" gate, which is now ONE file:
# .github/actions/version-guard/version-bumped.sh, a composite action called as
# a step by ci.yml, self-hosted-ci.yml and version-guard.yml
# (bdh-org/dev-common#124, #180, #182, #232, #235; bdh-org/home-infra#617).
#
# WHAT THIS FILE USED TO DO, AND WHY IT NO LONGER DOES IT. The step body was
# inline in all three workflows. This suite ran every case against all three
# copies and ended with a case asserting the three were BYTE-IDENTICAL, because
# a comment at the site had twice failed to keep them so: dev-common#182
# tightened ci.yml's comparison to strictly-greater and left self-hosted-ci.yml
# on the weaker test for ten days, while every repo in the stack called the
# weaker one; #208's VERSION COLLISION branch landed in self-hosted-ci.yml alone,
# so ci.yml told authors to run the `make bump-patch` they had just run (#232).
# Both times the behavioural cases stayed green, because they compared exit
# codes and the divergence was in a MESSAGE.
#
# The byte-identity case is GONE, and that is the point of #235 rather than a
# loss of coverage: with one implementation there is nothing left for it to
# compare, and a test asserting a tautology is worse than no test. What replaces
# it is structural -- every workflow CALLS the action, no workflow still carries
# the logic inline, and no workflow has grown a new JOB for it, because `ci / ci`
# is the required status check in nine consumer repos and a new context none of
# them requires would stop gating merges while still looking green.
#
# THE BEHAVIOUR THE GATE OWES. It used to ask whether VERSION *differed* from
# the base branch's. That passes every branch in a parallel set: on 2026-08-14
# three panoptikon PRs each branched from 2.12.105 and each ran `make bump-patch`
# to 2.12.106. All three differed from their base, all three went green, all
# three merged. The first took the 2.12.106 tag; the other two rode onto main
# under a version whose tag pointed two commits behind them, and
# `tag-version.yml` never fired again because VERSION had not changed. Nothing
# was red at any point.
#
# So the gate asks for STRICTLY GREATER. That catches the second and third PR --
# but only when their CI re-runs against the moved base, which is what "Require
# branches to be up to date before merging" enforces at the branch settings.
# That rollout is recorded in bdh-org/home-infra#414's comments and tracked for
# drift by #623. This file tests the half that lives in code; the other half is
# a repo setting and cannot be tested here.
#
# The cases run the REAL script -- not a re-implementation of its logic, which
# would pass while the action shipped something else.
#
# Usage:  bash tests/version-bumped.test.sh      (or: make test)

set -uo pipefail   # deliberately NOT -e: every case runs, then we report

HERE="$(cd "$(dirname "$0")" && pwd)"
ACTION_DIR="$HERE/../.github/actions/version-guard"
SCRIPT="$ACTION_DIR/version-bumped.sh"
ACTION_YML="$ACTION_DIR/action.yml"
# Every workflow that calls the action. A file that stops calling it fails the
# cases below rather than silently dropping out of coverage.
WORKFLOWS="ci.yml self-hosted-ci.yml version-guard.yml"
STEP_NAME="Version bumped"
# The only form that works from inside a `workflow_call`: a relative `uses: ./`
# resolves against the CALLING repo's checkout, where this action does not exist.
ACTION_REF="bdh-org/dev-common/.github/actions/version-guard@main"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass=0; fail=0
ok()    { echo "ok   - $CASE: $1"; pass=$((pass+1)); }
notok() { echo "NOT OK - $CASE: $1"; fail=$((fail+1)); }

export GIT_TERMINAL_PROMPT=0
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t

# ------------------------------------------------------------ the action is --
CASE="the action exists"
if [ -s "$SCRIPT" ] && [ -s "$ACTION_YML" ]; then
  ok "version-bumped.sh and action.yml are both present and non-empty"
else
  notok "no action at .github/actions/version-guard -- every case below is moot"
  echo; echo "passed: $pass   failed: $fail"; exit 1
fi

CASE="action.yml runs the script this file tests"
# Without this, action.yml could point at some other body and every behavioural
# case below would be green against a script nothing executes.
if grep -qF 'version-bumped.sh' "$ACTION_YML"; then
  ok "action.yml invokes version-bumped.sh"
else
  notok "action.yml does not mention version-bumped.sh -- the tested script is not the shipped one"
fi

CASE="every path action.yml runs exists in the action directory"
# NOTHING IN THIS REPO EXECUTES THE ACTION, so without this the first run of it
# is in nine consumer repos at once -- the same argument ci-build.test.sh makes
# about the reusable build leg. A mistyped path is not a silent failure (every
# caller's `ci / ci` would go red with "Can't find 'action.yml'"), but it would
# go red in the fleet rather than here, which is the part this closes.
missing_path=""
while IFS= read -r rel; do
  [ -n "$rel" ] || continue
  [ -f "$ACTION_DIR/$rel" ] || missing_path="$missing_path $rel"
done < <(grep -oE '\$\{\{ github\.action_path \}\}/[A-Za-z0-9._/-]+' "$ACTION_YML" \
         | sed 's#.*}}/##' | sort -u)
if [ -z "$missing_path" ]; then
  ok "action_path references all resolve to files that are here"
else
  notok "action.yml runs a path that does not exist:$missing_path"
fi

CASE="the script parses as bash"
if bash -n "$SCRIPT" 2>"$TMP/syn"; then
  ok "version-bumped.sh is syntactically valid"
else
  notok "the shipped script does not parse:"; sed 's/^/         /' "$TMP/syn"
fi

CASE="action.yml is a valid composite action"
# PyYAML is a BONUS, not the gate -- same reasoning as ci-build.test.sh: the
# properties below are also asserted textually, and a suite that goes red on
# whether the runner image ships a library is a suite that gets ignored. What
# only a parse can catch is the file being invalid YAML at all, which otherwise
# surfaces as every caller's job failing to start.
if python3 -c 'import yaml' 2>/dev/null; then
  if python3 -I -c '
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
assert d["runs"]["using"] == "composite", d["runs"]["using"]
steps = d["runs"]["steps"]
assert len(steps) == 1, f"{len(steps)} steps, expected 1"
assert steps[0]["shell"] == "bash", steps[0].get("shell")
assert "BASE_REF" in steps[0]["env"], list(steps[0]["env"])
assert d.get("description"), "no description"
' "$ACTION_YML" 2>"$TMP/yamlerr"; then
    ok "valid YAML, using: composite, one bash step taking BASE_REF"
  else
    notok "action.yml shape check failed:"; sed 's/^/         /' "$TMP/yamlerr"
  fi
else
  ok "valid-YAML parse not run (no PyYAML here); the textual checks still ran"
fi

CASE="the base branch reaches the script by env"
# The script reads \$BASE_REF rather than carrying `\${{ github.base_ref }}`
# inline. That is what lets this file run the shipped script verbatim instead of
# sed-substituting GitHub templating out of an extracted copy -- and an extracted
# copy is how the old suite could pass while the workflow shipped something else.
if grep -qE 'BASE_REF:[[:space:]]*\$\{\{[[:space:]]*github\.base_ref[[:space:]]*\}\}' "$ACTION_YML"; then
  ok "action.yml passes github.base_ref as BASE_REF"
else
  notok "action.yml does not set BASE_REF from github.base_ref -- the gate has no base to compare against"
fi
CASE="the script does not carry GitHub templating"
if grep -qF '${{' "$SCRIPT"; then
  notok "version-bumped.sh contains \${{ ... }} -- it is shell, and Actions does not expand a script file"
else
  ok "the script is plain shell, so what runs in CI is what runs here"
fi

# --------------------------------------------------- every workflow calls it --
# Every line of a named step, from its `- name:` to the next step or the end of
# the job's steps. Used to assert the step has NO inline body left.
#
# Deliberately NOT the old `run: |`-seeking extractor: with nothing to extract,
# that one keeps scanning and latches onto the NEXT step's body -- here the
# sibling "Version claimed by another open PR" -- so it reports a copy of the
# gate that is not there.
step_block() { # workflow-file step-name
  awk -v name="      - name: $2" '
    $0 == name        { instep = 1; next }
    instep && /^      - / { exit }   # the next step
    instep && /^[^ ]/     { exit }   # dedented out of the job entirely
    instep                { print }
  ' "$1"
}

# The top-level job keys of a workflow, one per line.
job_names() { # workflow-file
  awk '/^jobs:[[:space:]]*$/ {injobs=1; next}
       injobs && /^[^[:space:]#]/ {exit}
       injobs && /^  [A-Za-z0-9_-]+:[[:space:]]*$/ { sub(/:[[:space:]]*$/, ""); sub(/^  /, ""); print }
      ' "$1"
}

for WF_NAME in $WORKFLOWS; do
  WF="$HERE/../.github/workflows/$WF_NAME"
  if [ ! -f "$WF" ]; then
    CASE="[$WF_NAME] the workflow exists"
    notok "no such workflow -- WORKFLOWS names a file that is not here"
    continue
  fi

  CASE="[$WF_NAME] calls the shared action"
  if grep -qF "uses: $ACTION_REF" "$WF"; then
    ok "uses $ACTION_REF"
  else
    notok "$WF_NAME does not call the action -- it has either been unwired or gone back to a copy"
  fi

  CASE="[$WF_NAME] the call is the '$STEP_NAME' step"
  # The step NAME is what the log and the suite both key on, and a renamed step
  # is how the gate could disappear from a file that still calls the action for
  # something else.
  if awk -v name="      - name: $STEP_NAME" -v ref="        uses: $ACTION_REF" '
        $0 == name { found = 1; next }
        found && $0 ~ /^        (if|with|env):/ { next }
        found && $0 == ref { hit = 1; exit }
        found { exit }
        END { exit(hit ? 0 : 1) }' "$WF"; then
    ok "the step named '$STEP_NAME' is the one that calls the action"
  else
    notok "no '$STEP_NAME' step calling the action in $WF_NAME"
  fi

  CASE="[$WF_NAME] carries no inline copy of the gate"
  if step_block "$WF" "$STEP_NAME" | grep -qE '^        run:'; then
    notok "the '$STEP_NAME' step still has a run: body -- the duplication #235 removed is back"
  else
    ok "no inline run: body under '$STEP_NAME'"
  fi

  CASE="[$WF_NAME] the gate's logic is nowhere else in the file"
  # Catches the body pasted back under a DIFFERENT step name, which the case
  # above cannot see. Keyed on message text the gate owns outright.
  stray="$(grep -nF 'VERSION went BACKWARDS' "$WF" || true)"
  if [ -n "$stray" ]; then
    notok "the gate's own error text appears in $WF_NAME: $stray"
  else
    ok "no copy of the gate's messages in the workflow"
  fi
done

CASE="[ci.yml, self-hosted-ci.yml] the guard did not become a new job"
# THE REQUIRED-CONTEXT INVARIANT, and the reason #235 shipped a composite action
# called as a step rather than the sibling job its body proposed. canary,
# devtemplate, ferret, freddyb, heller, hog, oleo, panoptikon and slingshot all
# require the status check `ci / ci`. A second job in either reusable reports
# under a context none of them requires: the guard would stop gating merges
# while still showing green, and fixing it needs a branch-protection write in
# nine repos that no session credential holds. Adding the job here is therefore
# a silent fleet-wide regression, which is exactly the kind a test must own.
extra=""
for WF_NAME in ci.yml self-hosted-ci.yml; do
  names="$(job_names "$HERE/../.github/workflows/$WF_NAME" | tr '\n' ' ')"
  case "$(echo "$names" | tr -s ' ')" in
    "ci ") ;;
    *) extra="$extra $WF_NAME:[${names% }]" ;;
  esac
done
if [ -z "$extra" ]; then
  ok "both reusables still define exactly one job, 'ci', so 'ci / ci' is unchanged"
else
  notok "a job was added or renamed, so the required context moved:$extra"
fi

# ---------------------------------------------------------------- behaviour --
# A repo with `main` at $1, a branch at $2, and (optionally) a code change.
# Origin is a local clone of itself, because the script does `git fetch origin`.
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

run_step() { ( cd "$1" && BASE_REF="${BASE_REF_OVERRIDE-main}" bash "$SCRIPT" 2>&1 ); }

CASE="a real bump"
d=$(make_repo 2.12.105 2.12.106 src.py)
if out=$(run_step "$d"); then ok "2.12.105 -> 2.12.106 with a code change passes"
else notok "a genuine bump was rejected: $out"; fi

CASE="the collision that shipped"
# The exact #728/#729/#730 shape: base has MOVED to the version this PR chose.
d=$(make_repo 2.12.106 2.12.106 src.py)
if out=$(run_step "$d"); then notok "base 2.12.106 == head 2.12.106 with a code change PASSED -- #180 is not fixed"
else ok "a PR whose version equals the base's is rejected"; fi

CASE="a collision is NAMED a collision"
# dev-common#232. Every copy rejected this input, so an exit-code-only assertion
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

CASE="the colliding branch MERGES CLEANLY, and is still rejected"
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

CASE="a version that goes backwards"
d=$(make_repo 2.12.110 2.12.109 src.py)
if out=$(run_step "$d"); then notok "2.12.110 -> 2.12.109 passed"
else
  case "$out" in *BACKWARDS*) ok "a decreasing version is rejected, and says so" ;;
                 *) notok "rejected, but not for the stated reason: $out" ;; esac
fi

CASE="numeric ordering, not lexical"
# sort -V, not sort: lexically "2.12.9" > "2.12.10", which would reject a real bump.
d=$(make_repo 2.12.9 2.12.10 src.py)
if out=$(run_step "$d"); then ok "2.12.9 -> 2.12.10 passes (version sort, not string sort)"
else notok "a real bump was rejected by lexical comparison: $out"; fi

CASE="a pure bump PR"
d=$(make_repo 2.12.105 2.12.106)   # no other file touched
if out=$(run_step "$d"); then ok "a bump-only PR passes"
else notok "the fix for a missed bump was itself rejected: $out"; fi

CASE="nothing to version"
d=$(make_repo 2.12.105 2.12.105)   # unchanged version, nothing else changed
if out=$(run_step "$d"); then ok "an unchanged version with no other change passes"
else notok "a no-op PR was rejected: $out"; fi

CASE="a repo that does not version here"
d="$TMP/noversion"; mkdir -p "$d"; cd "$d" || exit 1
git init -q -b main .; echo hi > README.md; git add README.md; git commit -qm base
git clone -q --bare . "$d/origin.git"; git remote add origin "$d/origin.git"; git fetch -q origin
git checkout -qb pr; echo more >> README.md; git commit -qam pr
if out=$(run_step "$d"); then
  case "$out" in
    *"no VERSION in Makefile"*) ok "a repo with no VERSION line is skipped, and says why" ;;
    *) notok "passed silently instead of announcing the skip: $out" ;;
  esac
else notok "a repo that does not version this way was failed: $out"; fi

CASE="no base ref at all"
# Reachable only from a caller that wired the action onto a push, since all three
# workflows guard the step with `if: github.event_name == 'pull_request'`. The
# old inline body would have run `git fetch origin ""` and ERRORED -- and an
# erroring guard is worse than no guard, because it still shows a red X that
# looks like coverage (bdh-org/dev-common#235).
d=$(make_repo 2.12.105 2.12.105)
if out=$(BASE_REF_OVERRIDE="" run_step "$d"); then
  case "$out" in
    *"not a pull request"*) ok "skipped, naming the 'if:' guard the caller is missing" ;;
    *) notok "passed without saying why there was nothing to compare: $out" ;;
  esac
else notok "an empty BASE_REF failed the build instead of skipping: $out"; fi

echo
echo "passed: $pass   failed: $fail"
[ "$fail" -eq 0 ]
