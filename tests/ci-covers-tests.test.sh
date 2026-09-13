#!/usr/bin/env bash
# ci-covers-tests.test.sh -- assert that every test in tests/ actually runs in a
# job (bdh-org/dev-common#247). Ported from bdh-org/home-infra's
# tests/test-ci-covers-tests.sh, which exists for the same reason
# (bdh-org/home-infra#764).
#
# The gap it closes: `make test` GLOBS tests/*.test.sh, while
# .github/workflows/shell-tests.yml lists each suite BY NAME. Add a test and
# `make test` picks it up instantly -- so it passes locally, looks wired, and
# gates nothing. The local command a developer uses is precisely the one that
# hides the omission.
#
# It is not hypothetical: three of this repo's ten suites were in that state
# when #247 was filed (claude-install-lock, claude-host-shim, path-dedup). All
# three passed. None was enforcing anything.
#
# Why a separate guard rather than something inside `make test`: what is being
# detected is an ABSENCE, and an absence is exactly what a per-test check cannot
# see -- a test that runs nowhere reports nothing, which is indistinguishable
# from a test that does not exist. Same reasoning as the fleet audits: check
# against an expected list, not against whatever the directory happens to hold.
#
# Usage:  bash tests/ci-covers-tests.test.sh      (or: make test)

set -uo pipefail   # deliberately NOT -e: every case runs, then we report

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TESTS_DIR="$REPO_ROOT/tests"
WORKFLOW_DIR="$REPO_ROOT/.github/workflows"

# --- exemptions ------------------------------------------------------------
#
# "<path relative to repo root>|<reason>". A script listed here is allowed to
# run in no workflow -- for a shared helper, a fixture, or a suite that is
# genuinely too slow or too privileged for CI. The reason is mandatory and is
# the whole point: an unexplained exemption is the same silence this guard
# exists to break, just written down.
#
# Empty today. Adding an entry is a deliberate, reviewable line in a diff.
EXEMPT=(
  # "tests/example-helper.sh|sourced by the suites; not a suite itself"
)

pass=0
fail=0
CASE="(none)"

# --- harness ---------------------------------------------------------------

ok()   { pass=$((pass + 1)); printf 'ok     - %s: %s\n' "$CASE" "$1"; }
notok() {
  fail=$((fail + 1))
  printf 'NOT OK - %s: %s\n' "$CASE" "$1"
  [ -n "${2:-}" ] && printf '         got: %s\n' "$2"
  return 0
}

exempt_reason() {
  local want="$1" entry
  for entry in ${EXEMPT[@]+"${EXEMPT[@]}"}; do
    [ "${entry%%|*}" = "$want" ] && { printf '%s' "${entry#*|}"; return 0; }
  done
  return 1
}

# Every workflow line that is NOT a whole-line comment.
#
# Stripping comments matters, and stripping only WHOLE-line ones is the point:
# several workflows carry a shell comment naming the suite that covers them
# (e.g. "# tests/hydrate-submodules.test.sh sources everything above"), and
# counting a mention as coverage would let a suite look wired while running
# nowhere -- reintroducing the exact bug. Inline trailing comments are left
# alone; treating "#" anywhere as a comment would mangle real YAML strings.
#
# Every consumer below reads it with a here-string, never `printf ... | grep`.
# Under `set -o pipefail` a `grep -q` exits on its first match, printf dies of
# SIGPIPE, and the PIPELINE reports 141 -- so a successful match reads as a
# miss. That is not theoretical: the first run of this file reported all twelve
# suites uncovered while the very next section, which pipes the same $CODE into
# a grep WITHOUT -q, listed all twelve as present.
workflow_code() {
  grep -hv '^[[:space:]]*#' "$WORKFLOW_DIR"/*.yml
}

CODE="$(workflow_code)"

# --- every test on disk runs somewhere -------------------------------------

CASE="every tests/*.sh is invoked by a workflow"
# Globbing *.sh rather than *.test.sh on purpose: a suite misnamed
# tests/foo.sh runs in no workflow AND is invisible to `make test`, which is
# strictly worse than the bug this guard is named for. The wider glob is what
# makes that case visible.
found=0
for path in "$TESTS_DIR"/*.sh; do
  [ -e "$path" ] || continue
  found=$((found + 1))
  rel="tests/$(basename "$path")"
  if grep -qF "$rel" <<<"$CODE"; then
    ok "$rel is invoked"
  elif reason="$(exempt_reason "$rel")"; then
    if [ -n "$reason" ]; then
      ok "$rel is exempt ($reason)"
    else
      notok "$rel is exempt but gives no reason"
    fi
  else
    extra=""
    case "$rel" in
      *.test.sh) ;;
      *) extra=" -- and, not matching tests/*.test.sh, it is invisible to \`make test\` too" ;;
    esac
    notok "$rel runs in NO job$extra" \
      "add a step to .github/workflows/shell-tests.yml, or an entry with a reason to EXEMPT in $(basename "${BASH_SOURCE[0]}")"
  fi
done
if [ "$found" -gt 0 ]; then
  ok "$found script(s) checked"
else
  notok "tests/ matched no *.sh at all -- the glob or the path is wrong"
fi

# --- no workflow calls a test that is gone ---------------------------------

CASE="no workflow invokes a deleted test"
# The other direction. Deleting or renaming a suite leaves shell-tests.yml
# pointing at nothing, and `bash tests/gone.test.sh` fails the whole job with a
# "No such file or directory" that reads like an infrastructure fault.
missing=0
while IFS= read -r ref; do
  [ -n "$ref" ] || continue
  if [ -e "$REPO_ROOT/$ref" ]; then
    ok "$ref exists"
  else
    missing=$((missing + 1))
    notok "a workflow invokes $ref, which does not exist" \
      "remove the step, or restore the file"
  fi
done < <(grep -oE 'tests/[A-Za-z0-9._-]+\.sh' <<<"$CODE" | sort -u)
[ "$missing" -eq 0 ] && ok "every test named in a workflow is on disk"

# --- the exemption list stays honest ---------------------------------------

CASE="exemptions are live"
if [ "${#EXEMPT[@]}" -eq 0 ]; then
  ok "no exemptions to check"
fi
for entry in ${EXEMPT[@]+"${EXEMPT[@]}"}; do
  rel="${entry%%|*}"
  if [ ! -e "$REPO_ROOT/$rel" ]; then
    # An exemption outliving its script is not merely untidy: the name is now
    # free to be reused by a real suite, which would then be born exempt.
    notok "exemption names $rel, which does not exist" "drop the entry"
  elif grep -qF "$rel" <<<"$CODE"; then
    # The one hand-maintained piece of state this guard introduces, so it gets
    # its own check. An exemption for a suite that is now wired up is dead
    # weight that would silently re-cover the script if the step were removed.
    notok "$rel is exempt but IS invoked by a workflow" "drop the now-stale entry"
  else
    ok "$rel is exempt and still needs to be"
  fi
done

# --- the guard's own premise -----------------------------------------------

CASE="make test still globs"
# Everything above reasons about the difference between a GLOB (make) and a
# NAMED LIST (the workflow). If the Makefile ever stops globbing, that premise
# is wrong and the failure messages here start misdirecting the reader.
if grep -qF 'tests/*.test.sh' "$REPO_ROOT/Makefile"; then
  ok "the Makefile test target still globs tests/*.test.sh"
else
  notok "the Makefile no longer globs tests/*.test.sh" \
    "this guard's messages assume it does -- re-read them before changing it"
fi

CASE="this guard is itself wired in"
# The regress-to-zero case: a coverage checker that runs in no job is worth
# nothing, and would not notice its own absence, because it never runs.
self="tests/$(basename "${BASH_SOURCE[0]}")"
if grep -qF "$self" <<<"$CODE"; then
  ok "$self is invoked by a workflow"
else
  notok "$self runs in no job -- the coverage checker is itself uncovered"
fi

# --- report ----------------------------------------------------------------

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
