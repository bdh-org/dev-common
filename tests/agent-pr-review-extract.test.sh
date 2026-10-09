#!/usr/bin/env bash
# agent-pr-review-extract.test.sh -- the reviewer finds the review grok actually wrote
# (bdh-org/home-infra#1217), and folds what is only reasoning (bdh-org/home-infra#1255).
#
# grok 1.0.46 headless often ends with `text` empty and stopReason `cancelled`, whatever it
# wrote sitting in `thought`: a ONE-turn answer on a small clean PR, or a multi-turn session
# that stops mid-work below the turn ceiling (home-infra PR #1254, 7 turns). From 2026-10-04
# every review was discarded that way: the wrapper read only `text`, saw nothing, and refused
# to post -- while `thought` held "**No significant findings.** ...". Then the fix for #1217
# posted `thought` VERBATIM when it held no final block, and 34k chars of narration buried
# two real findings at the bottom of a PR. This drives the REAL extraction code (lifted out
# of the workflow's "Run the review" step, so a test cannot pass while the workflow diverges)
# against grok output shaped like those runs, and pins the cases where it must still refuse.
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

# Lift the python heredoc that follows `python3 - "$out" "$RUNNER_TEMP/review.md" <<'PY'`.
python3 - "$WF" "$TMP/extract.py" <<'PY'
import sys, textwrap
lines = open(sys.argv[1]).read().splitlines()
start = next(i for i, l in enumerate(lines)
             if l.strip().startswith('python3 - "$out" "$RUNNER_TEMP/review.md"'))
body = []
for l in lines[start + 1:]:
    if l.strip() == "PY":
        break
    body.append(l)
open(sys.argv[2], "w").write(textwrap.dedent("\n".join(body)) + "\n")
PY
[ -s "$TMP/extract.py" ] || { echo "NOT OK - could not lift the extraction code from $WF"; exit 1; }

run() {  # <json> -> rc in RC, review in REVIEW, log in LOG
  printf '%s' "$1" > "$TMP/out.json"
  rm -f "$TMP/review.md"
  LOG="$(RUNNER_TEMP="$TMP" GITHUB_STEP_SUMMARY="$TMP/summary" \
         python3 "$TMP/extract.py" "$TMP/out.json" "$TMP/review.md" 2>&1)"; RC=$?
  REVIEW="$(cat "$TMP/review.md" 2>/dev/null)"
}

# The folded form: one line that says grok never wrote the review, then the reasoning
# under <details>. Nothing above the fold may read as a verdict.
FOLD_HEAD="grok stopped before writing its review"
folded() {  # asserts the shape; $1 = what the fold must contain
  case "$REVIEW" in "$FOLD_HEAD"*) ok "opens by saying grok never wrote the review" ;;
                    *) notok "fold header (got: ${REVIEW:0:120})" ;; esac
  case "$REVIEW" in *"<details><summary>grok's reasoning ("*" chars)</summary>"*"</details>") ok "the reasoning is folded under <details>" ;;
                    *) notok "details fold (got: ${REVIEW:0:200} ... ${REVIEW: -40})" ;; esac
  case "$REVIEW" in *"$1"*) ok "grok's own words are inside the fold, verbatim" ;;
                    *) notok "fold content (wanted: $1)" ;; esac
  case "$LOG" in *"posted folded"*) ok "the log says the review was folded" ;; *) notok "log line (got: $LOG)" ;; esac
}

CASE="tagged review in text"
run '{"stopReason":"end_turn","num_turns":4,"total_cost_usd":0.1,"text":"Let me think.\n<review>**high** a.sh:3 -- breaks</review>"}'
[ "$RC" = 0 ] && ok "posts" || notok "posts (rc=$RC: $LOG)"
[ "$REVIEW" = "**high** a.sh:3 -- breaks" ] && ok "only what is inside the tags" || notok "tag contents only (got: $REVIEW)"
case "$LOG" in *"review from text"*) ok "the log names the source and the stop reason" ;; *) notok "log line (got: $LOG)" ;; esac

CASE="untagged text (older prompt)"
run '{"stopReason":"end_turn","num_turns":4,"total_cost_usd":0.1,"text":"No significant findings."}'
[ "$RC" = 0 ] && [ "$REVIEW" = "No significant findings." ] && ok "an untagged answer is still taken whole" \
  || notok "untagged text (rc=$RC, got: $REVIEW)"

CASE="the #1212 shape: text empty, tagged review in thought"
run '{"stopReason":"cancelled","num_turns":1,"total_cost_usd":0.03,"text":"","thought":"reading the diff... <review>**No significant findings.** The diff adds wedge-daemon with tight validation.</review>"}'
[ "$RC" = 0 ] && ok "posts instead of refusing" || notok "posts (rc=$RC: $LOG)"
case "$REVIEW" in "**No significant findings.** The diff adds wedge-daemon"*) ok "the review from thought is posted, open" ;;
                  *) notok "review from thought (got: $REVIEW)" ;; esac
case "$REVIEW" in *home-infra#1217*) ok "and says where it came from" ;; *) notok "provenance note" ;; esac
case "$REVIEW" in *"<details>"*) notok "a final tagged block must NOT be folded" ;; *) ok "not folded" ;; esac

CASE="the #1204 shape: text empty, a bare verdict in thought"
run '{"stopReason":"cancelled","num_turns":1,"total_cost_usd":0.0156,"text":"","thought":"The task is to review pull request #1204.\nNo significant findings."}'
[ "$RC" = 0 ] && ok "a bare verdict is posted, not discarded" || notok "bare verdict posted (rc=$RC: $LOG)"
case "$REVIEW" in "No significant findings."*) notok "a bare phrase in reasoning was posted AS a clean verdict" ;; *) ok "never promoted to a verdict" ;; esac
folded "The task is to review pull request #1204."

CASE="reasoning that names a finding is NOT a clean verdict"
run '{"stopReason":"cancelled","num_turns":1,"total_cost_usd":0.02,"text":"","thought":"At first no significant findings, but medium: x.sh:4 drops the error."}'
folded "medium: x.sh:4 drops the error"

# The coordinator's scenario 1: a High finding, then the prompt's own instruction quoted.
CASE="a High finding, then the quoted instruction <review>No significant findings.</review>"
run '{"stopReason":"cancelled","num_turns":1,"total_cost_usd":0.02,"text":"","thought":"high: a.sh:9 deletes the only backup. The prompt says if nothing is worth reporting write exactly <review>No significant findings.</review>"}'
case "$REVIEW" in "No significant findings."*) notok "posted a FALSE CLEAN review" ;;
                  *"high: a.sh:9 deletes the only backup"*) ok "the High finding is posted, not the quoted clean line" ;;
                  *) notok "high finding posted (rc=$RC, got: $REVIEW)" ;; esac

# Scenario 2: the diff contains the literal, echoed mid-thought, and analysis follows it.
CASE="a diff echoing <review>No significant findings.</review> with reasoning after it"
run '{"stopReason":"cancelled","num_turns":1,"total_cost_usd":0.02,"text":"","thought":"The diff adds a template line <review>No significant findings.</review> to the prompt. low: prompt.py:3 the tag is unescaped."}'
case "$REVIEW" in "No significant findings."*) notok "posted the echoed literal as a clean review" ;;
                  *"low: prompt.py:3"*) ok "a block that is not the last content is ignored; the reasoning is posted" ;;
                  *) notok "echo scenario (rc=$RC, got: $REVIEW)" ;; esac
folded "low: prompt.py:3 the tag is unescaped."

CASE="a FINAL clean block after a finding-free thought"
run '{"stopReason":"cancelled","num_turns":1,"total_cost_usd":0.02,"text":"","thought":"Checked the two files. <review>No significant findings.</review>"}'
case "$REVIEW" in "No significant findings."*) ok "is taken as the verdict" ;; *) notok "final clean block (got: $REVIEW)" ;; esac

# The #1254 shape (home-infra, 2026-10-09): seven turns, six files read, two findings named
# in the narration, "I will now finalize the review output." -- and then nothing.
CASE="the #1254 shape: a multi-turn session that stops before writing the review"
run '{"stopReason":"cancelled","num_turns":7,"total_cost_usd":0.1146,"text":"","thought":"Reviewing PR #1254. The final review must be written inside `<review>` tags.\n\nI found a cleanup bug. If `mktemp` fails, the function returns early without setting `STATUS`. This is a correctness bug with medium severity.\n\nA non-numeric GH_API_TRIES causes an infinite retry loop.\n\nI will report two findings. I will now finalize the review output."}'
[ "$RC" = 0 ] && ok "posts: the findings are in there" || notok "posts (rc=$RC: $LOG)"
folded "If \`mktemp\` fails, the function returns early without setting \`STATUS\`."
case "$REVIEW" in *"stopReason \`cancelled\`, 7 turns"*) ok "the header carries the real stop reason and turn count" ;; *) notok "stop facts in header (got: ${REVIEW:0:200})" ;; esac

CASE="a thought longer than GitHub's review limit is cut BEFORE the fold closes"
run "$(python3 -c 'import json; print(json.dumps({"stopReason":"cancelled","num_turns":9,"total_cost_usd":0.2,"text":"","thought":"medium: a.sh:1 the lock is never released. " + ("more reasoning. " * 5000)}))')"
[ "$RC" = 0 ] && ok "posts" || notok "posts (rc=$RC: $LOG)"
[ "${#REVIEW}" -lt 65000 ] && ok "fits GitHub's limit with the post step's header to spare (${#REVIEW} chars)" || notok "too long: ${#REVIEW} chars"
case "$REVIEW" in *"_(cut here; the whole text is in the run log)_"*"</details>") ok "says it was cut, and the fold still closes" ;; *) notok "cut note / fold close (tail: ${REVIEW: -120})" ;; esac
folded "medium: a.sh:1 the lock is never released."

CASE="a details tag inside the reasoning cannot end the fold early"
run '{"stopReason":"cancelled","num_turns":2,"total_cost_usd":0.02,"text":"","thought":"The diff adds </details> after the table. medium: page.py:8 the fold never closes."}'
[ "$RC" = 0 ] && ok "posts" || notok "posts (rc=$RC: $LOG)"
n="$(grep -o '</details>' <<<"$REVIEW" | wc -l)"
[ "$n" = 1 ] && ok "exactly one closing tag, the fold's own" || notok "closing tags: $n"
case "$REVIEW" in *"&lt;/details> after the table"*) ok "the quoted tag is shown as text" ;; *) notok "quoted tag not neutralised" ;; esac
folded "medium: page.py:8 the fold never closes."

CASE="nothing at all"
run '{"stopReason":"cancelled","num_turns":1,"total_cost_usd":0.01,"text":"","thought":"Let me look at the diff."}'
[ "$RC" != 0 ] && ok "still refuses an empty review" || notok "refuses empty"
case "$LOG" in *"refusing to post an empty review"*) ok "and says why" ;; *) notok "reason (log: $LOG)" ;; esac

CASE="every run still logs its stop reason and cost"
case "$LOG" in *'"stopReason": "cancelled"'*) ok "stopReason printed" ;; *) notok "stopReason printed" ;; esac
[ -s "$TMP/grok-cost.txt" ] && ok "cost file written for the review header" || notok "cost file"

echo
echo "agent-pr-review-extract: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
