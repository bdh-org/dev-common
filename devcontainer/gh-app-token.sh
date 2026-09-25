#!/usr/bin/env bash
# gh-app-token.sh -- mint a short-lived GitHub App INSTALLATION token for one org, from the
# headful devcontainer App (bdh-org-headful), so a session needs no long-lived PAT
# (bdh-org/home-infra#262; shipped fleet-wide in bdh-org/dev-common#269).
#
#   GH_TOKEN="$(gh-app-token bdh-org)" gh pr list ...
#   gh-app-token --check        # mint for every installed org, report, never print a token
#
# setup-claude.sh links this to /usr/local/bin/gh-app-token in EVERY devcontainer built on
# dev-common, which is the point: until then only home-infra's container could mint, and a
# repo's own devcontainer had no GitHub credential once the PATs were revoked.
#
# ============================================================================
#  RUNS IN: any devcontainer that bind-mounts ~/.config/ai/claude (they all do).
#  READS:   $CRED_DIR/bdh-org-headful.conf and the .pem beside it.
# ============================================================================
#
# CONFIG ($GH_APP_CONF, default $CRED_DIR/bdh-org-headful.conf) -- the format of
# scripts/twix/github-app-git-credential.sh, plus one line kind:
#   APP_ID=<numeric app id>
#   PEM=<path>                         optional; default: the .conf's path with .pem
#   INSTALL <org> <installation-id>    one per org
#   REPOS <org> <repo,repo,...>        optional; NARROW that org's tokens to these repos
#
# REPOS exists because an installation's repo scope is set in a browser by an org owner,
# and finriskanalytics was installed on "All repositories" -- 26, 17 of them private FRA
# work outside this stack, where the PAT it replaces reached 9. Narrowing at mint time
# keeps the App's reach equal to the PAT's without an operator round trip, and an org with
# no REPOS line gets whatever its installation grants.
#
# EXIT: 0 token on stdout (or --check all OK) | 1 could not mint (reason on stderr)
#       2 usage / org not installed
# NEVER prints the key, the JWT, or (under --check) a token. A failure prints GitHub's own
# error message, which carries no secret.
set -euo pipefail

CRED_DIR="${CRED_DIR:-$HOME/.config/ai/claude/credentials}"
CONF="${GH_APP_CONF:-$CRED_DIR/bdh-org-headful.conf}"
API="${GH_API:-https://api.github.com}"

die() { printf 'gh-app-token: %s\n' "$2" >&2; exit "$1"; }

[ $# -eq 1 ] || die 2 "usage: gh-app-token.sh <org> | --check"
[ -r "$CONF" ] || die 1 "no App config at $CONF"

APP_ID=""; PEM="${CONF%.conf}.pem"
declare -A INSTALL=() REPOS=()
while read -r a b c || [ -n "${a:-}" ]; do
  case "${a:-}" in
    ''|'#'*)  : ;;
    APP_ID=*) APP_ID="${a#APP_ID=}" ;;
    PEM=*)    PEM="${a#PEM=}" ;;
    INSTALL)  [ -n "${b:-}" ] && [ -n "${c:-}" ] && INSTALL["$b"]="$c" ;;
    REPOS)    [ -n "${b:-}" ] && [ -n "${c:-}" ] && REPOS["$b"]="$c" ;;
  esac
done < "$CONF"
[ -n "$APP_ID" ] || die 1 "$CONF has no APP_ID= line"
[ -r "$PEM" ]    || die 1 "App private key not readable at $PEM"
[ "${#INSTALL[@]}" -gt 0 ] || die 1 "$CONF has no INSTALL lines"

b64url() { openssl base64 -e -A | tr '+/' '-_' | tr -d '='; }
jwt() {
  local now hdr pld sig
  now="$(date +%s)"
  hdr="$(printf '%s' '{"alg":"RS256","typ":"JWT"}' | b64url)"
  pld="$(printf '{"iat":%d,"exp":%d,"iss":"%s"}' "$((now - 60))" "$((now + 540))" "$APP_ID" | b64url)"
  sig="$(printf '%s.%s' "$hdr" "$pld" | openssl dgst -sha256 -sign "$PEM" | b64url)" \
    || return 1
  printf '%s.%s.%s' "$hdr" "$pld" "$sig"
}

# missing_repos <org> <inst> <jwt> -- print the REPOS entries the installation cannot
# reach. Uses an unnarrowed token internally, only to list names; it is never printed.
missing_repos() {
  local org="$1" inst="$2" j="$3" wide
  wide="$(curl -sS --max-time 30 -X POST -H "Authorization: Bearer $j" \
      -H "Accept: application/vnd.github+json" "$API/app/installations/$inst/access_tokens" \
    | python3 -c 'import sys,json
try: print(json.load(sys.stdin).get("token",""))
except Exception: print("")')"
  [ -n "$wide" ] || return 0
  curl -sS --max-time 30 -H "Authorization: Bearer $wide" \
      "$API/installation/repositories?per_page=100" \
    | WANT="${REPOS[$org]}" python3 -c 'import sys,json,os
have={r["name"] for r in json.load(sys.stdin).get("repositories",[])}
gone=[r for r in os.environ["WANT"].split(",") if r and r not in have]
if gone: print("gh-app-token: REPOS entries the install cannot reach (remove them from the .conf):", ", ".join(gone), file=sys.stderr)' \
    || true
}

# mint <org> -> token on stdout, rc 1 with GitHub's message on stderr
mint() {
  local org="$1" inst body resp tok j
  inst="${INSTALL[$org]:-}"
  [ -n "$inst" ] || die 2 "App is not installed in '$org' (known: ${!INSTALL[*]})"
  j="$(jwt)" || { printf 'gh-app-token: could not sign a JWT with %s\n' "$PEM" >&2; return 1; }
  body='{}'
  if [ -n "${REPOS[$org]:-}" ]; then
    body="$(printf '%s' "${REPOS[$org]}" \
      | python3 -c 'import sys,json;print(json.dumps({"repositories":[r for r in sys.stdin.read().strip().split(",") if r]}))')"
  fi
  # Every gh call now mints first, so one network blip fails the command outright (a
  # 30s connect timeout did, 2026-09-25). curl's --retry covers timeouts and 5xx only --
  # a 401/403/422 is an answer and is not retried. A duplicate mint is harmless: tokens
  # are ~1h and nothing tracks them. Worst case ~66s, still under the JWT's 9 minutes.
  resp="$(curl -sS --connect-timeout 10 --max-time 20 --retry 2 --retry-delay 3 -X POST \
      -H "Authorization: Bearer $j" -H "Accept: application/vnd.github+json" \
      -d "$body" "$API/app/installations/$inst/access_tokens")" \
    || { printf 'gh-app-token: %s: GitHub unreachable\n' "$org" >&2; return 1; }
  tok="$(printf '%s' "$resp" | python3 -c 'import sys,json
try: d=json.load(sys.stdin)
except Exception: d={}
print(d.get("token",""))')"
  if [ -z "$tok" ]; then
    printf 'gh-app-token: %s: no token -- GitHub said: %s\n' "$org" \
      "$(printf '%s' "$resp" | python3 -c 'import sys,json
try: print(json.load(sys.stdin).get("message","(no message)"))
except Exception: print("(unparseable response)")')" >&2
    # A narrowed mint fails WHOLE if any one REPOS entry is gone (deleted, renamed,
    # dropped from the install), and GitHub does not say which. Name it, so the fix is
    # one edit to the .conf rather than a hunt -- solara vanished this way on day one.
    [ -n "${REPOS[$org]:-}" ] && missing_repos "$org" "$inst" "$j"
    return 1
  fi
  printf '%s' "$tok"
}

if [ "$1" != "--check" ]; then
  mint "$1"
  exit $?
fi

# --check: an assertion that each org's token WORKS (it lists repos), never merely that
# a token string came back -- a minted token scoped to zero repos is a failure.
rc=0
for org in $(printf '%s\n' "${!INSTALL[@]}" | sort); do
  if ! tok="$(mint "$org")"; then rc=1; continue; fi
  n="$(curl -sS --max-time 30 -H "Authorization: Bearer $tok" \
        "$API/installation/repositories?per_page=1" \
      | python3 -c 'import sys,json
try: print(json.load(sys.stdin).get("total_count",0))
except Exception: print(0)')"
  scope="all installed repos"; [ -n "${REPOS[$org]:-}" ] && scope="narrowed by REPOS"
  if [ "$n" -gt 0 ]; then
    printf 'OK    %-18s install %-10s %3s repos (%s)\n' "$org" "${INSTALL[$org]}" "$n" "$scope"
  else
    printf 'FAIL  %-18s install %-10s token reaches ZERO repos\n' "$org" "${INSTALL[$org]}"
    rc=1
  fi
done
exit "$rc"
