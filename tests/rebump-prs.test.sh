#!/usr/bin/env bash
# rebump-prs.test.sh -- .github/actions/rebump-prs (bdh-org/dev-common#344).
#
# Runs the REAL script against a fixture repo with a bare "origin" holding
# refs/pull/N/head, and `curl` stubbed on PATH to answer the GraphQL PR query. The cases are the
# ones a merge queue actually produces (the 2026-11-03 panoptikon run):
#   - a PR left in a version-line conflict by a merge
#   - a PR at the SAME number as main, which merges cleanly as agreement --
#     the case a conflict-triggered design would miss
#   - two PRs landing on one provisional number, which is allowed
#   - a PR above main that merges cleanly, left untouched, and one above main whose
#     version line conflicts, which is merged at its OWN number (dev-common#354)
#   - a PR that bumps a version file main's own bump never touched, so the merge
#     leaves it at the PR's number and not main's: re-bumped all the same, because
#     the move accepts either number (dev-common#361)
#   - a PR whose version line the merge leaves at NEITHER number, which the count
#     check still refuses -- the guard the #361 fix must not loosen away
#   - a PR that bumps a version file main DELETED, and the mirror, one that deletes
#     a version file main changed: a modify/delete has no conflict markers, so
#     keeping main's side is a no-op and the `git add` after it would resurrect the
#     file (or undo the deletion). Both are refused (dev-common#364)
#   - a PR with a real conflict, a draft, an unapproved PR
# then, in MODE=push, a whole DRAIN: one re-bump per run (dev-common#351), the
# re-bumped PR "merged", the next run re-bumping the next PR -- each landing at the
# right number with its own changes intact, including a non-version Makefile line
# (the line a greedy resolver wiped in panoptikon#1084) -- and every refusal
# pushing nothing and not using up the run's one push. The unapproved PR is
# re-bumped too, but only after every ready one, though its number is lower
# (dev-common#353).
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

CASE="the action defaults to report, and both tag workflows ask for push"
wf="$HERE/../.github/workflows"
if grep -qE '^[[:space:]]*default:[[:space:]]*report[[:space:]]*$' "$ACTION_DIR/action.yml" \
   && [ "$(grep -lE '^[[:space:]]*mode:[[:space:]]*push[[:space:]]*$' "$wf/tag-version.yml" "$wf/tag-version-self-hosted.yml" | wc -l)" -eq 2 ]; then
  ok "mode defaults to report; tag-version.yml and tag-version-self-hosted.yml pass mode: push"
else
  notok "the action's default is not report, or a tag workflow does not pass mode: push"
fi

CASE="both tag workflows check out with the App token"
# A push made with GITHUB_TOKEN does not trigger the PR's CI: the re-bumped PR
# would sit with no checks and never go green.
if [ "$(grep -lE 'token:[[:space:]]*\$\{\{ steps\.coder\.outputs\.coder_token \}\}' "$wf/tag-version.yml" "$wf/tag-version-self-hosted.yml" | wc -l)" -eq 2 ]; then
  ok "actions/checkout gets token: steps.coder.outputs.coder_token in both"
else
  notok "a tag workflow's checkout does not use the coder App token"
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
set_manifest() {  # a JSON "version" field that is NOT the repo's own version
  printf '{\n  "name": "r",\n  "version": "%s"\n}\n' "$1" >"$TMP/work/manifest.json"
}
set_version 1.2.0; set_manifest 0.4.0; echo base >"$TMP/work/shared.txt"
echo 1.2.0 >"$TMP/work/doomed.txt"   # a version file main will `git rm` (see pr14)
G add -A; G commit -qm base; G push -q origin main
base="$(G rev-parse HEAD)"

pr() {  # pr <n> <version> [file content] -- branch off base, push as refs/pull/<n>/head
  G checkout -q -B "pr$1" "$base"; set_version "$2"
  [ $# -ge 3 ] && echo "$3" >"$TMP/work/$4"
  echo "$1" >"$TMP/work/own-$1.txt"
  [ -n "${EXTRA:-}" ] && echo "$EXTRA" >>"$TMP/work/Makefile"
  G add -A; G commit -qm "pr $1"
  G push -q origin "HEAD:refs/pull/$1/head" "HEAD:refs/heads/pr$1"
}
pr 1 1.2.1                      # patch, conflicts on version lines once main moves
pr 2 1.3.0                      # minor, same number main will hold: merges as AGREEMENT
pr 3 1.2.1                      # patch, same provisional number as #1 -- allowed
pr 4 1.4.0                      # already above main
pr 5 1.2.1 "theirs" shared.txt  # real conflict outside version lines
pr 6 1.2.1                      # draft
pr 7 1.2.1                      # not approved, no auto-merge
EXTRA="EXTRA=1" pr 8 1.2.1      # also adds a Makefile line: must survive the re-bump
pr 11 1.2.1                     # auto-merge armed, but CI failed on the job's own re-bump
pr 9 1.2.1                      # its branch moves before the push: push refused
G commit -q --allow-empty -m "pushed later"; G push -q origin "HEAD:refs/heads/pr9"
G checkout -q -B pr10 "$base"; set_version 1.2.1; echo 1.2.1 >"$TMP/work/version.txt"
echo 10 >"$TMP/work/own-10.txt"
G add -A; G commit -qm "pr 10"; G push -q origin HEAD:refs/pull/10/head HEAD:refs/heads/pr10
#   ^ bumps a version.txt that main's bump never touched, so the merge leaves it at
#     1.2.1, the PR's own number, and not main's 1.3.0. The move accepts either, so
#     the count agrees and the PR is re-bumped (dev-common#361).
G checkout -q -B pr13 "$base"; set_version 1.2.1; set_manifest 1.2.1
echo 13 >"$TMP/work/own-13.txt"
G add -A; G commit -qm "pr 13"; G push -q origin HEAD:refs/pull/13/head HEAD:refs/heads/pr13
#   ^ also set an unrelated JSON "version" field to its own number. main holds that
#     field at 0.5.0, so the conflict resolves to a version line at NEITHER number:
#     the count check must still refuse this PR, all through the drain.
pr 14 1.2.1 1.2.1 doomed.txt
#   ^ bumps doomed.txt, which main DELETES: a modify/delete (UD), where git leaves
#     the PR's marker-free content in the tree. take_main_side cannot touch that, so
#     a `git add` would RESURRECT a file main deleted, at the new number -- and
#     nothing downstream catches it, because the surviving line IS a version line
#     (dev-common#364).
G checkout -q -B pr15 "$base"; set_version 1.2.1; G rm -q manifest.json
echo 15 >"$TMP/work/own-15.txt"
G add -A; G commit -qm "pr 15"; G push -q origin HEAD:refs/pull/15/head HEAD:refs/heads/pr15
#   ^ the DU mirror: the PR deletes manifest.json, whose "version" field main
#     changes. git leaves MAIN's content in the tree, so a `git add` would undo the
#     PR's own deletion -- and the move loop never looks, since the PR's diff adds
#     no line for that file.

# main moves: a minor merge to 1.3.0 that also edits shared.txt and drops doomed.txt
G checkout -q main; set_version 1.3.0; set_manifest 0.5.0; echo "ours" >"$TMP/work/shared.txt"
G rm -q doomed.txt
G add -A; G commit -qm "feat merged"; G push -q origin main

# A PR branched off main AS IT NOW IS, at a hand-picked target version several
# minors above it: above main AND merging cleanly, so nothing is owed it. Once main
# moves again its version line conflicts like every other PR's, and then it is
# merged at its OWN number -- main's version plus its level (minor) stays below
# 1.9.0 all through the drain, so a re-bump that ignored the max() would send it
# BACKWARDS (dev-common#354).
G checkout -q -B pr12 main; set_version 1.9.0; echo 12 >"$TMP/work/own-12.txt"
G add -A; G commit -qm "pr 12"; G push -q origin HEAD:refs/pull/12/head HEAD:refs/heads/pr12
G checkout -q main

mkdir -p "$TMP/bin"
# curl stub: writes the GraphQL answer to the -o file and prints the HTTP code,
# as `curl -o FILE -w '%{http_code}'` does. Also records that it was called with a
# bearer token, so a refactor back to `gh` (absent on forge) fails here.
cat >"$TMP/bin/curl" <<STUB
#!/usr/bin/env bash
out=""; while [ \$# -gt 0 ]; do
  case "\$1" in -o) out="\$2"; shift;; -H) case "\$2" in *"bearer "*) touch "$TMP/curl-authed";; esac; shift;; esac; shift
done
cp "$TMP/prs.json" "\$out"; printf 200
STUB
chmod +x "$TMP/bin/curl"

# The open PRs, one per line: <number> <review|-> <auto-merge 0|1> <draft 0|1>
# [<head: 1 = the job's own re-bump commit with FAILED checks>].
# #9, #10 and #13 have auto-merge armed, so they come first in line -- and #9 and
# #13 are refused, which must not use up the run's one push.
cat >"$TMP/open.txt" <<'EOF'
1 APPROVED 0 0
2 APPROVED 0 0
3 APPROVED 0 0
4 APPROVED 0 0
5 APPROVED 0 0
6 - 0 1
7 REVIEW_REQUIRED 0 0
8 APPROVED 0 0
9 APPROVED 1 0
10 APPROVED 1 0
11 - 1 0 1
12 APPROVED 0 0
13 APPROVED 1 0
14 APPROVED 0 0
15 APPROVED 0 0
EOF
write_prs() {
  awk 'BEGIN { printf "{\"data\":{\"repository\":{\"pullRequests\":{\"nodes\":[" }
    { printf "%s{\"number\":%s,\"headRefName\":\"pr%s\",\"isDraft\":%s,\"isCrossRepository\":false,\"reviewDecision\":%s,\"autoMergeRequest\":%s,\"commits\":{\"nodes\":[{\"commit\":{\"messageHeadline\":\"%s\",\"statusCheckRollup\":{\"state\":\"%s\"}}}]}}",
        (NR > 1 ? "," : ""), $1, $1, ($4 ? "true" : "false"), ($2 == "-" ? "null" : "\"" $2 "\""),
        ($3 ? "{\"enabledAt\":\"2026-11-03T00:00:00Z\"}" : "null"),
        ($5 ? "chore: merge main and re-bump to 1.2.1" : "pr " $1), ($5 ? "FAILURE" : "SUCCESS") }
    END { print "]}}}}" }' "$TMP/open.txt" >"$TMP/prs.json"
}
write_prs

run() {  # run <MODE> -- the real script, in the fixture checkout
  # With NO git identity, as on forge and the CI runner: `git merge` will not start
  # without one, and a developer's own identity hid that until CI (dev-common#344).
  mkdir -p "$TMP/home"
  (cd "$TMP/work" && env -u GIT_AUTHOR_NAME -u GIT_AUTHOR_EMAIL -u GIT_COMMITTER_NAME -u GIT_COMMITTER_EMAIL \
    HOME="$TMP/home" XDG_CONFIG_HOME="$TMP/home" GIT_CONFIG_NOSYSTEM=1 \
    PATH="$TMP/bin:$PATH" GH_TOKEN=t REPO=o/r MODE="$1" GITHUB_STEP_SUMMARY="$TMP/summary-$1.md" \
    bash "$SCRIPT" 2>&1)
}
PRS="1 2 3 4 5 7 8 9 10 11 12 13 14 15"   # every PR with a branch, so a stray push is seen
branch_sha() { git -C "$TMP/origin.git" rev-parse "refs/heads/pr$1"; }
# What GitHub does on a merge: main moves to the PR head -- which the previous run
# re-bumped, so it must contain main (asserted: a harness that merges a stale PR
# sends main backwards and every later case tests nothing) -- and the PR leaves the
# open list. Only the merged PR's ref is synced: #9's moved branch stays unseen.
merge_pr() {
  CASE="harness: #$1 was re-bumped before it merges"
  if git -C "$TMP/origin.git" merge-base --is-ancestor refs/heads/main "refs/heads/pr$1"; then
    ok "main is an ancestor of pr$1"
  else
    notok "pr$1 does not contain main -- the drain is out of order"
  fi
  git -C "$TMP/origin.git" update-ref refs/heads/main "refs/heads/pr$1"
  git -C "$TMP/origin.git" update-ref "refs/pull/$1/head" "refs/heads/pr$1"
  sed -i "/^$1 /d" "$TMP/open.txt"; write_prs
}
before=""; for n in $PRS; do before="$before $n=$(branch_sha $n)"; done

expect() {  # expect <case> <line the output must contain>
  CASE="$1"
  if grep -qF -- "$2" <<<"$out"; then ok "$2"; else notok "missing '$2' in:"; sed 's/^/         /' <<<"$out"; fi
}

# ---------------------------------------------------------------- report ---
out="$(run report)"; rc=$?
CASE="the report run succeeds"
if [ "$rc" -eq 0 ]; then ok "exit 0"; else notok "exit $rc:"; sed 's/^/         /' <<<"$out"; fi
expect "auto-merge goes first in line" "#9 1.2.1: WOULD RE-BUMP to 1.3.1 (patch)"
expect "only one re-bump per run; the rest wait" "#1 1.2.1: waiting: #9 is next in line"
expect "a PR at main's number is caught though git sees no conflict" "#2 1.3.0: waiting: #9 is next in line"
expect "a PR above main that merges cleanly is left as it is" "#12 1.9.0: ok: above main"
expect "a PR above main whose version line conflicts is IN LINE, not skipped as ok" \
  "#4 1.4.0: waiting: #9 is next in line"
expect "a conflict outside version lines is left alone, naming the file" \
  "#5 1.2.1: left alone: conflicts outside version lines in shared.txt"
expect "a version file main DELETED and the PR bumped is NOT version-only (dev-common#364)" \
  "#14 1.2.1: left alone: conflicts outside version lines in doomed.txt"
expect "nor is the mirror: a version file the PR deleted and main changed" \
  "#15 1.2.1: left alone: conflicts outside version lines in manifest.json"
expect "a draft is skipped" "#6 ?: skipped: draft"
expect "a PR whose CI failed on its own re-bump does not hold the line, though auto-merge is armed" \
  "#11 1.2.1: left alone: its CI failed after its last re-bump"
expect "an unready PR waits in line like the rest" "#7 1.2.1: waiting: #9 is next in line"

CASE="the job summary carries the table"
if grep -qF '| [#9](https://github.com/o/r/pull/9) | 1.2.1 | WOULD RE-BUMP to 1.3.1 (patch) |' "$TMP/summary-report.md"; then
  ok "summary has a row per PR, the PR a link"
else
  notok "summary-report.md lacks the linked #9 row:"; sed 's/^/         /' "$TMP/summary-report.md"
fi
CASE="the summary links the PR a waiting row names (a job summary does not autolink #N)"
if grep -qF '| [#1](https://github.com/o/r/pull/1) | 1.2.1 | waiting: [#9](https://github.com/o/r/pull/9) is next in line' "$TMP/summary-report.md"; then
  ok "waiting rows link the next PR"
else
  notok "the #1 row does not link #9:"; grep -F '#1]' "$TMP/summary-report.md" | sed 's/^/         /'
fi

CASE="the PR list comes from curl with the token, not from gh"
if [ -f "$TMP/curl-authed" ] && ! grep -qE '(^|[^-])\bgh (pr|api)\b' "$SCRIPT"; then
  ok "curl was called with a bearer token, and the script never runs gh (absent on forge)"
else
  notok "the script did not list PRs via curl with a bearer token, or still calls gh"
fi

CASE="report mode pushes nothing"
after=""; for n in $PRS; do after="$after $n=$(branch_sha $n)"; done
if [ "$before" = "$after" ]; then ok "no PR branch moved"; else notok "a PR branch moved in report mode"; fi

CASE="an unknown MODE is refused"
if (cd "$TMP/work" && PATH="$TMP/bin:$PATH" GH_TOKEN=t REPO=o/r MODE=yes bash "$SCRIPT" >/dev/null 2>&1); then
  notok "MODE=yes ran"
else
  ok "MODE=yes exits non-zero"
fi

# ------------------------------------------------------- push: a drain ---
at() { git -C "$TMP/origin.git" show "refs/heads/pr$1:$2" 2>/dev/null; }
pushes() {  # how many PR branches moved since $1 (a snapshot of branch_sha's)
  local snap="$1" c=0 n
  for n in $PRS; do case "$snap" in *" $n=$(branch_sha $n)"*) ;; *) c=$((c+1));; esac; done
  echo "$c"
}

snap="$before"; out="$(run push)"; rc=$?
CASE="push run 1 succeeds"
if [ "$rc" -eq 0 ]; then ok "exit 0"; else notok "exit $rc:"; sed 's/^/         /' <<<"$out"; fi
expect "a branch that moved is not overwritten" "#9 1.2.1: left alone: push refused (the branch moved); the next run retries"
expect "a refusal does not use up the run's push: the next in line goes" \
  "#10 1.2.1: RE-BUMPED to 1.3.1 (patch)"
expect "the rest wait for it" "#8 1.2.1: waiting: #10 is next in line"
CASE="exactly one branch pushed in run 1"
c="$(pushes "$snap")"; if [ "$c" = 1 ]; then ok "1 push"; else notok "$c pushes"; fi
CASE="a PR above main that merges cleanly is not pushed to"
case "$snap" in
  *" 12=$(branch_sha 12)"*) ok "pr12's branch did not move" ;;
  *) notok "pr12 was pushed to though it merges cleanly" ;;
esac
CASE="a version file main's own bump never touched reaches the new number (dev-common#361)"
if [ "$(at 10 Makefile | head -n1)" = VERSION=1.3.1 ] && [ "$(at 10 pkg/__init__.py)" = '__version__ = "1.3.1"' ] \
   && [ "$(at 10 version.txt)" = 1.3.1 ] && [ "$(at 10 own-10.txt)" = 10 ] && [ "$(at 10 shared.txt)" = ours ] \
   && git -C "$TMP/origin.git" merge-base --is-ancestor refs/heads/main refs/heads/pr10; then
  ok "pr10: 1.3.1 in Makefile, __version__ and version.txt, own-10.txt, main's shared.txt, main as ancestor"
else
  notok "pr10: $(at 10 Makefile | head -n1) / $(at 10 pkg/__init__.py) / version.txt=$(at 10 version.txt) / own=$(at 10 own-10.txt) / shared=$(at 10 shared.txt)"
fi
CASE="the re-bump commit is the coder App's"
if [ "$(git -C "$TMP/origin.git" log -1 --format='%an <%ae>' refs/heads/pr10)" = \
     'bdh-org-coder[bot] <305014630+bdh-org-coder[bot]@users.noreply.github.com>' ]; then
  ok "authored by bdh-org-coder[bot]"
else
  notok "authored by $(git -C "$TMP/origin.git" log -1 --format='%an <%ae>' refs/heads/pr10)"
fi

merge_pr 10; snap=""; for n in $PRS; do snap="$snap $n=$(branch_sha $n)"; done
out="$(run push)"
expect "a version line the merge leaves at NEITHER number is still refused" \
  "#13 1.2.1: left alone: moved 0 version lines in manifest.json, but the PR bumped 1"
expect "two refusals do not use up the run's push: the oldest ready PR goes next" \
  "#1 1.2.1: RE-BUMPED to 1.3.2 (patch)"
CASE="exactly one branch pushed in run 2"
c="$(pushes "$snap")"; if [ "$c" = 1 ]; then ok "1 push"; else notok "$c pushes"; fi
CASE="the re-bumped PR holds the new number in every version file, its own change and main's"
if [ "$(at 1 Makefile | head -n1)" = VERSION=1.3.2 ] && [ "$(at 1 pkg/__init__.py)" = '__version__ = "1.3.2"' ] \
   && [ "$(at 1 own-1.txt)" = 1 ] && [ "$(at 1 shared.txt)" = ours ] \
   && git -C "$TMP/origin.git" merge-base --is-ancestor refs/heads/main refs/heads/pr1; then
  ok "pr1: 1.3.2 in Makefile and __version__, own-1.txt, main's shared.txt, main as ancestor"
else
  notok "pr1: $(at 1 Makefile | head -n1) / $(at 1 pkg/__init__.py) / own=$(at 1 own-1.txt) / shared=$(at 1 shared.txt)"
fi

merge_pr 1; snap=""; for n in $PRS; do snap="$snap $n=$(branch_sha $n)"; done
out="$(run push)"
expect "after #1 merges, the agreement case goes next at its own level" "#2 1.3.0: RE-BUMPED to 1.4.0 (minor)"
CASE="exactly one branch pushed in run 3"
c="$(pushes "$snap")"; if [ "$c" = 1 ]; then ok "1 push"; else notok "$c pushes"; fi
CASE="#2 holds 1.4.0 in every version file"
if [ "$(at 2 Makefile | head -n1)" = VERSION=1.4.0 ] && [ "$(at 2 pkg/__init__.py)" = '__version__ = "1.4.0"' ]; then
  ok "pr2 at 1.4.0"
else
  notok "pr2: $(at 2 Makefile | head -n1) / $(at 2 pkg/__init__.py)"
fi

merge_pr 2; out="$(run push)"
expect "then #3, past #1's and #2's numbers" "#3 1.2.1: RE-BUMPED to 1.4.1 (patch)"
merge_pr 3; out="$(run push)"
expect "a PR that WAS above main falls behind as main passes it, and goes next" \
  "#4 1.4.0: RE-BUMPED to 1.5.0 (minor)"
merge_pr 4; out="$(run push)"
expect "then #8, approved, ahead of the older unapproved #7" "#8 1.2.1: RE-BUMPED to 1.5.1 (patch)"
expect "the unready PR waits for every ready one" "#7 1.2.1: waiting: #8 is next in line"
CASE="a non-version Makefile line survives (the panoptikon#1084 wipe)"
if [ "$(at 8 Makefile)" = "$(printf 'VERSION=1.5.1\nPACKAGE_DIR=pkg\nEXTRA=1')" ]; then
  ok "pr8's Makefile is exactly VERSION=1.5.1, PACKAGE_DIR=pkg, EXTRA=1"
else
  notok "pr8's Makefile is:"; at 8 Makefile | sed 's/^/         /'
fi

merge_pr 8; snap=""; for n in $PRS; do snap="$snap $n=$(branch_sha $n)"; done
out="$(run push)"
# main is 1.5.1 here, so #12's own level (minor) would put it at 1.6.0: it keeps
# 1.9.0 and gains only the merge -- the case that used to be skipped as "ok: above
# main" and left DIRTY forever (dev-common#354).
expect "a PR above main whose version line conflicts is merged, at its OWN number" \
  "#12 1.9.0: MERGED main, keeping 1.9.0"
CASE="exactly one branch pushed for the above-main PR"
c="$(pushes "$snap")"; if [ "$c" = 1 ]; then ok "1 push"; else notok "$c pushes"; fi
CASE="#12 kept 1.9.0 in every version file, with its own change and main's"
if [ "$(at 12 Makefile | head -n1)" = VERSION=1.9.0 ] && [ "$(at 12 pkg/__init__.py)" = '__version__ = "1.9.0"' ] \
   && [ "$(at 12 own-12.txt)" = 12 ] && [ "$(at 12 own-8.txt)" = 8 ] \
   && git -C "$TMP/origin.git" merge-base --is-ancestor refs/heads/main refs/heads/pr12; then
  ok "pr12: 1.9.0 in Makefile and __version__, own-12.txt, main's own-8.txt, main as ancestor"
else
  notok "pr12: $(at 12 Makefile | head -n1) / $(at 12 pkg/__init__.py) / own=$(at 12 own-12.txt) / main's=$(at 12 own-8.txt)"
fi

merge_pr 12; snap=""; for n in $PRS; do snap="$snap $n=$(branch_sha $n)"; done
out="$(run push)"
expect "with no ready PR left, the unready one is re-bumped (no /revise needed)" \
  "#7 1.2.1: RE-BUMPED to 1.9.1 (patch)"
expect "a delete-on-one-side conflict is refused without using up the run's push" \
  "#14 1.2.1: left alone: conflicts outside version lines in doomed.txt"
CASE="exactly one branch pushed for the unready PR"
c="$(pushes "$snap")"; if [ "$c" = 1 ]; then ok "1 push"; else notok "$c pushes"; fi

merge_pr 7; snap=""; for n in $PRS; do snap="$snap $n=$(branch_sha $n)"; done
out="$(run push)"
CASE="once the queue is drained, a run pushes nothing"
c="$(pushes "$snap")"
if [ "$c" = 0 ] && ! grep -qE "RE-BUMPED|MERGED" <<<"$out"; then ok "no push, no re-bump"; else notok "$c pushes:"; sed 's/^/         /' <<<"$out"; fi

CASE="refusals were never pushed in the whole drain"
moved=""; for n in 5 9 11 13 14 15; do
  case "$before" in *" $n=$(branch_sha $n)"*) ;; *) moved="$moved #$n";; esac
done
if [ -z "$moved" ]; then ok "#5 #9 #11 #13 #14 #15 untouched"; else notok "moved:$moved"; fi
CASE="the file main deleted was never resurrected, nor the PR's deletion undone"
# The branches above never moved, so this reads what a re-bump WOULD have pushed:
# doomed.txt still only on #14 (never carried into main or a drained PR), and
# manifest.json still absent from #15.
if [ -z "$(at 1 doomed.txt)" ] && [ -z "$(at 7 doomed.txt)" ] && [ -z "$(at 15 manifest.json)" ]; then
  ok "doomed.txt is gone from every re-bumped PR, and manifest.json stays deleted on #15"
else
  notok "doomed.txt on #1=$(at 1 doomed.txt) #7=$(at 7 doomed.txt); #15 manifest.json=$(at 15 manifest.json)"
fi

echo
echo "passed: $pass   failed: $fail"
[ "$fail" -eq 0 ]
