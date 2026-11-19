#!/usr/bin/env bash
# hosted-minutes.test.sh -- the two jobs that were spending finzeug's hosted Actions
# minutes stay cheap (bdh-org/home-infra#1786).
#
# GitHub bills a hosted job at a one-minute floor. In 2026-11 the agent gate (1,552
# min) and version-guard (524 min) were most of finzeug's 2,733 hosted minutes, each
# job doing seconds of work. The fixes are one line each, and a one-line fix is one
# edit away from being undone by someone who reads "ubuntu-latest deliberately" and
# tidies the `if:` away:
#   1. the gate keeps a job-level `if:` prefilter on /agent, so a comment that never
#      mentions the verb starts no runner at all;
#   2. version-guard's job runs on forge, not a hosted runner;
#   3. no other shared workflow names a hosted runner (see the allowlist below).
#
# Usage:  bash tests/hosted-minutes.test.sh      (or: make test)

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ISSUE_WF="$REPO_ROOT/.github/workflows/agent-issue-to-pr.yml"
GUARD_WF="$REPO_ROOT/.github/workflows/version-guard.yml"

fail=0
check() {  # check <description> <command...>
  local d="$1"; shift
  if "$@"; then printf 'ok     - %s\n' "$d"; else printf 'NOT OK - %s\n' "$d"; fail=$((fail + 1)); fi
}

# The lines of one job: from `  <name>:` to the next two-space job key.
job() { awk -v j="  $2:" '$0==j{on=1;print;next} on&&/^  [a-z_-]+:$/{exit} on' "$1"; }

gate="$(job "$ISSUE_WF" gate)"
check "agent-issue-to-pr.yml has a gate job" test -n "$gate"
check "gate is prefiltered on /agent before any runner starts" \
  grep -qF "if: github.event_name != 'issue_comment' || contains(github.event.comment.body, '/agent')" <<<"$gate"

guard="$(job "$GUARD_WF" version-bumped)"
check "version-guard.yml has its version-bumped job" test -n "$guard"
check "version-bumped runs on forge, not a hosted runner" \
  grep -qE '^    runs-on: \[self-hosted, forge\]$' <<<"$guard"

# 3. Every other job runs on forge. A hosted runner is allowed only where it is
#    deliberate and cheap, and each exception is named here with its reason:
#      agent-issue-to-pr.yml  the gate: no runner for most comments (prefilter
#                             above), and a forge slot per comment would queue
#                             every issue comment with deploys (home-infra#426)
#      shell-tests.yml        dev-common's own tests; dev-common is PUBLIC, and
#                             hosted minutes on a public repo are free
#    Any other `ubuntu-latest` is a reusable that every private repo calling it
#    pays for (bdh-org/home-infra#1786).
allowed="agent-issue-to-pr.yml shell-tests.yml"
for wf in "$REPO_ROOT"/.github/workflows/*.yml; do
  name="$(basename "$wf")"
  case " $allowed " in *" $name "*) continue ;; esac
  check "$name names no hosted runner" \
    bash -c '! grep -nE "^\s*runs-on:.*(ubuntu|windows|macos)-" "$1"' _ "$wf"
done

[ "$fail" -eq 0 ] && echo "all passed" || { echo "$fail failed"; exit 1; }
