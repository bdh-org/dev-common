#!/usr/bin/env bash
# smoke-dev.sh — HTTP smoke checks against a home-site svc-dev tier.
#
# SHARED, canonical copy (dev-common). Consumed by every stack repo's agent
# workflow via the common/ submodule as `common/ci/smoke-dev.sh`, so the smoke
# definition lives in ONE place and updates propagate through `update-common`.
#
# Default target is the svc-dev TEST TIER on twix: one Apache edge on :8080 with
# per-service vhosts selected by the Host header (svc-dev is rootless and can't
# bind :80, see home-infra#42). Run by svcdev-gate.sh after `claude-dev deploy
# <ref> [<svc>]`: exit 0 = green. It verifies each service answers a sane HTTP
# response through the edge; deliberately NOT exhaustive ("smoke").
#
# Usage:
#   common/ci/smoke-dev.sh                    # svc-dev tier (twix:8080, Host <svc>.twix)
#   common/ci/smoke-dev.sh --target min:80    # another edge (host:port)
#   common/ci/smoke-dev.sh --base minerva     # vhost domain suffix (e.g. prod aliases)

set -euo pipefail

TARGET="twix:8080"   # host:port the edge Apache listens on
BASE_SUFFIX="twix"   # vhost domain suffix -> requests carry Host: <svc>.<suffix>

# Readiness: the gate smokes right after `compose up`, when Python backends may
# still be booting (a 503 through the edge = upstream not listening YET, not broken).
# Retry each check until it passes or SMOKE_RETRY_SECS elapses. Services boot in
# parallel, so total time is ~the slowest single service, not the sum. A healthy
# stack passes immediately (no wait). SMOKE_RETRY_SECS=0 => old one-shot behaviour.
SMOKE_RETRY_SECS="${SMOKE_RETRY_SECS:-60}"
SMOKE_RETRY_INTERVAL="${SMOKE_RETRY_INTERVAL:-2}"

while [ $# -gt 0 ]; do
  case "$1" in
    --target) TARGET="$2"; shift 2 ;;
    --base)   BASE_SUFFIX="$2"; shift 2 ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

PASS=0
FAIL=0

# check <name> <vhost-host> <path> [expect_code]
# Connects to $TARGET (the edge) and sets Host: <vhost-host> so Apache selects the
# right vhost — the whole tier is one edge, routed by Host, not by port-per-service.
check() {
  local name="$1" vhost="$2" path="$3" expect_code="${4:-200}"
  local code deadline
  deadline=$(( $(date +%s) + SMOKE_RETRY_SECS ))
  # Poll until the service answers as expected or the readiness budget elapses. A
  # healthy stack matches on the first try; a just-started one gets time to boot.
  while :; do
    code=$(curl -sS -o /dev/null -w "%{http_code}" --max-time 10 \
             -H "Host: ${vhost}" "http://${TARGET}${path}" || echo "000")
    [ "$code" = "$expect_code" ] && break
    [ "$(date +%s)" -ge "$deadline" ] && break
    sleep "$SMOKE_RETRY_INTERVAL"
  done
  if [ "$code" = "$expect_code" ]; then
    printf "  PASS  %-24s Host:%-18s %s\n" "$name" "$vhost" "$path"
    PASS=$((PASS+1))
  else
    printf "  FAIL  %-24s Host:%-18s %s -> %s (want %s, after %ss)\n" \
      "$name" "$vhost" "$path" "$code" "$expect_code" "$SMOKE_RETRY_SECS"
    FAIL=$((FAIL+1))
  fi
}

echo "=== target: ${TARGET}  (vhost suffix: .${BASE_SUFFIX}) ==="

echo "--- edge (static site) ---"
check "home-site root"    "${BASE_SUFFIX}"             "/"
check "version.txt"       "${BASE_SUFFIX}"             "/version.txt"

echo "--- services (through the edge vhosts) ---"
check "panoptikon root"   "panoptikon.${BASE_SUFFIX}"  "/"
check "freddyb health"    "freddyb.${BASE_SUFFIX}"     "/health"
check "hog health"        "hog.${BASE_SUFFIX}"         "/api/v1/health"
check "canary root"       "canary.${BASE_SUFFIX}"      "/"
check "oleo root"         "oleo.${BASE_SUFFIX}"        "/"

echo
echo "=== summary: pass ${PASS}  fail ${FAIL} ==="
[ "$FAIL" -eq 0 ]
