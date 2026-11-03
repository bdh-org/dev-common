#!/usr/bin/env bash
# rebump-prs.test.sh -- .github/actions/rebump-prs (bdh-org/dev-common#344).
#
# Runs the REAL script against a fixture repo with a bare "origin" holding
# refs/pull/N/head, and `gh` stubbed on PATH to list those PRs. The cases are the
# ones a merge queue actually produces (the 2026-11-03 panoptikon run):
#   - a PR left in a version-line conflict by a merge
#   - a PR at the SAME number as main, which merges cleanly as agreement --
#     the case a conflict-triggered design would miss
#   - two PRs landing on one provisional number, which is allowed
#   - a PR already above main, a PR with a real conflict, a draft, an unapproved PR
#
# Usage:  bash tests/rebump-prs.test.sh      (or: make test)

set -uo pipefail   # deliberately NOT -e: every case runs, then we report

HERE="$(cd "$(dirname "$0")" && pwd)"
ACTION_DIR="$HERE/../.github/actions/rebump-prs"
SCRIPT="$ACTION_DIR/rebump-prs.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass=0; fail=0
ok()    { echo "ok   - $CASE: $1"; pass=$((pass+1)); }
notok() { echo "NOT OK - $CASE: $1"; fail=$((fail+1)); }

CASE="the action runs the script this file tests"
if grep -qF 'rebump-prs.sh' "$ACTION_DIR/action.yml" && bash -n "$SCRIPT"; then
  ok "action.yml invokes rebump-prs.sh, and it parses"
else
  notok "action.yml does not run rebump-prs.sh, or the script does not parse"
fi

CASE="the action is report-only"
if grep -qE '^[[:space:]]*MODE:[[:space:]]*report[[:space:]]*$' "$ACTION_DIR/action.yml"; then
  ok "action.yml sets MODE: report"
else
  notok "action.yml does not pin MODE: report -- stage 1 must push nothing"
fi

# ---------------------------------------------------------------- fixture --
G() { git -C "$TMP/work" -c user.name=t -c user.email=t@t -c commit.gpgsign=false "$@"; }
git init -q --bare "$TMP/origin.git"
git init -q -b main "$TMP/work"
G remote add origin "$TMP/origin.git"
set_version() {  # set_version <v> -- Makefile plus a Python __version__
  printf 'VERSION=%s\nPACKAGE_DIR=pkg\n' "$1" >"$TMP/work/Makefile"
  mkdir -p "$TMP/work/pkg"; printf '__version__ = "%s"\n' "$1" >"$TMP/work/pkg/__init__.py"
}
set_version 1.2.0; echo base >"$TMP/work/shared.txt"
G add -A; G commit -qm base; G push -q origin main
base="$(G rev-parse HEAD)"

pr() {  # pr <n> <version> [file content] -- branch off base, push as refs/pull/<n>/head
  G checkout -q -B "pr$1" "$base"; set_version "$2"
  [ $# -ge 3 ] && echo "$3" >"$TMP/work/$4"
  echo "$1" >"$TMP/work/own-$1.txt"
  G add -A; G commit -qm "pr $1"; G push -q origin "HEAD:refs/pull/$1/head"
}
pr 1 1.2.1                      # patch, conflicts on version lines once main moves
pr 2 1.3.0                      # minor, same number main will hold: merges as AGREEMENT
pr 3 1.2.1                      # patch, same provisional number as #1 -- allowed
pr 4 1.4.0                      # already above main
pr 5 1.2.1 "theirs" shared.txt  # real conflict outside version lines
pr 6 1.2.1                      # draft
pr 7 1.2.1                      # not approved, no auto-merge

# main moves: a minor merge to 1.3.0 that also edits shared.txt
G checkout -q main; set_version 1.3.0; echo "ours" >"$TMP/work/shared.txt"
G add -A; G commit -qm "feat merged"; G push -q origin main

mkdir -p "$TMP/bin"
cat >"$TMP/bin/gh" <<'STUB'
#!/usr/bin/env bash
cat <<'JSON'
[
 {"number":1,"isDraft":false,"isCrossRepository":false,"reviewDecision":"APPROVED","autoMergeRequest":null},
 {"number":2,"isDraft":false,"isCrossRepository":false,"reviewDecision":"","autoMergeRequest":{"mergeMethod":"SQUASH"}},
 {"number":3,"isDraft":false,"isCrossRepository":false,"reviewDecision":"APPROVED","autoMergeRequest":null},
 {"number":4,"isDraft":false,"isCrossRepository":false,"reviewDecision":"APPROVED","autoMergeRequest":null},
 {"number":5,"isDraft":false,"isCrossRepository":false,"reviewDecision":"APPROVED","autoMergeRequest":null},
 {"number":6,"isDraft":true,"isCrossRepository":false,"reviewDecision":"","autoMergeRequest":null},
 {"number":7,"isDraft":false,"isCrossRepository":false,"reviewDecision":"REVIEW_REQUIRED","autoMergeRequest":null}
]
JSON
STUB
chmod +x "$TMP/bin/gh"

out="$(cd "$TMP/work" && PATH="$TMP/bin:$PATH" REPO=o/r GITHUB_STEP_SUMMARY="$TMP/summary.md" \
  bash "$SCRIPT" 2>&1)"; rc=$?

CASE="the run succeeds"
if [ "$rc" -eq 0 ]; then ok "exit 0"; else notok "exit $rc:"; sed 's/^/         /' <<<"$out"; fi

expect() {  # expect <case> <line the output must contain>
  CASE="$1"
  if grep -qF -- "$2" <<<"$out"; then ok "$2"; else notok "missing '$2' in:"; sed 's/^/         /' <<<"$out"; fi
}
expect "a version-line conflict is re-bumped past main at the PR's own level" \
  "#1 1.2.1: WOULD RE-BUMP to 1.3.1 (patch)"
expect "a PR at main's number is caught though git sees no conflict" \
  "#2 1.3.0: WOULD RE-BUMP to 1.4.0 (minor)"
expect "two PRs may share one provisional number" \
  "#3 1.2.1: WOULD RE-BUMP to 1.3.1 (patch)"
expect "a PR already above main is left as it is" \
  "#4 1.4.0: ok: above main"
expect "a conflict outside version lines is left alone, naming the file" \
  "#5 1.2.1: left alone: conflicts outside version lines in shared.txt"
expect "a draft is skipped" \
  "#6 ?: skipped: draft"
expect "an unready PR is reported but not marked for re-bump" \
  "#7 1.2.1: would re-bump to 1.3.1 (patch) once approved or set to auto-merge"

CASE="the job summary carries the table"
if grep -qF '| #1 | 1.2.1 | WOULD RE-BUMP to 1.3.1 (patch) |' "$TMP/summary.md"; then
  ok "summary has a row per PR"
else
  notok "summary.md lacks the #1 row"
fi

CASE="report mode pushes nothing"
if [ "$(git -C "$TMP/origin.git" for-each-ref --format='%(objectname)' refs/pull/1/head)" = \
     "$(G rev-parse pr1)" ]; then
  ok "refs/pull/1/head is untouched"
else
  notok "the PR head moved in report mode"
fi

CASE="any other MODE is refused"
if (cd "$TMP/work" && PATH="$TMP/bin:$PATH" REPO=o/r MODE=push bash "$SCRIPT" >/dev/null 2>&1); then
  notok "MODE=push ran -- it is not built yet and must refuse"
else
  ok "MODE=push exits non-zero"
fi

echo
echo "passed: $pass   failed: $fail"
[ "$fail" -eq 0 ]
