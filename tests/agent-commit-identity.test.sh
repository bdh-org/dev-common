#!/usr/bin/env bash
# agent-commit-identity.test.sh -- the agent workflows must name the identity their
# commits are attributed to, and must not fall back to the action's default
# (bdh-org/home-infra#875).
#
# WHY THIS EXISTS
#
#   anthropics/claude-code-action writes the checkout's git identity from its `bot_id`
#   and `bot_name` inputs, and its DEFAULT bot_id is 41898282. That is
#   `github-actions[bot]`, not anything Claude-shaped -- the default pairs it with the
#   display name `claude[bot]`, and GitHub keys attribution on the NUMBER. So with the
#   inputs unset, every agent commit in the fleet is credited to CI.
#
#   71 commits across 12 repos landed that way before anyone looked, and nothing was
#   red: the commits are fine, the PRs are fine, and the only symptom is an avatar in a
#   web UI. That is precisely why it needs a test rather than a comment -- there is no
#   failing behaviour to notice, so a future edit that drops these two lines would be
#   invisible until someone re-measured months later.
#
#   Upstream has had the bug on file since 2025-12-20
#   (anthropics/claude-code-action#759) and contradicts itself about the value, so the
#   defaults cannot be relied on to become correct. Setting them explicitly also means
#   an upstream fix cannot silently MOVE our attribution either.
#
# WHAT IT DOES NOT CHECK
#   That GitHub actually renders the attribution -- that needs a real run. This asserts
#   the input is present, correct, and in the right block, which is the half a diff can
#   see.
#
# Usage:  bash tests/agent-commit-identity.test.sh      (or: make test)
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WF_ISSUE="$ROOT/.github/workflows/agent-issue-to-pr.yml"
WF_REVISE="$ROOT/.github/workflows/agent-pr-revise.yml"

# The App whose installation token checks out, pushes the branch and opens the PR.
WANT_ID="305014630"
WANT_NAME="bdh-org-coder[bot]"
# The action's default, and the reason this file exists. Never ours.
CI_BOT_ID="41898282"

pass=0; fail=0
ok()    { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad()   { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; [ $# -gt 1 ] && printf '       %s\n' "$2"; }

for wf in "$WF_ISSUE" "$WF_REVISE"; do
  n="$(basename "$wf")"
  if [ ! -f "$wf" ]; then bad "$n exists" "not found at $wf"; continue; fi

  # Take the claude-code-action step only: from its `uses:` line to the next step at
  # the same indent. A bot_id sitting anywhere else in the file would be inert, so
  # asserting on the whole file would pass a broken wiring.
  step="$(awk '
    /^      - uses: anthropics\/claude-code-action/ { inblock=1; print; next }
    inblock && /^      - / { exit }
    inblock { print }
  ' "$wf")"

  if [ -z "$step" ]; then
    bad "$n calls anthropics/claude-code-action" "no such step -- has the pin or indentation changed?"
    continue
  fi
  ok "$n calls anthropics/claude-code-action"

  got_id="$(sed -n 's/^ *bot_id: *"\{0,1\}\([0-9]*\)"\{0,1\} *$/\1/p' <<<"$step" | head -1)"
  got_name="$(sed -n 's/^ *bot_name: *"\{0,1\}\(.*[^"]\)"\{0,1\} *$/\1/p' <<<"$step" | head -1)"

  if [ -z "$got_id" ]; then
    bad "$n sets bot_id" "unset, so the action defaults to ${CI_BOT_ID} = github-actions[bot] and every agent commit is credited to CI"
  elif [ "$got_id" = "$CI_BOT_ID" ]; then
    bad "$n sets bot_id" "set to ${CI_BOT_ID}, which is github-actions[bot] -- the default this test exists to prevent"
  elif [ "$got_id" != "$WANT_ID" ]; then
    bad "$n sets bot_id to ${WANT_ID}" "found ${got_id}; if the acting credential really changed, update WANT_ID here and say so in issues/862-agent-commit-identity.md"
  else
    ok "$n attributes commits to ${WANT_ID}"
  fi

  if [ "$got_name" != "$WANT_NAME" ]; then
    bad "$n sets bot_name to ${WANT_NAME}" "found '${got_name:-<unset>}' -- the noreply address is <id>+<name>@, so a mismatched pair is how #875 happened in the first place"
  else
    ok "$n names ${WANT_NAME}"
  fi
done

echo
if [ "$fail" -eq 0 ]; then
  echo "PASS: ${pass} checks -- both agent workflows attribute commits to ${WANT_NAME}"
else
  {
    echo "FAIL: ${fail} of $((pass+fail)) checks."
    echo
    echo "Both agent workflows must pass these in the claude-code-action \`with:\` block:"
    echo "  bot_id: \"${WANT_ID}\""
    echo "  bot_name: \"${WANT_NAME}\""
  } >&2
  exit 1
fi
