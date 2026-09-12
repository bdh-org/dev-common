#!/usr/bin/env bash
# template-initialised.test.sh -- the "Template initialised" gate, in BOTH
# workflows that embed it: .github/workflows/ci.yml AND
# .github/workflows/self-hosted-ci.yml (bdh-org/dev-common#242).
#
# WHAT THE GATE IS FOR
#
# `make init` is step 3 of creating a repo from devtemplate, and nothing notices
# when it is skipped. bdh-org/travel was created from the template on 2026-09-12
# without it and behaved normally for two PRs while carrying
# PROJECT_NAME=devtemplate and devtemplate's own VERSION=0.8.13 -- which
# `make bump-patch` then advanced to 0.8.14 on a repo with two commits. The
# omission surfaced only as a version gate failure, i.e. as a symptom.
#
# RUNS EVERY CASE AGAINST BOTH FILES, for the reason version-bumped.test.sh
# spells out at length: dev-common#182 tightened one copy and not the other, and
# the suite went green for ten days while the fleet ran the weaker rule. A
# comment cannot enforce agreement between two files; refusing to hardcode
# either one can.
#
# The cases run the REAL step body, extracted from the workflow, against
# throwaway directories -- not a re-implementation, which would pass while the
# workflow shipped something else.
#
# Usage:  bash tests/template-initialised.test.sh      (or: make test)

set -uo pipefail   # deliberately NOT -e: every case runs, then we report

HERE="$(cd "$(dirname "$0")" && pwd)"
# Every workflow that embeds the gate. Adding a third is one line here, and a
# file that stops carrying the step fails the "extractable" case rather than
# silently dropping out of coverage.
WORKFLOWS="ci.yml self-hosted-ci.yml"
STEP_NAME="Template initialised"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass=0; fail=0
ok()    { echo "ok   - $CASE: $1"; pass=$((pass+1)); }
notok() { echo "NOT OK - $CASE: $1"; fail=$((fail+1)); }

# The named step's `run: |` body, dedented out of the workflow. Same idiom as
# version-bumped.test.sh; a renamed step makes this empty and the first case red.
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

# A directory with a Makefile containing the given lines (or no Makefile at all).
make_repo() { # [makefile-line ...]
  local d="$TMP/repo-$RANDOM$RANDOM"
  mkdir -p "$d" || return 1
  if [ "$#" -gt 0 ]; then
    printf '%s\n' "$@" > "$d/Makefile"
  fi
  echo "$d"
}

for WF_NAME in $WORKFLOWS; do
  WF="$HERE/../.github/workflows/$WF_NAME"
  if [ ! -f "$WF" ]; then
    CASE="[$WF_NAME] the workflow exists"
    notok "no such workflow -- WORKFLOWS names a file that is not here"
    continue
  fi

  SCRIPT="$TMP/template-initialised-$WF_NAME.sh"
  extract "$WF" "$STEP_NAME" > "$SCRIPT"

  CASE="[$WF_NAME] the step is extractable"
  if [ -s "$SCRIPT" ]; then ok "$WF_NAME carries a '$STEP_NAME' step with a body"
  else notok "$WF_NAME has no '$STEP_NAME' step -- renamed or removed"; fi

  CASE="[$WF_NAME] the step runs before the version steps"
  # Ordering is load-bearing (dev-common#242): the version gate firing first is
  # what turned "this repo was never initialised" into "you forgot to bump".
  t_line=$(grep -n "      - name: $STEP_NAME\$" "$WF" | head -1 | cut -d: -f1)
  v_line=$(grep -n "      - name: Version consistency\$" "$WF" | head -1 | cut -d: -f1)
  if [ -n "$t_line" ] && [ -n "$v_line" ] && [ "$t_line" -lt "$v_line" ]; then
    ok "'$STEP_NAME' (line $t_line) precedes 'Version consistency' (line $v_line)"
  else
    notok "ordering wrong or step missing: template=$t_line version=$v_line"
  fi

  CASE="[$WF_NAME] the step is not confined to pull_request"
  # A repo-level property must fail on a push to main too, or the commit that
  # most needs to be identifiable is the one that escapes the check.
  if sed -n "$((t_line - 1)),$((t_line + 1))p" "$WF" | grep -q "if: github.event_name"; then
    notok "an 'if: github.event_name' guard was added -- pushes would stop being checked"
  else
    ok "no event guard on the step"
  fi

  run_step() { # dir repo-slug
    ( cd "$1" && GITHUB_REPOSITORY="$2" bash "$SCRIPT" 2>&1 )
  }

  CASE="[$WF_NAME] an initialised repo"
  d=$(make_repo "PROJECT_NAME=travel" "CONTAINER_NAME=travel" "VERSION=0.1.0")
  if out=$(run_step "$d" "bdh-org/travel"); then ok "PROJECT_NAME=travel passes"
  else notok "a properly initialised repo was rejected: $out"; fi

  CASE="[$WF_NAME] the travel shape -- init never run"
  d=$(make_repo "PROJECT_NAME=devtemplate" "CONTAINER_NAME=devtemplate" "VERSION=0.8.13")
  if out=$(run_step "$d" "bdh-org/travel"); then
    notok "PROJECT_NAME=devtemplate in bdh-org/travel PASSED -- the gate does nothing"
  else
    case "$out" in
      *"make init"*) ok "rejected, and the message names 'make init'" ;;
      *)             notok "rejected but the message never says what to run: $out" ;;
    esac
  fi

  CASE="[$WF_NAME] the message warns about existing tags"
  # Telling a repo that already has tags to run `make init` would reset VERSION
  # to 0.0.1, i.e. backwards past a tag -- the remedy must not be one-size.
  if out=$(run_step "$d" "bdh-org/travel"); then :; fi
  case "$out" in
    *"BACKWARDS"*) ok "the message distinguishes a fresh repo from one with history" ;;
    *)             notok "no warning about resetting VERSION backwards: $out" ;;
  esac

  CASE="[$WF_NAME] CONTAINER_NAME alone is enough to fail"
  # A half-done rename is still not initialised.
  d=$(make_repo "PROJECT_NAME=travel" "CONTAINER_NAME=devtemplate")
  if out=$(run_step "$d" "bdh-org/travel"); then
    notok "a stale CONTAINER_NAME PASSED -- half a rename counts as done"
  else ok "stale CONTAINER_NAME rejected"; fi

  CASE="[$WF_NAME] devtemplate itself"
  # The template legitimately has PROJECT_NAME=devtemplate and must stay green,
  # or every push to the template is red forever.
  d=$(make_repo "PROJECT_NAME=devtemplate" "CONTAINER_NAME=devtemplate")
  if out=$(run_step "$d" "bdh-org/devtemplate"); then ok "devtemplate is exempt"
  else notok "the template failed its own check: $out"; fi

  CASE="[$WF_NAME] a repo with no Makefile"
  # P2c data services and P1 primaries do not all carry one.
  d=$(make_repo)
  if out=$(run_step "$d" "bdh-org/somerepo"); then ok "absent Makefile skips cleanly"
  else notok "a repo with no Makefile was failed: $out"; fi

  CASE="[$WF_NAME] a Makefile with no PROJECT_NAME"
  d=$(make_repo "VERSION=1.0.0" "all:" "	echo hi")
  if out=$(run_step "$d" "bdh-org/somerepo"); then ok "absent PROJECT_NAME skips cleanly"
  else notok "a Makefile without PROJECT_NAME was failed: $out"; fi

  CASE="[$WF_NAME] whitespace and CRLF tolerance"
  # A Windows-edited or loosely-spaced Makefile must not sneak past the check.
  d=$(make_repo "PROJECT_NAME = devtemplate")
  if out=$(run_step "$d" "bdh-org/travel"); then
    notok "'PROJECT_NAME = devtemplate' (spaces) PASSED"
  else ok "spaces around = still caught"; fi
  d=$(make_repo)
  printf 'PROJECT_NAME=devtemplate\r\nCONTAINER_NAME=devtemplate\r\n' > "$d/Makefile"
  if out=$(run_step "$d" "bdh-org/travel"); then
    notok "CRLF line endings PASSED -- trailing \\r hid the value"
  else ok "CRLF line endings still caught"; fi

  CASE="[$WF_NAME] a name that merely contains 'devtemplate'"
  # Substring matching would false-fail a legitimately named repo.
  d=$(make_repo "PROJECT_NAME=devtemplate-db" "CONTAINER_NAME=devtemplate-db")
  if out=$(run_step "$d" "bdh-org/devtemplate-db"); then
    ok "devtemplate-db is not mistaken for an uninitialised clone"
  else notok "substring match false-failed devtemplate-db: $out"; fi

  CASE="[$WF_NAME] GITHUB_REPOSITORY unset"
  # Must fail loudly rather than guess: guessing either false-fails the template
  # or waves through an uninitialised clone.
  d=$(make_repo "PROJECT_NAME=devtemplate")
  if out=$( cd "$d" && env -u GITHUB_REPOSITORY bash "$SCRIPT" 2>&1 ); then
    notok "an unset GITHUB_REPOSITORY passed silently"
  else
    case "$out" in
      *GITHUB_REPOSITORY*) ok "fails loudly and names the missing variable" ;;
      *)                   notok "failed, but not for a stated reason: $out" ;;
    esac
  fi
done

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
