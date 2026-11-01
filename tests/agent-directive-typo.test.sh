#!/usr/bin/env bash
# agent-directive-typo.test.sh -- a MISSPELT agent directive is named, not ignored
# (bdh-org/dev-common#303).
#
# The bug this encodes: `directive()` matches the key exactly, so a body opening with
# `agent-tuns: 150` (missing the r) matched nothing, the run took the default turn
# budget and then died on the very ceiling that line asked to raise. It happened three
# times on bdh-org/home-infra#1253, and each failure comment told the reader to put
# `agent-turns: 150` on its own line -- which, to a human skimming the body, it already
# was. The workflow already warns when an unclosed code fence would swallow directives;
# a typo is the same failure and said nothing.
#
# Two properties, because the fix has two halves:
#   1. THE WARNING -- the real "Resolve model + turn budget" shell, lifted out of both
#      workflows that carry it, warns about an unknown column-0 `agent-<word>:` key and
#      names the nearest known directive, while still resolving the run at the default.
#      A correctly spelt directive produces no warning and still applies.
#   2. THE COMMENT -- the real "Verify the revision pushed" python, driven against a
#      stub GitHub API, opens its out-of-turns message with the typo. That comment is
#      what a reader actually sees; the ::warning:: is in a log they were never sent to.
#
# Nothing here re-implements either half: every case runs text taken from the workflows.
# The harness mirrors tests/agent-pr-revise-rereview.test.sh.
#
# Usage:  bash tests/agent-directive-typo.test.sh      (or: make test)

set -uo pipefail   # deliberately NOT -e: every case runs, then we report

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ISSUE_WF="$REPO_ROOT/.github/workflows/agent-issue-to-pr.yml"
REVISE_WF="$REPO_ROOT/.github/workflows/agent-pr-revise.yml"

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

TMP="$(mktemp -d)"
PID=""
trap '[ -n "$PID" ] && kill "$PID" 2>/dev/null; rm -rf "$TMP"' EXIT

# ---------------------------------------------------------------- lifting helpers

# The `run: |` block of the step with the given name, dedented into a script.
lift_run() {  # lift_run <workflow> <step name> <outfile>
  python3 - "$1" "$2" "$3" <<'PY'
import sys, textwrap
lines = open(sys.argv[1]).read().splitlines()
want = "- name: " + sys.argv[2]
i = next(i for i, l in enumerate(lines) if l.strip() == want)
j = next(k for k in range(i, len(lines)) if lines[k].strip() == "run: |")
indent = len(lines[j]) - len(lines[j].lstrip())
body = []
for l in lines[j + 1:]:
    if l.strip() and len(l) - len(l.lstrip()) <= indent:
        break
    body.append(l)
open(sys.argv[3], "w").write(textwrap.dedent("\n".join(body)) + "\n")
PY
}

lift_run "$ISSUE_WF" "Resolve model + turn budget" "$TMP/budget-issue.sh"
lift_run "$REVISE_WF" "Resolve model + turn budget" "$TMP/budget-revise.sh"
for f in "$TMP/budget-issue.sh" "$TMP/budget-revise.sh"; do
  [ -s "$f" ] || { echo "NOT OK - could not lift the budget step into $f"; exit 1; }
done

# Runs a lifted budget script; sets LOG (stdout+stderr) and OUT (the step outputs).
# Extra env assignments are passed as arguments.
run_budget() {  # run_budget <script> [VAR=value ...]
  local script="$1"; shift
  : > "$TMP/github_output"
  LOG="$(env GITHUB_OUTPUT="$TMP/github_output" \
             DEFAULT_MODEL=sonnet DEFAULT_TURNS=100 \
             EVENT_NAME=issues COMMENT_BODY="" ISSUE_BODY="" BODY="" \
             "$@" bash "$script" 2>&1)"
  RC=$?
  OUT="$(cat "$TMP/github_output")"
}

# The value of one step output.
outval() { printf '%s\n' "$OUT" | sed -nE "s/^$1=(.*)/\1/p" | head -1; }

# ------------------------------------------------- 1. the warning (both workflows)

for wf in issue revise; do
  SCRIPT="$TMP/budget-$wf.sh"
  # The issue workflow picks the body by event; the revise one reads $BODY.
  if [ "$wf" = issue ]; then BODYVAR=ISSUE_BODY; else BODYVAR=BODY; fi

  CASE="$wf: a misspelt key warns and names the nearest directive"
  run_budget "$SCRIPT" "$BODYVAR=$(printf 'Please do the thing.\n\nagent-tuns: 150\n')"
  [ "$RC" = 0 ] && ok "the step still succeeds" || notok "exit 0 (rc=$RC)" "$LOG"
  case "$LOG" in
    *"::warning::unknown directive 'agent-tuns' -- did you mean agent-turns?"*)
      ok "warns, naming agent-turns" ;;
    *) notok "the typo warning" "$LOG" ;;
  esac
  [ "$(outval turns)" = 100 ] && ok "and the run uses the default budget" \
    || notok "turns=100" "$(outval turns)"
  [ "$(outval unknown_directive)" = "agent-tuns: 150" ] \
    && ok "the directive as written is carried out for the comment" \
    || notok "unknown_directive=agent-tuns: 150" "$(outval unknown_directive)"
  [ "$(outval unknown_suggestion)" = "agent-turns" ] \
    && ok "with the suggestion" || notok "unknown_suggestion=agent-turns" "$(outval unknown_suggestion)"

  CASE="$wf: the correctly spelt directive is silent and still applies"
  run_budget "$SCRIPT" "$BODYVAR=$(printf 'Please do the thing.\n\nagent-turns: 150\n')"
  case "$LOG" in
    *"unknown directive"*) notok "no warning for a real directive" "$LOG" ;;
    *) ok "no warning" ;;
  esac
  [ "$(outval turns)" = 150 ] && ok "and 150 turns are granted" \
    || notok "turns=150" "$(outval turns)"
  [ -z "$(outval unknown_directive)" ] && ok "nothing carried to the comment" \
    || notok "unknown_directive empty" "$(outval unknown_directive)"

  CASE="$wf: a misspelt agent-model is caught the same way"
  run_budget "$SCRIPT" "$BODYVAR=$(printf 'agent-mdoel: haiku\n')"
  case "$LOG" in
    *"unknown directive 'agent-mdoel' -- did you mean agent-model?"*) ok "warns" ;;
    *) notok "the agent-model typo warning" "$LOG" ;;
  esac
  [ "$(outval model)" = claude-sonnet-5 ] && ok "and the default model is kept" \
    || notok "model=claude-sonnet-5" "$(outval model)"

  CASE="$wf: a key nowhere near a directive lists the known ones"
  run_budget "$SCRIPT" "$BODYVAR=$(printf 'agent-deployment-notes: see below\n')"
  case "$LOG" in
    *"unknown directive 'agent-deployment-notes' -- known directives: agent-model agent-turns"*)
      ok "warns with the list rather than a bogus suggestion" ;;
    *) notok "the known-directives warning" "$LOG" ;;
  esac

  CASE="$wf: the quoting forms that cannot request a directive cannot warn either"
  run_budget "$SCRIPT" "$BODYVAR=$(printf 'Docs:\n\n```\nagent-tuns: 150\n```\n\n> agent-tuns: 150\n\n    agent-tuns: 150\n\n- agent-tuns: 150\n')"
  case "$LOG" in
    *"unknown directive"*) notok "a fenced, quoted, indented or listed key must stay quiet" "$LOG" ;;
    *) ok "no warning for fenced, blockquoted, indented or list text" ;;
  esac

  CASE="$wf: the same typo twice warns once"
  run_budget "$SCRIPT" "$BODYVAR=$(printf 'agent-tuns: 150\nagent-tuns: 150\n')"
  n="$(printf '%s\n' "$LOG" | grep -c "unknown directive 'agent-tuns'")"
  [ "$n" = 1 ] && ok "one warning" || notok "exactly one warning" "$n"

  CASE="$wf: a body with no directive at all is unchanged"
  run_budget "$SCRIPT" "$BODYVAR=$(printf 'Fix the null pointer in the data loader.\n')"
  [ "$RC" = 0 ] && ok "the step succeeds" || notok "exit 0 (rc=$RC)" "$LOG"
  case "$LOG" in
    *"unknown directive"*) notok "nothing to warn about" "$LOG" ;;
    *) ok "no warning" ;;
  esac
  [ "$(outval turns)" = 100 ] && ok "repo defaults" || notok "turns=100" "$(outval turns)"
done

CASE="the /agent one-liner is parsed for typos too"
# The verb is stripped before parsing, so `/agent agent-tuns: 150` must warn -- that
# one-liner is the form dev-common#143 added and the form a typo arrives in.
run_budget "$TMP/budget-issue.sh" EVENT_NAME=issue_comment \
  "COMMENT_BODY=$(printf '/agent agent-tuns: 150\n')"
case "$LOG" in
  *"unknown directive 'agent-tuns' -- did you mean agent-turns?"*) ok "warns" ;;
  *) notok "the typo warning on the comment path" "$LOG" ;;
esac

CASE="the check is the SAME in both workflows"
# The two budget steps are duplicated by design (dev-common#142: no composite action),
# so this block drifts silently unless something compares them.
for f in "$TMP/budget-issue.sh" "$TMP/budget-revise.sh"; do
  awk '/^KNOWN_DIRECTIVES=/{p=1} /^# Allowlist \+ clamp\./{p=0} p' "$f" > "$f.block"
done
[ -s "$TMP/budget-issue.sh.block" ] && ok "the block is findable in agent-issue-to-pr.yml" \
  || notok "could not isolate the unknown-directive block"
diff -u "$TMP/budget-issue.sh.block" "$TMP/budget-revise.sh.block" > "$TMP/blockdiff" \
  && ok "byte-identical in agent-pr-revise.yml" \
  || notok "the two copies have drifted" "$(cat "$TMP/blockdiff")"

CASE="the typo reaches the step that comments"
# A rename on either side silently restores the old comment, which is the whole bug.
# On the issue path the comment is written by agent-report-outcome.sh (shipped from
# home-infra, bdh-org/home-infra#1477), so the wiring is all this repo can assert.
for v in unknown_directive unknown_suggestion; do
  grep -q "steps.budget.outputs.$v" "$ISSUE_WF" \
    && ok "agent-issue-to-pr.yml hands the reporter steps.budget.outputs.$v" \
    || notok "the reporter step must get steps.budget.outputs.$v"
  grep -q "steps.budget.outputs.$v" "$REVISE_WF" \
    && ok "agent-pr-revise.yml hands the verify step steps.budget.outputs.$v" \
    || notok "the verify step must get steps.budget.outputs.$v"
done

# ------------------------------------------- 2. the comment (agent-pr-revise.yml)

lift_run_python() {  # lift_run_python <workflow> <step name> <outfile>
  lift_run "$1" "$2" "$3.sh"
  python3 - "$3.sh" "$3" <<'PY'
import sys, textwrap
lines = open(sys.argv[1]).read().splitlines()
i = next(i for i, l in enumerate(lines) if l.strip().startswith("python3 - <<'PY'"))
body = []
for l in lines[i + 1:]:
    if l.strip() == "PY":
        break
    body.append(l)
src = textwrap.dedent("\n".join(body)) + "\n"
# The 10s re-poll for a push that trails the API is real behaviour and is not what
# this test is about; it would add 10s per case.
src = src.replace("time.sleep(10)", "time.sleep(0)")
open(sys.argv[2], "w").write(src)
PY
}

lift_run_python "$REVISE_WF" "Verify the revision pushed" "$TMP/verify.py"
[ -s "$TMP/verify.py" ] || { echo "NOT OK - could not lift the verify step"; exit 1; }

cat > "$TMP/stub.py" <<'PY'
"""GET pulls/<n> -> a PR whose head is still $SHA (i.e. nothing was pushed)."""
import json, os
from http.server import BaseHTTPRequestHandler, HTTPServer

class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_GET(self):
        b = json.dumps({"head": {"sha": os.environ["SHA"]},
                        "html_url": "https://github.com/o/r/pull/7"}).encode()
        self.send_response(200); self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(b))); self.end_headers()
        self.wfile.write(b)

srv = HTTPServer(("127.0.0.1", 0), H)
open(os.environ["PORTFILE"], "w").write(str(srv.server_address[1]))
srv.serve_forever()
PY

SHA=1234567890abcdef1234567890abcdef12345678
rm -f "$TMP/port"
SHA="$SHA" PORTFILE="$TMP/port" python3 "$TMP/stub.py" & PID=$!
for _ in $(seq 1 100); do [ -s "$TMP/port" ] && break; sleep 0.05; done
[ -s "$TMP/port" ] || { echo "NOT OK - the API stub never came up"; exit 1; }

# The agent's own account of why it stopped: out of turns.
printf '%s\n' '{"type": "result", "subtype": "error_max_turns", "num_turns": 100}' \
  > "$TMP/execution.json"

run_verify() {  # run_verify [VAR=value ...]
  VOUT="$(env GITHUB_API_URL="http://127.0.0.1:$(cat "$TMP/port")" GH_TOKEN=stub \
              REPO=o/r PR=7 REF=agent/issue-1 BEFORE="$SHA" \
              AGENT_OUTCOME=failure AGENT_CONCLUSION="" \
              EXECUTION_FILE="$TMP/execution.json" MAX_TURNS=100 \
              GITHUB_STEP_SUMMARY="$TMP/summary" \
              UNKNOWN_DIRECTIVE="" UNKNOWN_SUGGESTION="" \
              "$@" python3 "$TMP/verify.py" 2>&1)"
  VRC=$?
}

CASE="out of turns WITH a misspelt directive: the comment says so first"
run_verify "UNKNOWN_DIRECTIVE=agent-tuns: 150" UNKNOWN_SUGGESTION=agent-turns
[ "$VRC" = 1 ] && ok "still red" || notok "exit 1 (rc=$VRC)" "$VOUT"
case "$VOUT" in
  *'your /revise comment says `agent-tuns: 150`, but the key is `agent-turns`'*)
    ok "names the key as written and the key it should be" ;;
  *) notok "the typo sentence" "$VOUT" ;;
esac
case "$VOUT" in
  *"used the default budget of 100 turns"*) ok "and that the default was used" ;;
  *) notok "the default-budget sentence" "$VOUT" ;;
esac
# The typo precedes the advice: "put agent-turns: 150 on its own line" is what read as
# nonsense to a reader whose comment appeared to say exactly that.
python3 - "$VOUT" <<'PY' && ok "before the re-request advice" || notok "the typo must come first" "$VOUT"
import sys
out = sys.argv[1]
raise SystemExit(0 if out.index("agent-tuns") < out.index("re-request with") else 1)
PY

CASE="out of turns with no typo: the message is unchanged"
run_verify
[ "$VRC" = 1 ] && ok "still red" || notok "exit 1 (rc=$VRC)" "$VOUT"
case "$VOUT" in
  *"the key is"*) notok "nothing to correct" "$VOUT" ;;
  *) ok "no typo sentence" ;;
esac
case "$VOUT" in
  *"the agent ran out of turns (100 of 100) before it pushed"*) ok "the budget diagnosis" ;;
  *) notok "the out-of-turns message" "$VOUT" ;;
esac

echo
echo "agent-directive-typo: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
