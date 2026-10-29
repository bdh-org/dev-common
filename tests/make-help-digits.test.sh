#!/usr/bin/env bash
# make-help-digits.test.sh -- `make help` and `make list` must list a target
# whose name contains a digit (bdh-org/dev-common#229).
#
# The defect this encodes is invisible by construction. Both listings in
# make/utils.mk select target lines with a grep character class, and both
# classes omitted 0-9 -- so a target like `vm20-map` still RAN, and still ran
# correctly, it simply never appeared in either listing. Nothing is red, no
# command fails, and the target is undiscoverable by the one command whose job
# is discovery. It was found in bdh-site, where `vm20-map`, `vm20-map-check`
# and `vm20-viewer-test` were all missing from `make help`; digits in target
# names are ordinary across the fleet (`py311-*`, `s3-*`, `vm20-*`), so the fix
# is the character class and never a rename.
#
# The cases run the REAL recipes: a fixture makefile `include`s the shipped
# make/utils.mk and the test invokes `make help` / `make list` on it. A test
# that re-implemented the grep would pass while utils.mk shipped a different
# one -- the same trap tests/version-bumped.test.sh avoids by extracting the
# step it tests.
#
# `list` gets a case `help` cannot have: two targets declared on one line
# (`s3-sync s3-sync-check:`). Its regex has a SECOND character class for the
# rest of the line, and a single digit-bearing name does not reach it -- the
# first class consumes the whole name. Only the multi-target line pins it, and
# `help` anchors its colon to the first name so it never lists one at all.
#
# Usage:  bash tests/make-help-digits.test.sh      (or: make test)

set -uo pipefail   # deliberately NOT -e: every case runs, then we report

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
UTILS="$REPO_ROOT/make/utils.mk"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass=0
fail=0
CASE="(none)"

ok()    { pass=$((pass + 1)); printf 'ok     - %s: %s\n' "$CASE" "$1"; }
notok() {
  fail=$((fail + 1))
  printf 'NOT OK - %s: %s\n' "$CASE" "$1"
  [ -n "${2:-}" ] && printf '         got: %s\n' "$2"
  return 0
}

CASE="the file under test exists"
if [ -f "$UTILS" ]; then
  ok "make/utils.mk is where this suite expects it"
else
  notok "no make/utils.mk at $UTILS -- moved or renamed"
  printf '\npassed: %d   failed: %d\n' "$pass" "$fail"
  exit 1
fi

# The fixture. `alpha` is the control: it has no digit, so it was listed even
# with the defect present, and its absence means the harness itself is broken
# rather than the regex -- the difference between a red case and a test that
# measured nothing.
cat > "$TMP/Makefile" <<FIXTURE
include $UTILS

alpha: ## control: a target with no digit
	@true

vm20-map: ## the bdh-site target that was invisible
	@true

py311-lint: ## a digit run in the middle of the name
	@true

s3-sync s3-sync-check: ## two targets on one line, both with digits
	@true
FIXTURE

run_make() { make -C "$TMP" --no-print-directory "$1" 2>&1; }

HELP_OUT="$(run_make help)"
LIST_OUT="$(run_make list)"

# A `make` that failed outright (a syntax error in utils.mk, say) leaves output
# that contains none of the names below, and every case would report the defect
# instead of the breakage. Separate the two.
CASE="the fixture builds"
for pair in "help:$HELP_OUT" "list:$LIST_OUT"; do
  goal="${pair%%:*}"
  case "${pair#*:}" in
    *"No rule to make target"* | *"*** "*)
      notok "make $goal errored on the fixture" "${pair#*:}" ;;
    "")
      notok "make $goal printed nothing" ;;
    *)
      ok "make $goal ran against a makefile including the real utils.mk" ;;
  esac
done

CASE="help lists the control target"
case "$HELP_OUT" in
  *alpha*) ok "a target with no digit is listed (the harness works)" ;;
  *) notok "even 'alpha' is missing -- the fixture is not being read" "$HELP_OUT" ;;
esac

CASE="list lists the control target"
case "$LIST_OUT" in
  *alpha*) ok "a target with no digit is listed (the harness works)" ;;
  *) notok "even 'alpha' is missing -- the fixture is not being read" "$LIST_OUT" ;;
esac

# The defect itself, in both listings.
for name in vm20-map py311-lint; do
  CASE="help lists $name"
  case "$HELP_OUT" in
    *"$name"*) ok "a digit in the target name no longer hides it from make help" ;;
    *) notok "make help does not list $name -- the help grep still omits 0-9" "$HELP_OUT" ;;
  esac

  CASE="list lists $name"
  case "$LIST_OUT" in
    *"$name"*) ok "a digit in the target name no longer hides it from make list" ;;
    *) notok "make list does not list $name -- the list grep still omits 0-9" "$LIST_OUT" ;;
  esac
done

# Only `list` shows multi-target lines, and only this case reaches the second
# character class in its regex.
CASE="list lists both names of a multi-target line"
case "$LIST_OUT" in
  *"s3-sync s3-sync-check"*)
    ok "the trailing character class accepts digits too" ;;
  *)
    notok "make list does not list 's3-sync s3-sync-check' -- its second character class still omits 0-9" "$LIST_OUT" ;;
esac

# What the greps filter out must stay filtered: adding 0-9 widens them, and the
# variables it could newly catch all carry a digit (VERSION=0.24.0 and friends).
CASE="widening the class caught no variable assignments"
leaked=""
for noise in VERSION PROD_SERVER IMAGE_NAME MAKEFLAGS _SHOW_TARGETS; do
  printf '%s\n' "$LIST_OUT" | grep -qw -- "$noise" && leaked="$leaked $noise"
done
if [ -z "$leaked" ]; then
  ok "no variable assignment appears as a target"
else
  notok "make list now lists variable assignments as targets" "$leaked"
fi

printf '\npassed: %d   failed: %d\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
