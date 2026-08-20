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
# suite stays sub-second. The defaults it ships with (25min wait, 1h stale) are
# for a real forge run and would make this test useless as a gate.
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

for wf in "$WF_ISSUE" "$WF_REVISE"; do
  CASE="wiring $(basename "$wf")"
  if [ ! -f "$wf" ]; then notok "workflow is missing at $wf"; continue; fi
  body="$(cat "$wf")"
  assert_contains "$body" "claude-install-lock@main" "calls the lock action"
  assert_contains "$body" "mode: acquire" "acquires"
  assert_contains "$body" "mode: release" "releases"

  # Order matters: acquire ABOVE the action, release BELOW it. A release above
  # the action would free the lock before the install it is protecting.
  acq=$(grep -n "mode: acquire" "$wf" | head -1 | cut -d: -f1)
  act=$(grep -n "uses: anthropics/claude-code-action" "$wf" | head -1 | cut -d: -f1)
  rel=$(grep -n "mode: release" "$wf" | head -1 | cut -d: -f1)
  if [ -n "$acq" ] && [ -n "$act" ] && [ "$acq" -lt "$act" ]; then
    ok "acquires BEFORE claude-code-action"
  else
    notok "acquire is not before claude-code-action (acquire=$acq action=$act)"
  fi
  if [ -n "$rel" ] && [ -n "$act" ] && [ "$rel" -gt "$act" ]; then
    ok "releases AFTER claude-code-action"
  else
    notok "release is not after claude-code-action (release=$rel action=$act)"
  fi

  # The release must be unconditional. Without `if: always()` a failed or
  # cancelled agent run leaves the lock behind, and every later run pays the
  # full stale timeout before it can proceed.
  #
  # Anchor on the step's NAME, not on `mode: release`: `if:` sits above `with:`
  # in a step, so a window opened at the mode line looks past the condition it
  # is checking for and reports a correctly-wired workflow as broken.
  rel_name=$(grep -n "name: Release the Claude Code install lock" "$wf" | head -1 | cut -d: -f1)
  if [ -z "$rel_name" ]; then
    notok "no step named 'Release the Claude Code install lock'"
  else
    rel_block="$(sed -n "${rel_name},\$p" "$wf" | head -8)"
    assert_contains "$rel_block" "always()" "the release runs even when the agent step failed"
  fi
done

# --- report -----------------------------------------------------------------

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
