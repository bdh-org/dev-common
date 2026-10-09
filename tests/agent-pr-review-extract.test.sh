#!/usr/bin/env bash
# agent-pr-review-extract.test.sh -- the reviewer posts the review grok WROTE, never its
# reasoning, with the right event (bdh-org/home-infra#1217, #1255, #1256).
#
# grok headless often ends with `text` (the final message) empty and its verdict only in
# `thought`. The workflow resumes the session once to make it write the review; what it
# never writes is never posted (the fold of #1255 is gone: Brian needs a review, not
# reasoning). A review that names a finding is posted as REQUEST_CHANGES, a clean one as
# COMMENT; on an agent-authored PR a finding is handed back with a /revise, at most
# max_revise_rounds times; this reviewer's earlier CHANGES_REQUESTED is dismissed as
# superseded. This drives the REAL code lifted out of the workflow -- extract.py (the
# "Run the review" step) and compose.py (the "Post the review" step) -- so a test cannot
# pass while the workflow diverges.
#
# Usage:  bash tests/agent-pr-review-extract.test.sh      (or: make test)

set -uo pipefail   # deliberately NOT -e: every case runs, then we report

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WF="$REPO_ROOT/.github/workflows/agent-pr-review.yml"

pass=0
fail=0
CASE="(none)"
ok()    { pass=$((pass + 1)); printf 'ok     - %s: %s\n' "$CASE" "$1"; }
notok() { fail=$((fail + 1)); printf 'NOT OK - %s: %s\n' "$CASE" "$1"; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Lift the python heredoc that follows a `cat > "$RUNNER_TEMP/<name>.py" <<'PY'` line.
lift() {  # <marker prefix> <out>
  python3 - "$WF" "$2" "$1" <<'PY'
import sys, textwrap
lines = open(sys.argv[1]).read().splitlines()
start = next(i for i, l in enumerate(lines) if l.strip().startswith(sys.argv[3]))
body = []
for l in lines[start + 1:]:
    if l.strip() == "PY":
        break
    body.append(l)
open(sys.argv[2], "w").write(textwrap.dedent("\n".join(body)) + "\n")
PY
  [ -s "$2" ] || { echo "NOT OK - could not lift $1 from $WF"; exit 1; }
}
lift 'cat > "$RUNNER_TEMP/extract.py"' "$TMP/extract.py"
lift 'cat > "$RUNNER_TEMP/compose.py"' "$TMP/compose.py"

T="$TMP/rt"   # the step's RUNNER_TEMP, fresh per case
fresh() { rm -rf "$T"; mkdir -p "$T"; }

extract() {  # <json> [label] -> RC, REVIEW, LOG
  printf '%s' "$1" > "$T/out.json"
  LOG="$(RUNNER_TEMP="$T" GITHUB_STEP_SUMMARY="$T/summary" \
         python3 "$TMP/extract.py" "$T/out.json" "$T/review.md" "${2:-review}" 2>&1)"; RC=$?
  REVIEW="$(cat "$T/review.md" 2>/dev/null)"
}

# compose fixtures: the review, the runs behind it, the PR author, what is on the PR.
review()   { printf '%s' "$1" > "$T/review.md"; }
runs()     { printf '%s\n' "$@" > "$T/grok-runs.jsonl"; }
pr_by()    { printf '{"number":7,"user":{"id":%s}}' "$1" > "$T/pr.json"; }
reviews()  { printf '%s' "$1" > "$T/prior-reviews.json"; }
comments() { printf '%s' "$1" > "$T/prior-comments.json"; }
AGENT=305014630; ME=337812394; SESSION=333881240
ONE_RUN='{"label":"review","stopReason":"end_turn","num_turns":9,"total_cost_usd":0.15}'
setup() {  # a finding-free default fixture; cases override pieces
  fresh; runs "$ONE_RUN"; pr_by "$AGENT"; reviews '[]'; comments '[]'
}
compose() {  # [VAR=value ...] -> RC, LOG, EVENT, BODY
  LOG="$(env RUNNER_TEMP="$T" PR_SHA=abcdef0123456789 MODEL=grok-build-0.1 GROK_VERSION=1.0.50 \
             RUN_URL=https://x/run/1 REQUEST_CHANGES=true MAX_REVISE_ROUNDS=1 \
             CODER_USER_ID="$AGENT" REVIEWER_USER_ID="$ME" "$@" python3 "$TMP/compose.py" 2>&1)"; RC=$?
  EVENT="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["event"])' "$T/review.json" 2>/dev/null)"
  BODY="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["body"])' "$T/review.json" 2>/dev/null)"
}

# ---- extract.py: only the final message is the review ---------------------------------

CASE="tagged review in text"
fresh; extract '{"stopReason":"end_turn","num_turns":4,"total_cost_usd":0.1,"text":"Let me think.\n<review>- **high** a.sh:3 -- breaks</review>"}'
[ "$RC" = 0 ] && ok "exit 0" || notok "exit 0 (rc=$RC: $LOG)"
[ "$REVIEW" = "- **high** a.sh:3 -- breaks" ] && ok "only what is inside the tags" || notok "tag contents only (got: $REVIEW)"
case "$LOG" in *'grok (review): {"stopReason": "end_turn"'*) ok "logs the stop reason under the run's label" ;; *) notok "log (got: $LOG)" ;; esac
[ "$(wc -l < "$T/grok-runs.jsonl")" = 1 ] && ok "one line in grok-runs.jsonl for the header" || notok "runs file"

CASE="untagged text (older prompt)"
fresh; extract '{"stopReason":"end_turn","num_turns":4,"total_cost_usd":0.1,"text":"No significant findings."}'
[ "$RC" = 0 ] && [ "$REVIEW" = "No significant findings." ] && ok "an untagged answer is taken whole" || notok "untagged (rc=$RC, got: $REVIEW)"

CASE="the #1254 shape: text empty, the verdict only in thought"
fresh; extract '{"stopReason":"cancelled","num_turns":7,"total_cost_usd":0.11,"text":"","thought":"I found a bug: medium severity, mktemp. <review>No significant findings.</review> I will now finalize the review output."}'
[ "$RC" = 0 ] && ok "exit 0: not an error, the step resumes the session" || notok "exit 0 (rc=$RC: $LOG)"
[ -e "$T/review.md" ] && [ ! -s "$T/review.md" ] && ok "review.md is EMPTY: reasoning is never the review" || notok "empty review (got: $REVIEW)"
case "$LOG" in *"no review in text (review)"*"I will now finalize"*) ok "the thought's tail goes to the log" ;; *) notok "log tail (got: $LOG)" ;; esac

CASE="a resumed session that then writes it"
extract '{"stopReason":"end_turn","num_turns":1,"total_cost_usd":0.03,"text":"<review>- **medium** lib/gh.sh:102 -- mktemp failure leaves STATUS stale</review>"}' finish
[ "$REVIEW" = "- **medium** lib/gh.sh:102 -- mktemp failure leaves STATUS stale" ] && ok "the second attempt's review is taken" || notok "finish review (got: $REVIEW)"
[ "$(wc -l < "$T/grok-runs.jsonl")" = 2 ] && ok "both runs are on record for the header" || notok "runs file lines: $(wc -l < "$T/grok-runs.jsonl")"

CASE="not JSON"
fresh; extract 'Error: something'
[ "$RC" != 0 ] && ok "fails" || notok "fails"
case "$LOG" in *"not JSON"*) ok "and says so" ;; *) notok "reason (log: $LOG)" ;; esac

# ---- compose.py: the event, the hand-back, the supersede --------------------------------

CASE="a finding on an agent PR, first time"
setup; review '- **medium** `lib/gh.sh:102` -- returns without setting STATUS; the next repo reads the previous body'
compose
[ "$RC" = 0 ] && ok "exit 0" || notok "exit 0 (rc=$RC: $LOG)"
[ "$EVENT" = REQUEST_CHANGES ] && ok "REQUEST_CHANGES" || notok "event (got: $EVENT)"
case "$BODY" in '**Grok review** of `abcdef0`'*'$0.15, 9 turns; [run]'*) ok "header: sha, cost, turns, run link" ;; *) notok "header (got: ${BODY:0:160})" ;; esac
case "$BODY" in *"resumed"*) notok "says resumed when it was not" ;; *) ok "one run, no resume note" ;; esac
case "$BODY" in *'- **medium** `lib/gh.sh:102`'*"Changes requested"*) ok "the finding, then what clears the request" ;; *) notok "body (got: $BODY)" ;; esac
[ -s "$T/revise.md" ] && ok "a /revise is written" || notok "revise.md"
case "$(cat "$T/revise.md" 2>/dev/null)" in "/revise"*'- **medium** `lib/gh.sh:102`'*"hand-back 1 of 1"*) ok "it starts with /revise, carries the finding, counts the round" ;; *) notok "revise body (got: $(cat "$T/revise.md" 2>/dev/null))" ;; esac
[ ! -s "$T/dismiss.txt" ] && ok "nothing to supersede" || notok "dismiss.txt: $(cat "$T/dismiss.txt")"
[ ! -e "$T/no-review" ] && ok "no no-review marker" || notok "marker"
case "$LOG" in *"handing back to the agent: /revise 1 of 1"*) ok "the log says it handed back" ;; *) notok "log (got: $LOG)" ;; esac

CASE="a finding on an agent PR after the hand-back was spent"
setup; review '- **low** a.sh:1 -- still wrong'
comments "[{\"user\":{\"id\":$ME},\"body\":\"/revise\\n\\nearlier hand-back\"}]"
compose
[ "$EVENT" = REQUEST_CHANGES ] && ok "still REQUEST_CHANGES" || notok "event (got: $EVENT)"
[ ! -e "$T/revise.md" ] && ok "no second /revise" || notok "revise.md written again"
case "$LOG" in *"not handing back: 1 /revise hand-back(s) already spent (max 1)"*) ok "says the round was spent" ;; *) notok "log (got: $LOG)" ;; esac

CASE="a human's /revise does not count against the reviewer's rounds"
setup; review '- **low** a.sh:1 -- wrong'
comments '[{"user":{"id":1},"body":"/revise please tidy"}]'
compose
[ -s "$T/revise.md" ] && ok "the reviewer still hands back once" || notok "revise.md"

CASE="max_revise_rounds 0"
setup; review '- **high** a.sh:1 -- wrong'
compose MAX_REVISE_ROUNDS=0
[ "$EVENT" = REQUEST_CHANGES ] && [ ! -e "$T/revise.md" ] && ok "requests changes, never hands back" || notok "event=$EVENT revise=$([ -e "$T/revise.md" ] && echo yes || echo no)"

CASE="a finding on a session's PR"
setup; pr_by "$SESSION"; review '- **medium** a.sh:1 -- wrong'
compose
[ "$EVENT" = REQUEST_CHANGES ] && ok "REQUEST_CHANGES" || notok "event (got: $EVENT)"
[ ! -e "$T/revise.md" ] && ok "no /revise: the session takes it" || notok "revise.md on a session PR"

CASE="a clean review supersedes this reviewer's earlier CHANGES_REQUESTED"
setup; review 'No significant findings.'
reviews "[{\"id\":11,\"user\":{\"id\":$ME},\"state\":\"CHANGES_REQUESTED\"},{\"id\":12,\"user\":{\"id\":999},\"state\":\"CHANGES_REQUESTED\"},{\"id\":13,\"user\":{\"id\":$ME},\"state\":\"COMMENTED\"}]"
compose
[ "$EVENT" = COMMENT ] && ok "COMMENT" || notok "event (got: $EVENT)"
[ "$(cat "$T/dismiss.txt")" = "11" ] && ok "dismisses its own CHANGES_REQUESTED only, not another reviewer's" || notok "dismiss.txt: $(cat "$T/dismiss.txt")"
[ ! -e "$T/revise.md" ] && ok "no /revise" || notok "revise.md"
case "$BODY" in *"Changes requested"*) notok "a clean review must not carry the change-request note" ;; *) ok "no change-request note" ;; esac

CASE="the wording of the real 1254 review (bold severity, no bullet)"
setup; review '**medium** `scripts/lib/gh.sh:261`

`gh_api_get` does `resp="$(mktemp)" || return 0` ...

No other correctness, security or data-loss problems were found in the changed paths.'
compose
[ "$EVENT" = REQUEST_CHANGES ] && ok "is a finding" || notok "event (got: $EVENT)"

CASE="a finding that quotes the clean phrase is still a finding"
setup; review 'At first no significant findings, but - **low** x.sh:4 drops the error.'
compose
[ "$EVENT" = REQUEST_CHANGES ] && ok "the finding wins" || notok "event (got: $EVENT)"

CASE="request_changes=false (the comment-only trial)"
setup; review '- **high** a.sh:1 -- wrong'
compose REQUEST_CHANGES=false
[ "$EVENT" = COMMENT ] && ok "COMMENT" || notok "event (got: $EVENT)"
[ ! -e "$T/revise.md" ] && ok "and no hand-back" || notok "revise.md"

CASE="no review at all, even after the resume"
setup; : > "$T/review.md"
runs '{"label":"review","stopReason":"cancelled","num_turns":7,"total_cost_usd":0.11}' '{"label":"finish","stopReason":"cancelled","num_turns":1,"total_cost_usd":0.02}'
reviews "[{\"id\":21,\"user\":{\"id\":$ME},\"state\":\"CHANGES_REQUESTED\"}]"
compose
[ "$RC" = 0 ] && ok "compose itself succeeds (the post step fails AFTER posting)" || notok "rc=$RC: $LOG"
[ "$EVENT" = COMMENT ] && ok "COMMENT" || notok "event (got: $EVENT)"
case "$BODY" in *"wrote no review (review: cancelled, finish: cancelled)"*"Re-add the \`agent-review\` label"*) ok "says what happened and how to retry" ;; *) notok "body (got: $BODY)" ;; esac
case "$BODY" in *'$0.13, 8 turns (resumed once to write it)'*) ok "the header sums both runs and says it resumed" ;; *) notok "header (got: ${BODY:0:200})" ;; esac
[ -e "$T/no-review" ] && ok "the no-review marker fails the check" || notok "marker"
[ ! -s "$T/dismiss.txt" ] && ok "an earlier finding STANDS: nothing is superseded by no review" || notok "dismissed: $(cat "$T/dismiss.txt")"
[ ! -e "$T/revise.md" ] && ok "no /revise" || notok "revise.md"

CASE="a review longer than GitHub's limit"
setup; review "$(python3 -c 'print("- **low** a.sh:1 -- " + "wrong " * 12000)')"
compose
[ "${#BODY}" -lt 65100 ] && ok "cut under the limit (${#BODY} chars)" || notok "too long: ${#BODY}"
case "$BODY" in *"cut at GitHub's review size limit"*) ok "and says so" ;; *) notok "cut note" ;; esac

echo
echo "agent-pr-review-extract: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
