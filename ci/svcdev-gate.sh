#!/usr/bin/env bash
# svcdev-gate.sh — shared svc-dev deploy+smoke gate for the headless agent pipeline.
#
# SHARED, canonical copy (dev-common). Every stack repo's agent workflow calls this
# via the common/ submodule, so the gate logic lives in ONE place (home-infra#42/#53)
# and updates propagate through `update-common`:
#
#   common/ci/svcdev-gate.sh <service> <branch>
#
#   <service>  the repo's compose service (hog, oleo, ...). "" or "home-site" =>
#              whole-stack deploy with no per-service checkout move (home-site's own
#              workflow). Any other value is passed to `claude-dev deploy <ref> <svc>`,
#              which moves THAT service's svc-dev checkout to the branch and rebuilds
#              the tier -- so a service-repo PR is what gets built + smoked.
#   <branch>   the PR branch to test (e.g. agent/issue-42).
#
# What it does (mirrors home-site's original inline gate): resolve the PR head SHA,
# set a `svc-dev gate (deploy+smoke)` commit status = pending, SSH the claude-dev
# deploy verb to twix, run smoke-dev.sh (its sibling), then set the status
# success/failure and -- on failure -- comment the smoke tail ON the PR. Exits
# non-zero on a red gate so the job (and any auto-merge step) fails.
#
# Env:
#   GH_TOKEN        github.token -- for the commit status + PR comment (needs
#                   contents:read, statuses:write, pull-requests:write).
#   KEY_B64         base64 of the claude-dev SSH private key (a prior workflow step
#                   fetches it from Vault kv/ai/coder/claude-dev-ssh).
#   CLAUDE_DEV_SSH  ssh target for the forced-command verb (default claude@twix).
#   GITHUB_REPOSITORY / GITHUB_SERVER_URL / GITHUB_RUN_ID  provided by Actions.
#
# Runs on the forge runner inside the agent workflow, AFTER claude-code-action has
# opened the PR (so the verdict lands on it). bash -n clean; no secrets in argv.
set -uo pipefail   # NOT -e: capture the gate result, then report it before exiting

SVC="${1:-}"
BRANCH="${2:?usage: svcdev-gate.sh <service> <branch>}"
REPO="${GITHUB_REPOSITORY:?GITHUB_REPOSITORY unset (run inside GitHub Actions)}"
TARGET="${CLAUDE_DEV_SSH:-claude@twix}"
RUN_URL="${GITHUB_SERVER_URL:-https://github.com}/${REPO}/actions/runs/${GITHUB_RUN_ID:-}"
HERE="$(cd "$(dirname "$0")" && pwd)"

KEY="$(mktemp)"; LOG="$(mktemp)"; trap 'rm -f "$KEY" "$LOG"' EXIT
printf '%s' "${KEY_B64:?KEY_B64 unset (fetch the claude-dev key from Vault first)}" | base64 -d > "$KEY"
chmod 600 "$KEY"

# PR head SHA = tip of the agent's branch (the job checked out the default branch).
SHA="$(gh api "repos/${REPO}/commits/${BRANCH}" -q .sha 2>/dev/null || true)"
set_status() {  # <state> <description>
  [ -n "${SHA:-}" ] || return 0
  gh api -X POST "repos/${REPO}/statuses/${SHA}" \
    -f state="$1" -f context="svc-dev gate (deploy+smoke)" \
    -f description="$2" -f target_url="${RUN_URL}" >/dev/null || true
}

# Service arg for the deploy verb: home-site (or empty) => whole-stack, no per-svc move.
DEPLOY_SVC=""
case "$SVC" in ""|home-site) ;; *) DEPLOY_SVC="$SVC" ;; esac

set_status pending "deploying ${BRANCH}${DEPLOY_SVC:+ (${DEPLOY_SVC})} to svc-dev + smoke"
echo "==> svc-dev gate: deploy ${BRANCH} ${DEPLOY_SVC:-<whole-stack>} via ${TARGET}, then smoke"
if { ssh -i "$KEY" -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new \
       "$TARGET" deploy "$BRANCH" $DEPLOY_SVC && "${HERE}/smoke-dev.sh"; } 2>&1 | tee "$LOG"; then
  set_status success "svc-dev deploy + smoke passed"
else
  set_status failure "svc-dev deploy or smoke FAILED"
  { echo "### svc-dev gate: FAILED"; echo
    echo "Deploy-to-svc-dev + smoke did not pass. [Full run](${RUN_URL})."; echo
    echo '```'; tail -n 30 "$LOG"; echo '```'
  } | gh pr comment "$BRANCH" --body-file - || true
  exit 1
fi
