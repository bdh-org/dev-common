#!/usr/bin/env bash
# agent-ci-env-wiring.test.sh -- the agent can lint and test its own edits
# (bdh-org/dev-common#314).
#
# Both writing workflows (agent-issue-to-pr, agent-pr-revise) locate the repo's
# self-hosted-ci conda env in a `cienv` step and hand it to the agent step ALONE, as
# CONDA_PREFIX -- which every repo Makefile's `CONDA_PREFIX ?=` defers to, so `make lint`
# and `make test` resolve there. The step id, its outputs and the agent's env are wired
# independently, so a rename on one side silently puts the agent back on the
# devcontainer default (/home/vscode/miniforge3/bin/ruff: No such file), which is the
# failure this exists for. Also pins that the prompt forbids installing into the env
# (CI owns it; conda is unsafe under concurrent writers), and that the prompt's bump
# rule is semver, not "ALWAYS bump-patch". Plain text checks: no YAML library assumed.
#
# Usage:  bash tests/agent-ci-env-wiring.test.sh      (or: make test)

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

pass=0
fail=0
ok()    { pass=$((pass + 1)); printf 'ok     - %s\n' "$1"; }
notok() { fail=$((fail + 1)); printf 'NOT OK - %s\n' "$1"; }

for name in agent-issue-to-pr agent-pr-revise; do
  WF="$REPO_ROOT/.github/workflows/$name.yml"

  # The env assignments of the agent step only (from its `uses:` to the next step).
  agent_env="$(awk '
    /^      - uses: anthropics\/claude-code-action/ { in_agent = 1; next }
    in_agent && /^      - (name|uses):/ { in_agent = 0 }
    in_agent { print }
  ' "$WF")"

  grep -q '^        id: cienv$' "$WF" && ok "$name: has the cienv step" || notok "$name: has the cienv step"
  grep -q 'echo "prefix=' "$WF" && grep -q 'echo "status=' "$WF" \
    && ok "$name: cienv writes prefix and status" || notok "$name: cienv writes prefix and status"
  printf '%s\n' "$agent_env" | grep -q 'CONDA_PREFIX: ${{ steps.cienv.outputs.prefix }}' \
    && ok "$name: the agent step gets CONDA_PREFIX from cienv" || notok "$name: the agent step gets CONDA_PREFIX from cienv"
  printf '%s\n' "$agent_env" | grep -q 'AGENT_CI_ENV: ${{ steps.cienv.outputs.status }}' \
    && ok "$name: and AGENT_CI_ENV, the status the prompt names" || notok "$name: AGENT_CI_ENV from cienv"

  # Scoped to the agent step: no OTHER step may carry it, or that step's python moves too.
  others="$(grep -c 'steps.cienv.outputs.prefix' "$WF")"
  [ "$others" = 1 ] && ok "$name: CONDA_PREFIX reaches no other step" || notok "$name: steps.cienv.outputs.prefix used $others times"

  grep -q '`make lint` and `make test`' "$WF" && ok "$name: the prompt asks for lint AND test" || notok "$name: the prompt asks for lint and test"
  grep -q 'NEVER `pip install` or `conda' "$WF" && ok "$name: the prompt forbids installing into the env" || notok "$name: the prompt forbids installing"
  grep -q 'AGENT_CI_ENV is$' "$WF" || grep -q 'If AGENT_CI_ENV is' "$WF" \
    && ok "$name: the prompt says what to do when the env is missing" || notok "$name: the prompt covers a missing env"
  grep -q 'ALWAYS use `make bump-patch`' "$WF" \
    && notok "$name: the prompt still says ALWAYS bump-patch" || ok "$name: the bump rule is not 'ALWAYS patch'"
  grep -q '`make bump-minor` for' "$WF" && ok "$name: and names bump-minor for new capability" || notok "$name: names bump-minor"
done

echo
echo "agent-ci-env-wiring: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
