#!/usr/bin/env bash
# bump-merge-guard.test.sh -- the bump-* targets in make/version.mk must REFUSE
# to run while a merge is in progress (bdh-org/dev-common#379, found in hog as
# finzeug/hog#1064).
#
# The defect: _bump_apply ends in `git commit`. Run with MERGE_HEAD present,
# that commit IS the merge commit -- it takes every staged conflict resolution
# with it and titles the lot `chore: bump version to <v>`. Nothing fails. The
# version is correct, the merge is complete, and `git log --oneline` shows a
# bump where a merge was, with the resolution described nowhere. The history is
# wrong in a way no later command can detect, which is why this has to be
# refused rather than warned about.
#
# hog carried the fix as a prerequisite-only rule in its own Makefile, which
# could only ever fix hog -- every other repo including version.mk had the same
# defect. So the case that matters here is that the guard is in the SHARED file:
# the fixture below includes the real make/version.mk and defines no guard of
# its own, so it passes only if version.mk brings one.
#
# The cases run the REAL recipes against throwaway git repos with a genuine
# conflicted-then-resolved merge, not a hand-made MERGE_HEAD file: a test that
# wrote .git/MERGE_HEAD itself would pass against a guard checking something
# `git merge` does not actually produce.
#
# Beyond the refusal, two properties the comment in version.mk claims:
#   - the guard is the FIRST clause, so a refused bump leaves Makefile and the
#     other version files untouched -- no half-applied bump to clean up;
#   - it is not sticky: committing the merge, as the message says to, lets the
#     very next bump through.
#
# Usage:  bash tests/bump-merge-guard.test.sh      (or: make test)

set -uo pipefail   # deliberately NOT -e: every case runs, then we report

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION_MK="$REPO_ROOT/make/version.mk"

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
if [ -f "$VERSION_MK" ]; then
  ok "make/version.mk is where this suite expects it"
else
  notok "no make/version.mk at $VERSION_MK -- moved or renamed"
  printf '\npassed: %d   failed: %d\n' "$pass" "$fail"
  exit 1
fi

# A throwaway repo whose Makefile carries a VERSION and includes the REAL
# version.mk -- and nothing else. No local guard, so whatever the cases below
# observe comes from the shared file.
#
# The identity is set per repo, never globally: this runs on a self-hosted
# runner whose git config is shared with everything else on the box.
make_repo() {
  local dir="$1"
  mkdir -p "$dir"
  (
    cd "$dir" || exit 1
    git init -q -b main .
    git config user.name 'bump guard test'
    git config user.email 'test@example.invalid'
    git config commit.gpgsign false
    cat > Makefile <<FIXTURE
VERSION=1.2.3

include $VERSION_MK
FIXTURE
    printf 'base\n' > shared.txt
    git add Makefile shared.txt
    git commit -qm 'initial'
  ) >/dev/null 2>&1
}

# Leave $1 mid-merge with the conflict resolved and staged -- exactly the state
# in which the next `git commit` concludes the merge, whatever its message says.
start_resolved_merge() {
  local dir="$1"
  (
    cd "$dir" || exit 1
    git checkout -q -b other
    printf 'theirs\n' > shared.txt
    git commit -qam 'their change'
    git checkout -q main
    printf 'ours\n' > shared.txt
    git commit -qam 'our change'
    git merge other        # conflicts, on purpose
    printf 'resolved\n' > shared.txt
    git add shared.txt
  ) >/dev/null 2>&1
}

version_of()  { sed -n 's/^VERSION=//p' "$1/Makefile"; }
commits_in()  { git -C "$1" rev-list --count HEAD; }

# --- the control: an ordinary repo still bumps -----------------------------
#
# First, because if the guard rejects everything the refusal cases below pass
# for the wrong reason and nobody can tell.
CLEAN="$TMP/clean"
make_repo "$CLEAN"
before_commits="$(commits_in "$CLEAN")"
clean_out="$(make -C "$CLEAN" --no-print-directory bump-patch 2>&1)"
clean_rc=$?

CASE="a repo with no merge in progress bumps"
if [ "$clean_rc" -eq 0 ]; then
  ok "make bump-patch succeeds when MERGE_HEAD does not exist"
else
  notok "make bump-patch failed on a clean repo -- the guard over-reaches, or the fixture is broken" "$clean_out"
fi

CASE="the control bump lands"
if [ "$(version_of "$CLEAN")" = "1.2.4" ] \
   && [ "$(commits_in "$CLEAN")" -eq $((before_commits + 1)) ]; then
  ok "VERSION is 1.2.4 and one commit was made"
else
  notok "expected VERSION=1.2.4 and one new commit" \
    "VERSION=$(version_of "$CLEAN") commits=$(commits_in "$CLEAN") (was $before_commits)"
fi

# --- the defect, for all three targets -------------------------------------
#
# All three, not one: they are three separate recipes, and a guard added to
# bump-patch alone is the shape of the original hog fix before it covered the
# other two.
for target in bump-patch bump-minor bump-major; do
  DIR="$TMP/merge-$target"
  make_repo "$DIR"
  start_resolved_merge "$DIR"

  CASE="the fixture reaches a merge-in-progress state ($target)"
  if git -C "$DIR" rev-parse -q --verify MERGE_HEAD >/dev/null 2>&1; then
    ok "MERGE_HEAD exists with the resolution staged"
  else
    notok "no MERGE_HEAD -- the fixture never got mid-merge, so this target measures nothing"
    continue
  fi

  before_commits="$(commits_in "$DIR")"
  out="$(make -C "$DIR" --no-print-directory "$target" 2>&1)"
  rc=$?

  CASE="$target refuses to run mid-merge"
  if [ "$rc" -ne 0 ]; then
    ok "make $target exits non-zero while MERGE_HEAD exists"
  else
    notok "make $target SUCCEEDED mid-merge -- its commit is the merge commit" "$out"
  fi

  CASE="$target says why it refused"
  case "$out" in
    *merge*) ok "the message names the merge in progress" ;;
    *) notok "nothing in the output mentions a merge, so the operator cannot tell what to fix" "$out" ;;
  esac

  CASE="$target writes nothing before refusing"
  if [ "$(version_of "$DIR")" = "1.2.3" ]; then
    ok "Makefile VERSION is untouched -- the guard runs before the rewrite"
  else
    notok "VERSION was rewritten by a bump that then refused to commit" "VERSION=$(version_of "$DIR")"
  fi

  CASE="$target concludes no merge"
  if [ "$(commits_in "$DIR")" -eq "$before_commits" ] \
     && git -C "$DIR" rev-parse -q --verify MERGE_HEAD >/dev/null 2>&1; then
    ok "no commit was made and the merge is still in progress for its own commit"
  else
    notok "the merge was concluded by the bump" \
      "commits=$(commits_in "$DIR") (was $before_commits) MERGE_HEAD=$(git -C "$DIR" rev-parse -q --verify MERGE_HEAD || echo gone)"
  fi

  CASE="the resolution survives $target"
  if [ "$(cat "$DIR/shared.txt")" = "resolved" ]; then
    ok "the staged conflict resolution is still there to be committed"
  else
    notok "the resolution was lost" "$(cat "$DIR/shared.txt")"
  fi
done

# --- the recovery path the message tells you to take -----------------------
#
# "bump after committing it" has to be true, or the guard is a dead end: a repo
# that can never bump again is worse than the history it was protecting.
RECOVER="$TMP/recover"
make_repo "$RECOVER"
start_resolved_merge "$RECOVER"
make -C "$RECOVER" --no-print-directory bump-patch >/dev/null 2>&1
git -C "$RECOVER" commit -qm 'merge other into main' >/dev/null 2>&1
before_commits="$(commits_in "$RECOVER")"
rec_out="$(make -C "$RECOVER" --no-print-directory bump-patch 2>&1)"
rec_rc=$?

CASE="the guard is not sticky"
if [ "$rec_rc" -eq 0 ] \
   && [ "$(version_of "$RECOVER")" = "1.2.4" ] \
   && [ "$(commits_in "$RECOVER")" -eq $((before_commits + 1)) ]; then
  ok "committing the merge lets the next bump through, as the message says"
else
  notok "bump-patch still refuses after the merge was committed" \
    "rc=$rec_rc VERSION=$(version_of "$RECOVER") commits=$(commits_in "$RECOVER") (was $before_commits): $rec_out"
fi

CASE="the merge keeps its own commit"
subjects="$(git -C "$RECOVER" log --format=%s -2 | tr '\n' '|')"
case "$subjects" in
  *"merge other into main"*) ok "the merge commit is described as a merge, with the bump above it" ;;
  *) notok "the merge commit is not in the last two subjects" "$subjects" ;;
esac

printf '\npassed: %d   failed: %d\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
