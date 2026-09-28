#!/usr/bin/env bash
# claude-install-lock.test.sh -- the gate for .github/actions/claude-install-lock
# (bdh-org/home-infra#541).
#
# That action decides whether two agent runs on one forge host install the
# Claude Code CLI at the same time. When they do, both die -- "Checksum
# verification failed", then ETXTBSY / exit 126 -- and neither failure mentions
# the issue being worked, so the run reads as an unrelated infrastructure blip.
#
# The properties worth asserting are the ones a careless rewrite would break:
#
#   - a held lock actually BLOCKS (a lock that never blocks is decoration, and
#     would go green while the race continued);
#   - a lock whose holder was killed is eventually STOLEN (otherwise one hard
#     kill wedges the whole fleet's agent pipeline, permanently, silently);
#   - a stolen lock is NOT released by its original holder returning late --
#     that would put two runs back inside the lock, i.e. this bug again but
#     harder to see;
#   - both agent workflows actually CALL it, in the right order. The logic can
#     be perfect and do nothing at all if the wiring is missing, which is the
#     "green audit, nothing running" shape home-infra#541 itself was found in.
#
# Usage:  bash tests/claude-install-lock.test.sh      (or: make test)

set -uo pipefail   # deliberately NOT -e: every case runs, then we report

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOCK_SH="$REPO_ROOT/.github/actions/claude-install-lock/lock.sh"
ACTION_YML="$REPO_ROOT/.github/actions/claude-install-lock/action.yml"
WF_ISSUE="$REPO_ROOT/.github/workflows/agent-issue-to-pr.yml"
WF_REVISE="$REPO_ROOT/.github/workflows/agent-pr-revise.yml"

pass=0
fail=0
CASE="(none)"

# --- harness ---------------------------------------------------------------

ok()    { pass=$((pass + 1)); printf 'ok     - %s: %s\n' "$CASE" "$1"; }
notok() { fail=$((fail + 1)); printf 'NOT OK - %s: %s\n' "$CASE" "$1"; }

assert_eq() { # want got description
  if [ "$1" = "$2" ]; then ok "$3"; else
    notok "$3"; printf '         want: %s\n         got:  %s\n' "$1" "$2"
  fi
}

assert_contains() { # haystack needle description
  case "$1" in *"$2"*) ok "$3";; *) notok "$3 (no '$2' in output)";; esac
}

assert_absent() { # haystack needle description
  case "$1" in *"$2"*) notok "$3 (found '$2')";; *) ok "$3";; esac
}

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

LOCK="$TMP/install.lock.d"

# Run lock.sh with a throwaway lock dir and impatient timings, so the whole
# suite stays sub-second. The defaults it ships with (20min wait, 15min stale)
# are for a real forge run and would make this test useless as a gate. The
# shipped values are asserted separately, below, as an ORDERING.
run_lock() { # mode owner [extra env assignments...]
  local mode="$1" owner="$2"; shift 2
  env LOCK_MODE="$mode" LOCK_OWNER="$owner" LOCK_DIR="$LOCK" \
      LOCK_WAIT_SECONDS=1 LOCK_STALE_SECONDS=3600 LOCK_POLL_SECONDS=1 \
      "$@" bash "$LOCK_SH" 2>&1
}

# --- the script exists and is sane -----------------------------------------

CASE="script"
if [ -f "$LOCK_SH" ]; then ok "lock.sh exists"; else notok "lock.sh is missing at $LOCK_SH"; fi
if bash -n "$LOCK_SH" 2>/dev/null; then ok "lock.sh parses"; else notok "lock.sh has a syntax error"; fi
if [ -f "$ACTION_YML" ]; then ok "action.yml exists"; else notok "action.yml is missing"; fi

# --- acquire / release round trip ------------------------------------------

CASE="acquire"
out="$(run_lock acquire "run-1")"
assert_eq "0" "$?" "acquiring a free lock succeeds"
assert_contains "$out" "acquired" "says it acquired"
if [ -d "$LOCK" ]; then ok "the lock directory now exists"; else notok "no lock directory was created"; fi
assert_eq "run-1" "$(cat "$LOCK/owner" 2>/dev/null)" "records the owner, so a waiter can name who holds it"

CASE="contention"
# THE load-bearing case: while run-1 holds it, run-2 must NOT get in.
out="$(run_lock acquire "run-2")"; rc=$?
assert_eq "1" "$rc" "a second acquire fails rather than proceeding into the install"
assert_contains "$out" "gave up after" "says it timed out"
assert_contains "$out" "run-1" "names the run that is holding the lock"
assert_contains "$out" "::error::" "annotates the timeout for the GitHub UI"
assert_eq "run-1" "$(cat "$LOCK/owner" 2>/dev/null)" "and the loser does not clobber the holder's owner file"

CASE="release"
out="$(run_lock release "run-1")"
assert_eq "0" "$?" "the owner can release"
assert_contains "$out" "released" "says it released"
if [ -d "$LOCK" ]; then notok "the lock directory survived its own release"; else ok "the lock directory is gone"; fi

CASE="re-acquire"
out="$(run_lock acquire "run-2")"
assert_eq "0" "$?" "the next run can acquire once the lock is released"
assert_eq "run-2" "$(cat "$LOCK/owner" 2>/dev/null)" "and takes ownership"

# --- a killed job must not wedge the pipeline ------------------------------

CASE="stale"
# Backdate the owner file to simulate a job killed hours ago without releasing.
touch -d "2 hours ago" "$LOCK/owner" 2>/dev/null || touch -t 200001010000 "$LOCK/owner"
out="$(env LOCK_MODE=acquire LOCK_OWNER="run-3" LOCK_DIR="$LOCK" \
        LOCK_WAIT_SECONDS=1 LOCK_STALE_SECONDS=60 LOCK_POLL_SECONDS=1 \
        bash "$LOCK_SH" 2>&1)"
assert_eq "0" "$?" "a lock older than the stale window is taken, not waited on forever"
assert_contains "$out" "stealing a stale lock" "says it stole it"
assert_contains "$out" "::warning::" "and warns, because a steal means a job died"
assert_eq "run-3" "$(cat "$LOCK/owner" 2>/dev/null)" "the thief becomes the owner"

CASE="stolen-release"
# run-2 comes back from the dead and tries to release. It must NOT, or run-3
# and whoever acquires next would both be inside the lock.
out="$(run_lock release "run-2")"
assert_eq "0" "$?" "a late release by the dispossessed holder is not an error"
assert_contains "$out" "NOT releasing" "refuses to release a lock it no longer owns"
assert_contains "$out" "::warning::" "and warns about it"
assert_eq "run-3" "$(cat "$LOCK/owner" 2>/dev/null)" "the real holder keeps the lock"

CASE="release-idempotent"
out="$(run_lock release "run-3")"
assert_eq "0" "$?" "run-3 releases its own lock"
out="$(run_lock release "run-3")"
assert_eq "0" "$?" "releasing an absent lock is a no-op, not a failure"
assert_contains "$out" "nothing to release" "and says so"

# --- misuse ----------------------------------------------------------------

CASE="misuse"
out="$(env LOCK_MODE=wat LOCK_OWNER=x LOCK_DIR="$LOCK" bash "$LOCK_SH" 2>&1)"
assert_eq "1" "$?" "an unknown mode fails"
assert_contains "$out" "must be 'acquire' or 'release'" "and says what the valid modes are"

out="$(env LOCK_MODE=acquire LOCK_DIR="$LOCK" bash "$LOCK_SH" 2>&1)"
assert_eq "1" "$?" "acquire without an owner fails"
assert_contains "$out" "LOCK_OWNER" "and names what was missing"

# --- the wiring, which is the half that silently does nothing --------------
#
# Since bdh-org/home-infra#881 the lock is taken by the claude-code-install
# action around the install ALONE, and claude-code-action is handed the binary
# it produced. The wiring that matters is therefore:
#
#   - the install step exists and runs BEFORE claude-code-action;
#   - claude-code-action is given its path, so it does not install again --
#     unlocked, inside its own long step, which would be #541 back;
#   - nothing acquires the lock across the agent step any more (that is what
#     serialised the fleet to one agent at a time);
#   - the agent's GitHub token is minted AFTER the install, so no wait before it
#     can age the token past its 60 minutes (bdh-org/dev-common#257).

for wf in "$WF_ISSUE" "$WF_REVISE"; do
  CASE="wiring $(basename "$wf")"
  if [ ! -f "$wf" ]; then notok "workflow is missing at $wf"; continue; fi
  body="$(cat "$wf")"
  assert_contains "$body" "claude-code-install@main" "calls the install action"
  assert_contains "$body" 'path_to_claude_code_executable: ${{ steps.claude_cli.outputs.path }}' \
    "hands claude-code-action the installed binary, so it skips its own unlocked install"
  assert_absent "$body" "mode: acquire" "does not hold the lock across the agent step"

  inst=$(grep -n "uses: bdh-org/dev-common/.github/actions/claude-code-install@main" "$wf" | head -1 | cut -d: -f1)
  act=$(grep -n "uses: anthropics/claude-code-action" "$wf" | head -1 | cut -d: -f1)
  if [ -n "$inst" ] && [ -n "$act" ] && [ "$inst" -lt "$act" ]; then
    ok "installs BEFORE claude-code-action"
  else
    notok "install is not before claude-code-action (install=$inst action=$act)"
  fi
  inst_id=$(grep -n "id: claude_cli" "$wf" | head -1 | cut -d: -f1)
  if [ -n "$inst_id" ] && [ -n "$inst" ] && [ "$inst_id" -lt "$inst" ] && [ $(( inst - inst_id )) -le 4 ]; then
    ok "the install step carries id claude_cli, which the action's path refers to"
  else
    notok "no 'id: claude_cli' on the install step (id=$inst_id uses=$inst)"
  fi

  # The token the agent uses must come from a mint that runs after the install,
  # i.e. after anything that can wait.
  mint=$(grep -n "id: coder_agent" "$wf" | head -1 | cut -d: -f1)
  if [ -n "$mint" ] && [ -n "$inst" ] && [ -n "$act" ] && [ "$mint" -gt "$inst" ] && [ "$mint" -lt "$act" ]; then
    ok "mints the agent's token between the install and the agent (dev-common#257)"
  else
    notok "the agent's token mint is not between install and agent (install=$inst mint=$mint action=$act)"
  fi
  act_block="$(sed -n "${act:-1},\$p" "$wf" | head -60)"
  assert_contains "$act_block" 'github_token: ${{ steps.coder_agent.outputs.coder_token }}' \
    "claude-code-action gets the freshly minted token"
  assert_contains "$act_block" 'GH_TOKEN: ${{ steps.coder_agent.outputs.coder_token }}' \
    "and so does the agent's own shell"
  assert_absent "$act_block" 'steps.coder.outputs.coder_token' \
    "and never the job-start token"
done

# --- the ordering invariant: install step timeout < stale < wait ------------
#
# These numbers are only correct as a SET, and the first version had them
# in the wrong order (wait 1500 under stale 3600). Nothing was red: the lock
# worked, the tests passed, and the defect only showed as agent runs failing
# after 25 minutes about issues they had never touched (home-infra#881). So the
# ordering is asserted here rather than left as a comment, and the two places
# the numbers live are checked against each other -- action.yml is what callers
# get, lock.sh's fallback is what a direct `bash lock.sh` gets, and a fix
# applied to one of them only is the drift this suite exists to catch.

CASE="timings"

# First `default:` after an input's key. The descriptions are folded blocks, so
# the value never sits on the key's own line.
yaml_default() { # file key
  awk -v key="$2" '
    $0 ~ "^  " key ":" { found = 1; next }
    found && /^[[:space:]]*default:/ {
      sub(/^[[:space:]]*default:[[:space:]]*/, ""); gsub(/"/, ""); print; exit
    }
    found && /^  [a-z][a-z-]*:/ { exit }
  ' "$1"
}

WAIT_YML="$(yaml_default "$ACTION_YML" wait-seconds)"
STALE_YML="$(yaml_default "$ACTION_YML" stale-seconds)"
WAIT_SH="$(sed -n 's/^WAIT="\${LOCK_WAIT_SECONDS:-\([0-9]*\)}"/\1/p' "$LOCK_SH")"
STALE_SH="$(sed -n 's/^STALE="\${LOCK_STALE_SECONDS:-\([0-9]*\)}"/\1/p' "$LOCK_SH")"

if [ -z "$WAIT_YML" ] || [ -z "$STALE_YML" ] || [ -z "$WAIT_SH" ] || [ -z "$STALE_SH" ]; then
  notok "could not read the shipped timings (yml: '$WAIT_YML'/'$STALE_YML', sh: '$WAIT_SH'/'$STALE_SH')"
else
  ok "read the shipped timings"
  assert_eq "$WAIT_YML" "$WAIT_SH" "action.yml and lock.sh agree on the wait default"
  assert_eq "$STALE_YML" "$STALE_SH" "action.yml and lock.sh agree on the stale default"

  # THE load-bearing one. With wait <= stale a waiter can only reach the steal
  # path by arriving when the lock is already (stale - wait) seconds old, so the
  # ordinary arrival times out instead -- the stale case becomes decoration.
  if [ "$WAIT_YML" -gt "$STALE_YML" ]; then
    ok "wait ($WAIT_YML) is above stale ($STALE_YML), so a waiter can reach the steal path"
  else
    notok "wait ($WAIT_YML) must exceed stale ($STALE_YML) or a waiter dies before it can steal"
  fi
fi

# The holder of the lock is now the install step, so ITS timeout is the first
# term of the ordering: a hung install is killed (its EXIT trap releases) well
# before the lock goes stale, and a slow-but-alive one is never stolen from.
# No step timeout would mean the job's 90 minutes, far above the stale window.
for wf in "$WF_ISSUE" "$WF_REVISE"; do
  CASE="timings $(basename "$wf")"
  if [ ! -f "$wf" ]; then notok "workflow is missing at $wf"; continue; fi
  inst=$(grep -n "uses: bdh-org/dev-common/.github/actions/claude-code-install@main" "$wf" | head -1 | cut -d: -f1)
  name=$(grep -n "name: Install Claude Code" "$wf" | head -1 | cut -d: -f1)
  tmo=""
  if [ -n "$inst" ] && [ -n "$name" ]; then
    tmo="$(sed -n "${name},${inst}p" "$wf" | sed -n 's/^[[:space:]]*timeout-minutes:[[:space:]]*\([0-9]*\).*/\1/p' | head -1)"
  fi
  if [ -z "$tmo" ]; then
    notok "the install step sets no timeout-minutes, so it can hold the lock for the whole job"
  else
    ok "the install step bounds its own hold (${tmo}m)"
    if [ -n "${STALE_YML:-}" ] && [ "$(( tmo * 60 ))" -lt "$STALE_YML" ]; then
      ok "that timeout (${tmo}m) is below the steal window (${STALE_YML}s)"
    else
      notok "timeout ${tmo}m must be below stale ${STALE_YML:-?}s, or a live holder gets stolen from"
    fi
  fi
  jt="$(sed -n 's/^    timeout-minutes:[[:space:]]*\([0-9]*\).*/\1/p' "$wf" | head -1)"
  if [ -n "$jt" ]; then ok "the agent job still bounds its runtime (${jt}m)"; else notok "the agent job sets no timeout-minutes (GitHub's 6h default)"; fi
done

# --- report -----------------------------------------------------------------

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
