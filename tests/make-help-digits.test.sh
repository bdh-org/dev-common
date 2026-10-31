#!/usr/bin/env bash
# make-help-digits.test.sh -- `make help` and `make list` must list a target
# whose name contains a digit (bdh-org/dev-common#229), and a target declared
# with a sibling on one line (bdh-org/dev-common#323).
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
# Both listings get a case for two targets declared on one line
# (`s3-sync s3-sync-check:`). For `list` it reaches a part of the regex nothing
# else does -- a SECOND character class for the rest of the line, which a single
# digit-bearing name never gets to because the first class consumes the whole
# name. For `help` it is a separate defect found while fixing this one: `help`
# anchored its colon to the end of the FIRST name, so it listed no multi-target
# line at all, including this repo's own `list ls:` (bdh-org/dev-common#323). It
# now lists one as a single row naming both targets, `list ls`, so the case asks
# for the names adjacent and not merely both present somewhere in the output.
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

fixture_var := 7 ## an assignment, not a target
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

# A line declaring two targets, in both listings. For `list` this is the only
# case that reaches the second character class in its regex; for `help` it is
# the whole of bdh-org/dev-common#323 -- the colon used to be anchored to the
# end of the first name, so no such line was ever listed. Both names adjacent
# is the format decision: one row, named as the makefile names it.
for pair in "help:$HELP_OUT" "list:$LIST_OUT"; do
  goal="${pair%%:*}"
  out="${pair#*:}"
  CASE="$goal lists both names of a multi-target line"
  case "$out" in
    *"s3-sync s3-sync-check"*)
      ok "a multi-target line is listed as one row naming both targets" ;;
    *)
      notok "make $goal does not list 's3-sync s3-sync-check'" "$out" ;;
  esac
done

# What the greps filter out must stay filtered. Both widenings could overreach:
# adding 0-9 catches variables that carry a digit (VERSION=0.24.0 and friends),
# and allowing a space in a target name would catch ` :=` assignments if it were
# written as a character class instead of repeated whole names -- `fixture_var`
# in the fixture above is there to be absent.
for pair in "help:$HELP_OUT" "list:$LIST_OUT"; do
  goal="${pair%%:*}"
  out="${pair#*:}"
  CASE="$goal lists no variable assignment as a target"
  leaked=""
  for noise in fixture_var VERSION PROD_SERVER IMAGE_NAME MAKEFLAGS _SHOW_TARGETS; do
    printf '%s\n' "$out" | grep -qw -- "$noise" && leaked="$leaked $noise"
  done
  if [ -z "$leaked" ]; then
    ok "no variable assignment appears as a target"
  else
    notok "make $goal now lists variable assignments as targets" "$leaked"
  fi
done

printf '\npassed: %d   failed: %d\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
