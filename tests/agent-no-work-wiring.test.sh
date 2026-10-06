#!/usr/bin/env bash
# agent-no-work-wiring.test.sh -- the NO-WORK outcome is wired end to end
# (bdh-org/home-infra#474).
#
# The agent writes its "nothing to build" note to $AGENT_NO_WORK_FILE; the forge reporter
# (home-infra scripts/forge/agent-report-outcome.sh, which has its own behavioural tests)
# reads the same variable and ends a no-push run green with that note on the issue. The
# two steps are configured independently in agent-issue-to-pr.yml, so a rename on one side
# silently turns every NO-WORK run back into a red "no PR". This pins that they agree, and
# that the prompt actually tells the agent about the file. Plain text checks on purpose: no
# YAML library is assumed on the runner.
#
# Usage:  bash tests/agent-no-work-wiring.test.sh      (or: make test)

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WF="$REPO_ROOT/.github/workflows/agent-issue-to-pr.yml"

pass=0
fail=0
ok()    { pass=$((pass + 1)); printf 'ok     - %s\n' "$1"; }
notok() { fail=$((fail + 1)); printf 'NOT OK - %s\n' "$1"; }

# Every `AGENT_NO_WORK_FILE:` env assignment, with the name of the step it sits in.
assignments="$(awk '
  /^      - (name|uses):/ { step = $0 }
  /^      - uses: anthropics\/claude-code-action/ { step = "AGENT-STEP" }
  /^          AGENT_NO_WORK_FILE:/ { sub(/^ *AGENT_NO_WORK_FILE: */, ""); print step " => " $0 }
' "$WF")"

agent_val="$(printf '%s\n' "$assignments" | sed -n 's/^AGENT-STEP => //p')"
report_val="$(printf '%s\n' "$assignments" | sed -n "s/^.*Report the run's outcome.* => //p")"

[ -n "$agent_val" ]  && ok "the agent step names AGENT_NO_WORK_FILE ($agent_val)" || notok "the agent step names AGENT_NO_WORK_FILE"
[ -n "$report_val" ] && ok "the report step names AGENT_NO_WORK_FILE" || notok "the report step names AGENT_NO_WORK_FILE ($assignments)"
[ -n "$agent_val" ] && [ "$agent_val" = "$report_val" ] && ok "and they name the SAME file" \
  || notok "same file (agent='$agent_val' report='$report_val')"
case "$agent_val" in *runner.temp*) ok "outside the checkout, so it can never be committed" ;; *) notok "outside the checkout ($agent_val)" ;; esac
grep -q "file named by the env var" "$WF" && grep -q "^            AGENT_NO_WORK_FILE: what you understood" "$WF" \
  && ok "the prompt tells the agent to write it" || notok "the prompt mentions AGENT_NO_WORK_FILE"
grep -q "when in doubt, implement" "$WF" && ok "and biases the agent towards implementing" || notok "bias towards implementing"

echo
echo "agent-no-work-wiring: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
