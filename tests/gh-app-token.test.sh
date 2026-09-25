#!/usr/bin/env bash
# gh-app-token.test.sh -- the headful App minter (bdh-org/dev-common#269; ported from
# bdh-org/home-infra's tests/test-gh-app-token.sh, minus its gh_token_for half).
#
#   RUNS: anywhere with the repo checked out and openssl + python3. No network, ~2s.
#         Via `make test`, and in CI (shell-tests.yml) on every PR.
#
# WHAT MATTERS
#   * REPOS narrows the mint: the request body names exactly those repos, or none.
#   * A narrowed mint that fails NAMES the repo that is gone (solara vanished on day one
#     and GitHub's own message does not say which).
#   * --check fails on a token that reaches ZERO repos, not merely on no token.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MINT="$ROOT/devcontainer/gh-app-token.sh"
[ -x "$MINT" ] || { echo "FAIL: minter not executable at $MINT" >&2; exit 1; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
CRED="$TMP/cred"; STUB="$TMP/bin"; mkdir -p "$CRED" "$STUB"
openssl genrsa -out "$CRED/bdh-org-headful.pem" 2048 2>/dev/null
cat > "$CRED/bdh-org-headful.conf" <<'EOF'
APP_ID=42
INSTALL bdh-org 111
INSTALL finriskanalytics 333
REPOS finriskanalytics keep1,keep2,gone
EOF

# Stub curl: records the POST body; the access_tokens endpoint refuses any body naming
# "gone"; /installation/repositories answers with STUB_TOTAL and the keep repos.
cat > "$STUB/curl" <<'STUBEOF'
#!/usr/bin/env bash
body=""; url=""
while [ $# -gt 0 ]; do
  case "$1" in -d) body="$2"; shift 2 ;; -H|-X|--max-time|--connect-timeout|--retry|--retry-delay) shift 2 ;; -*) shift ;; *) url="$1"; shift ;; esac
done
case "$url" in
  */access_tokens)
    printf '%s\n' "$body" >> "$STUB_STATE/bodies"
    if [ "${STUB_MINT_FAIL:-0}" = 1 ]; then echo '{"message":"Bad credentials"}'; exit 0; fi
    case "$body" in *gone*) echo '{"message":"There is at least one repository that does not exist"}' ;;
                    *) echo '{"token":"ghs_STUBTOKEN"}' ;; esac ;;
  */installation/repositories*)
    printf '{"total_count":%s,"repositories":[{"name":"keep1"},{"name":"keep2"}]}\n' "${STUB_TOTAL:-2}" ;;
esac
STUBEOF
chmod +x "$STUB/curl"
export PATH="$STUB:$PATH" CRED_DIR="$CRED" STUB_STATE="$TMP" GH_API="https://stub"

fail=0; pass=0
ok()  { pass=$((pass + 1)); }
bad() { printf 'FAIL: %s\n' "$1" >&2; fail=$((fail + 1)); }

# 1. unnarrowed org: token printed, body is {}
: > "$TMP/bodies"
out="$("$MINT" bdh-org 2>/dev/null)"; rc=$?
[ "$rc" = 0 ] && [ "$out" = ghs_STUBTOKEN ] && ok || bad "bdh-org mint rc=$rc out=$out"
grep -qx '{}' "$TMP/bodies" && ok || bad "unnarrowed body was not {}: $(cat "$TMP/bodies")"

# 2. narrowed org with a vanished repo: rc 1, and the missing repo is NAMED
: > "$TMP/bodies"
err="$("$MINT" finriskanalytics 2>&1 >/dev/null)"; rc=$?
[ "$rc" = 1 ] && ok || bad "narrowed mint with a gone repo returned rc=$rc"
[[ "$err" == *"cannot reach"*"gone"* ]] && ok || bad "missing repo not named: $err"
[[ "$err" != *keep1* ]] && ok || bad "a reachable repo was reported missing: $err"
[[ "$err" != *ghs_* ]] && ok || bad "a token leaked to stderr"

# 3. fix the conf: body names exactly the REPOS list
sed -i 's/,gone$//' "$CRED/bdh-org-headful.conf"
: > "$TMP/bodies"
out="$("$MINT" finriskanalytics 2>/dev/null)"; rc=$?
[ "$rc" = 0 ] && ok || bad "narrowed mint rc=$rc"
grep -qx '{"repositories": \["keep1", "keep2"\]}' "$TMP/bodies" && ok \
  || bad "narrowed body wrong: $(cat "$TMP/bodies")"

# 4. --check never prints a token, and fails a token reaching zero repos
out="$("$MINT" --check 2>&1)"; rc=$?
[ "$rc" = 0 ] && ok || bad "--check rc=$rc: $out"
[[ "$out" != *ghs_* ]] && ok || bad "--check printed a token"
out="$(STUB_TOTAL=0 "$MINT" --check 2>&1)"; rc=$?
[ "$rc" = 1 ] && [[ "$out" == *ZERO* ]] && ok || bad "--check passed a zero-repo token (rc=$rc)"

# 5. usage / unknown org / no conf
"$MINT" >/dev/null 2>&1; [ $? = 2 ] && ok || bad "no-arg rc not 2"
"$MINT" nosuch >/dev/null 2>&1; [ $? = 2 ] && ok || bad "unknown org rc not 2"
GH_APP_CONF="$TMP/none" "$MINT" bdh-org >/dev/null 2>&1; [ $? = 1 ] && ok || bad "missing conf rc not 1"

printf 'gh-app-token.test: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" = 0 ]
