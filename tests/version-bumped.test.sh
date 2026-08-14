#!/usr/bin/env bash
# version-bumped.test.sh -- the "Version bumped" gate embedded in
# .github/workflows/ci.yml (bdh-org/dev-common#124, #180).
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
# settings (bdh-org/home-infra#414). This file tests the half that lives in
# code; the other half is a repo setting and cannot be tested here.
#
# The cases run the REAL step body, extracted from the workflow, against
# throwaway git repos -- not a re-implementation of its logic, which would pass
# while the workflow shipped something else.
#
# Usage:  bash tests/version-bumped.test.sh      (or: make test)

set -uo pipefail   # deliberately NOT -e: every case runs, then we report

HERE="$(cd "$(dirname "$0")" && pwd)"
WF="$HERE/../.github/workflows/ci.yml"
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

SCRIPT="$TMP/version-bumped.sh"
extract "$WF" "$STEP_NAME" > "$SCRIPT"

# `${{ github.base_ref }}` is GitHub's templating, not shell. Substitute the
# branch name the way Actions would before running the body.
sed -i 's/\${{ github\.base_ref }}/main/g' "$SCRIPT"

CASE="the step is extractable"
if [ -s "$SCRIPT" ]; then ok "ci.yml carries a '$STEP_NAME' step with a body"
else notok "ci.yml has no '$STEP_NAME' step -- renamed or removed"; fi

# A repo with `main` at $1, a branch at $2, and (optionally) a code change.
# Origin is a local clone of itself, because the step does `git fetch origin`.
make_repo() { # base_version head_version [extra_file]
  local base="$1" head="$2" extra="${3:-}" d="$TMP/repo-$RANDOM"
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

run_step() { ( cd "$1" && bash "$SCRIPT" 2>&1 ); }

CASE="a real bump"
d=$(make_repo 2.12.105 2.12.106 src.py)
if out=$(run_step "$d"); then ok "2.12.105 -> 2.12.106 with a code change passes"
else notok "a genuine bump was rejected: $out"; fi

CASE="the collision that shipped"
# The exact #728/#729/#730 shape: base has MOVED to the version this PR chose.
d=$(make_repo 2.12.106 2.12.106 src.py)
if out=$(run_step "$d"); then notok "base 2.12.106 == head 2.12.106 with a code change PASSED -- #180 is not fixed"
else ok "a PR whose version equals the base's is rejected"; fi

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
if out=$(run_step "$d"); then ok "a repo with no VERSION line is skipped, not failed"
else notok "a repo that does not version this way was failed: $out"; fi

echo
echo "passed: $pass   failed: $fail"
[ "$fail" -eq 0 ]
