#!/usr/bin/env bash
# bump-submodule-pins.sh — open (or refresh) ONE pull request per consumer that moves a
# stale submodule pin to the source's current default branch. The remediation half of the
# loop whose detection half is bdh-org/home-infra's scripts/audit-submodule-pins.sh
# (home-infra#349, #362).
#
# It lives HERE, in dev-common, and not beside the audit, because .github/workflows/
# bump-submodule-pins.yml runs it and a reusable workflow can only reach code in a repo its
# callers can see: home-infra is private, dev-common is public, and a reusable's default
# checkout lands in the CALLER's workspace (home-infra#368). The audit stays in home-infra --
# a human runs it there from the architect devcontainer -- and reads the ONE registry that
# sits beside this script, through its own `common/` submodule, as
# common/scripts/fleet-consumers.txt.
#
#   ./scripts/bump-submodule-pins.sh --source bdh-org/home-stack-common --dry-run
#   ./scripts/bump-submodule-pins.sh --source bdh-org/dev-common
#   ./scripts/bump-submodule-pins.sh --source bdh-org/dev-common --only finzeug/hog
#
# WHAT IT ANSWERS
#
#   Nothing advanced a submodule pointer except a human remembering to. `common` was
#   1-3 commits behind fleet-wide because the update-common skill existed; `stack-common`
#   was 15 commits and 30 days behind across ten repos because nothing did. That is not a
#   policy difference -- nobody decided the instructions every session loads at start
#   should be a month stale. It is the difference between a tool and a habit.
#
#   So: the SOURCE sweeps its consumers, because the source is the only party that knows
#   a change happened. A consumer cannot notice something it has not fetched -- the same
#   absence problem the three fleet audits exist for.
#
# WHAT IT WILL NOT DO, EVER
#
#   * It does not merge. Merging a bump is a DEPLOY -- ci-build ships an image and
#     restarts the service -- so a fleet sweep that merged would be a fleet deploy with
#     nothing checking the fleet came back (home-infra#348). The PR is the deliverable;
#     the merge is a human act.
#   * It does not push to a consumer's default branch. Structurally, not by convention:
#     every push goes to refs/heads/bump/<path>, and push_branch refuses a ref
#     that is not under the prefix or that equals the consumer's default branch.
#   * It does not `sed` a version. `make bump-patch` owns that, so Makefile VERSION and
#     __version__/package.json/version.txt move together and the consumer's own
#     version-check passes.
#
# ONE PR PER CONSUMER, UPDATED IN PLACE
#
#   The branch name is stable (bump/common, bump/stack-common) and the push is a force
#   push, so the open PR is always "your pin versus current main" and merging it is
#   always current. A PR per bump would build a queue of stale PRs in which merging the
#   wrong one moves the pin BACKWARDS.
#
#   When the pin is already at the source's head the open PR is CLOSED and its branch
#   deleted, so an open bump PR always means real drift. A PR left open over a pin that
#   someone bumped by hand is the stalest thing this script could produce.
#
# A CONSUMER THAT CANNOT BE PROCESSED IS A FAILURE, NOT A SKIP
#
#   No token, no .gitmodules, a clone that fails, a `make bump-patch` that errors -- or one
#   that exits 0 and moves no version: each is counted, named in the summary, and exits
#   non-zero. A sweep that silently covered 8 of 10 repos reports the same green as one
#   that covered 10, which is the exact false green in home-infra#343.
#
#   Exit 0  every applicable consumer is current or now has an open PR
#   Exit 1  at least one consumer could not be processed
#   Exit 2  nothing was assessed (no registry, no consumer pins this source, no token
#           anywhere) -- NOT a pass
#
# CREDENTIALS (home-infra#91)
#
#   Per org, in order: $GH_TOKEN_<org with - as _> (how the workflow passes the coder App
#   installation tokens it mints for bdh-org and finzeug), then a file in $CRED_DIR
#   (gh-<org>.token -- the devcontainer layout), then $GH_TOKEN. Consumers live in BOTH
#   orgs, so one token is never enough for a whole sweep.
#
# curl-based, like the audit: gh is not on every host's PATH (the forge runner has none).
set -uo pipefail

API="${GH_API:-https://api.github.com}"          # test seam: point at a stub API base
CRED_DIR="${CRED_DIR:-$HOME/.config/ai/claude/credentials}"
# BUMP_BRANCH_PREFIX, not BRANCH_PREFIX: the forge runner exports BRANCH_PREFIX=claude/ for
# the agent pipeline, and a generic name here silently produced claude/common branches on the
# first test run. An env knob this script reads has to be named for THIS script.
BRANCH_PREFIX="${BUMP_BRANCH_PREFIX:-bump/}"
# Test seam: the base every clone/push URL is built from. Empty (the default) means real
# GitHub over HTTPS with the org token embedded; tests point it at a directory of bare
# repos so the whole clone -> commit -> force-push path runs for real without a network.
GIT_BASE="${GIT_BASE:-}"
# The headless git actor. Matches the identity the agent pipeline already commits as, so
# a bump commit is attributable to the App and not to a person.
GIT_AUTHOR_NAME_="${BUMP_GIT_NAME:-bdh-org-coder[bot]}"
GIT_AUTHOR_EMAIL_="${BUMP_GIT_EMAIL:-305014630+bdh-org-coder[bot]@users.noreply.github.com}"

command -v jq  >/dev/null 2>&1 || { echo "bump-submodule-pins: jq is required" >&2; exit 2; }
command -v git >/dev/null 2>&1 || { echo "bump-submodule-pins: git is required" >&2; exit 2; }

# ---------------------------------------------------------------------------- args

SOURCE=""; DRY=0; ONLY=""
REGISTRY="${FLEET_REGISTRY:-$(dirname "$0")/fleet-consumers.txt}"
usage() {
  cat >&2 <<EOF
usage: bump-submodule-pins.sh --source <org>/<repo> [--dry-run] [--only <org>/<repo>]
                              [--registry <file>]

  --source    the submodule repo whose consumers to sweep (bdh-org/dev-common,
              bdh-org/home-stack-common). Required.
  --dry-run   do everything locally -- clone, move the pointer, run make bump-patch --
              and report it, but push nothing, open no PR and close no PR.
  --only      restrict the sweep to one consumer from the registry (still an
              expected-list entry: an --only that matches nothing exits 2).
  --registry  consumer list (default: ${REGISTRY})
EOF
  exit 2
}
while [ $# -gt 0 ]; do
  case "$1" in
    --source)   SOURCE="${2:-}"; shift 2 || usage ;;
    --only)     ONLY="${2:-}"; shift 2 || usage ;;
    --registry) REGISTRY="${2:-}"; shift 2 || usage ;;
    --dry-run)  DRY=1; shift ;;
    -h|--help)  usage ;;
    *) echo "bump-submodule-pins: unknown argument: $1" >&2; usage ;;
  esac
done
[ -n "$SOURCE" ] || usage
case "$SOURCE" in */*) ;; *) echo "bump-submodule-pins: --source must be <org>/<repo>" >&2; exit 2 ;; esac
SOURCE_ORG="${SOURCE%%/*}"

# ---------------------------------------------------------------------------- helpers

log()  { printf '%s\n' "$*"; }
note() { printf '%s\n' "$*" >&2; }

trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

is_num() { case "$1" in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac; }

# makefile_version <worktree> <rev> -- the VERSION= value as COMMITTED at <rev>, empty if
# the Makefile has none. Reading the commit rather than the worktree is deliberate: what
# ships in the PR is the commit, so that is what "the version moved" has to be asked of.
makefile_version() {
  git -C "$1" show "${2}:Makefile" 2>/dev/null \
    | grep -m1 -E '^VERSION[[:space:]]*=' | sed -E 's/^VERSION[[:space:]]*=[[:space:]]*//'
}

# api_get / api_send <token> <path> [json-body] -- set STATUS and BODY.
#
# Deliberately not `body=$(api_get ...)`: a command substitution runs in a subshell, so
# the status the callee learned would be discarded and every response judged against
# whatever the previous call left behind (same reason as the audit).
STATUS=""; BODY=""
RESP="$(mktemp)"
WORKROOT="$(mktemp -d)"
trap 'rm -f "$RESP"; rm -rf "$WORKROOT"' EXIT

api_get() {
  local tok="$1" path="$2"
  BODY=""
  STATUS="$(curl -sS -o "$RESP" -w '%{http_code}' \
              -H "Authorization: Bearer ${tok}" \
              -H "Accept: application/vnd.github+json" \
              "${API}${path}" 2>/dev/null)" || STATUS="000"
  BODY="$(cat "$RESP")"
}

# api_send <token> <method> <path> [body-file]
api_send() {
  local tok="$1" method="$2" path="$3" bodyfile="${4:-}"
  BODY=""
  if [ -n "$bodyfile" ]; then
    STATUS="$(curl -sS -o "$RESP" -w '%{http_code}' -X "$method" \
                -H "Authorization: Bearer ${tok}" \
                -H "Accept: application/vnd.github+json" \
                -H "Content-Type: application/json" \
                --data-binary "@${bodyfile}" \
                "${API}${path}" 2>/dev/null)" || STATUS="000"
  else
    STATUS="$(curl -sS -o "$RESP" -w '%{http_code}' -X "$method" \
                -H "Authorization: Bearer ${tok}" \
                -H "Accept: application/vnd.github+json" \
                "${API}${path}" 2>/dev/null)" || STATUS="000"
  fi
  BODY="$(cat "$RESP")"
}

token_for() {
  local org="$1"
  # $GH_TOKEN_<org> first: this is how the workflow hands over the per-org coder App
  # installation tokens it mints. `-` is not legal in an env var name, so bdh-org
  # arrives as GH_TOKEN_bdh_org.
  local var="GH_TOKEN_${org//-/_}"
  local v="${!var:-}"
  [ -n "$v" ] && { printf '%s' "$v"; return 0; }
  local f="${CRED_DIR}/gh-${org}.token"
  [ -r "$f" ] && { cat "$f"; return 0; }
  # Ambient GH_TOKEN is a fallback, not a default: it is usually scoped to ONE org, and
  # using it against another yields 404. Every caller probes the repo before drawing a
  # conclusion, which is what makes the fallback safe.
  [ -n "${GH_TOKEN:-}" ] && { printf '%s' "$GH_TOKEN"; return 0; }
  return 1
}

# slug_of <git url> -> "org/repo". Handles https, scp-style and a trailing slash; prints
# nothing for a non-github remote, which the caller reports rather than guessing at.
slug_of() {
  local u="$1"
  u="${u%/}"; u="${u%.git}"
  case "$u" in
    *github.com/*) printf '%s' "${u##*github.com/}" ;;
    *github.com:*) printf '%s' "${u##*github.com:}" ;;
    *) return 1 ;;
  esac
}

days_since() {
  local then now
  then="$(date -d "$1" +%s 2>/dev/null)" || { printf '?'; return; }
  [ -n "$then" ] || { printf '?'; return; }
  now="$(date +%s)"
  printf '%d' $(( (now - then) / 86400 ))
}

# clone_url <slug> <token> -- the URL git is handed. GIT_BASE is the test seam; without
# it the org token is embedded, which is why nothing here is ever echoed.
clone_url() {
  if [ -n "$GIT_BASE" ]; then printf '%s%s.git' "$GIT_BASE" "$1"
  else printf 'https://x-access-token:%s@github.com/%s.git' "$2" "$1"; fi
}

# jqs <filter> -- read a string out of $BODY, empty on any parse trouble.
jqs() { printf '%s' "$BODY" | jq -r "$1" 2>/dev/null || printf ''; }

# ---------------------------------------------------------------------------- registry

if [ -z "${CONSUMERS:-}" ]; then
  [ -r "$REGISTRY" ] || {
    note "bump-submodule-pins: no consumer registry at ${REGISTRY}"
    note "Point --registry/FLEET_REGISTRY at it, or pass the list inline via CONSUMERS=."
    exit 2
  }
  CONSUMERS="$(cat "$REGISTRY")"
fi

# ---------------------------------------------------------------------------- the source

STOK="$(token_for "$SOURCE_ORG")" || {
  note "bump-submodule-pins: no credential for ${SOURCE_ORG} (tried \$GH_TOKEN_${SOURCE_ORG//-/_}, ${CRED_DIR}/gh-${SOURCE_ORG}.token, \$GH_TOKEN)"
  exit 2
}
api_get "$STOK" "/repos/${SOURCE}"
[ "$STATUS" = "200" ] || { note "bump-submodule-pins: cannot read ${SOURCE} (HTTP ${STATUS})"; exit 2; }
SOURCE_BRANCH="$(jqs '.default_branch // ""')"
[ -n "$SOURCE_BRANCH" ] || { note "bump-submodule-pins: ${SOURCE} reports no default branch"; exit 2; }

api_get "$STOK" "/repos/${SOURCE}/commits/${SOURCE_BRANCH}"
[ "$STATUS" = "200" ] || { note "bump-submodule-pins: cannot read ${SOURCE}@${SOURCE_BRANCH} (HTTP ${STATUS})"; exit 2; }
SOURCE_HEAD="$(jqs '.sha // ""')"
[ -n "$SOURCE_HEAD" ] || { note "bump-submodule-pins: no head sha for ${SOURCE}@${SOURCE_BRANCH}"; exit 2; }

log "bump-submodule-pins: source ${SOURCE}@${SOURCE_BRANCH} = ${SOURCE_HEAD:0:8}$([ "$DRY" = 1 ] && echo '  [DRY RUN — nothing will be pushed]')"
log ""

# ---------------------------------------------------------------------------- PR body
#
# The body is where this stops being merely automatic and becomes safe: whoever merges it
# is deploying, and has to be told so in the PR they are looking at rather than in a
# runbook they are not.

pr_body() {   # pr_body <consumer> <path> <sub-slug> <pin> <behind> <age-days> <subjects-file> <touches-claudemd> <bumped-version> <has-ci-build>
  local consumer="$1" path="$2" sub="$3" pin="$4" behind="$5" age="$6" subjects="$7" claudemd="$8" newver="$9" cibuild="${10}"
  local svc="${consumer##*/}"

  printf 'Moves the `%s` submodule pin from `%s` to `%s` (%s@%s).\n\n' \
    "$path" "${pin:0:8}" "${SOURCE_HEAD:0:8}" "$sub" "$SOURCE_BRANCH"
  printf '**%s commits, oldest one missed %s days ago.**\n\n' "$behind" "$age"
  printf 'Range: https://github.com/%s/compare/%s...%s\n\n' "$sub" "$pin" "$SOURCE_HEAD"
  if [ -s "$subjects" ]; then
    printf 'What moves:\n\n'
    sed 's/^/- /' "$subjects"
    printf '\n'
  fi
  if [ -n "$newver" ]; then
    printf 'Also bumps this repo to `%s` via `make bump-patch`, so `version-check` passes.\n\n' "$newver"
  else
    printf 'No `VERSION=` in this Makefile, so no version bump — the pointer is the whole change.\n\n'
  fi

  # Whether merging deploys is ASKED, not assumed. The first live PR this script opened said
  # merging would restart "the home-infra service on min" -- home-infra ships no image and has
  # no ci-build at all. A blast-radius paragraph that names a deploy that does not exist is
  # worse than none: it is the confident wrong sentence, in the one place a human reads before
  # merging.
  printf -- '---\n\n'
  if [ "$cibuild" = "yes" ]; then
    printf '### Merging this is a deploy\n\n'
    printf 'Merging to `main` runs `ci-build` in **%s**: it builds a SHA-tagged image, pushes it to\n' "$consumer"
    printf '`registry.home.arpa`, and the deploy on `min` restarts **%s** (a P2b static site rsyncs its\n' "$svc"
    printf '`dist/` instead of restarting a container). Nothing here checks that it came back —\n'
    printf 'bdh-org/home-infra#348 is that half. Merge one at a time, or watch the fleet if you merge\n'
    printf 'several.\n\n'
  else
    printf '### Merging this deploys nothing directly\n\n'
    printf '**%s** has no `ci-build` workflow, so merging builds no image and restarts no service. It\n' "$consumer"
    printf 'reaches production only through whatever pins **%s** in turn, at the next build of that\n' "$svc"
    printf 'consumer — which is this same staleness, one layer up.\n\n'
  fi
  if [ "$claudemd" = "yes" ]; then
    printf '### This range changes `CLAUDE.md`\n\n'
    printf 'That is the instruction file every Claude Code session in this repo loads at start, so merging\n'
    printf 'changes how sessions here behave. **No test covers an instruction change** — read the diff of\n'
    printf '`%s/CLAUDE.md` in the range above rather than trusting a green CI.\n\n' "$path"
  elif [ "$path" = "stack-common" ]; then
    printf '### Instruction changes are invisible to CI\n\n'
    printf '`stack-common` carries `CLAUDE.md`, the file every Claude Code session in this repo loads at\n'
    printf 'start. This particular range does not touch it, but when one does, nothing tests it — a green\n'
    printf 'CI says nothing either way.\n\n'
  fi
  printf '### Do not auto-merge\n\n'
  printf 'This PR is opened, and force-refreshed in place, by `scripts/bump-submodule-pins.sh` in\n'
  printf 'bdh-org/dev-common (issues bdh-org/home-infra#362, #368). It never merges and never pushes to `main`.\n'
  printf 'The branch `%s%s` is rewritten on every sweep, so it always reads "your pin versus current\n' "$BRANCH_PREFIX" "$path"
  printf '`%s`" — do not build on it. If the pin gets bumped some other way, the next sweep closes this\n' "$SOURCE_BRANCH"
  printf 'PR automatically.\n'
}

# ---------------------------------------------------------------------------- git ops

# push_branch <workdir> <branch> <default-branch> <clone-url>
#
# The ONLY push in this script, and the place the "never touches main" guarantee is
# enforced rather than merely intended: an explicit refspec, a prefix check, and a
# default-branch check. Nothing else in this file runs `git push`.
push_branch() {
  local wd="$1" branch="$2" default="$3" url="$4"
  case "$branch" in
    "${BRANCH_PREFIX}"?*) ;;
    *) note "REFUSING to push '${branch}': not under ${BRANCH_PREFIX}"; return 1 ;;
  esac
  if [ "$branch" = "$default" ]; then
    note "REFUSING to push '${branch}': it is the consumer's default branch"; return 1
  fi
  git -C "$wd" push --force "$url" "HEAD:refs/heads/${branch}" >/dev/null 2>&1
}

# ---------------------------------------------------------------------------- the sweep

repos=0; applicable=0; current=0; bumped=0; failed=0; nopin=0
problems=""
fail() { failed=$((failed+1)); problems="${problems} $1"; }

while IFS= read -r line; do
  line="$(trim "$line")"
  [ -n "$line" ] || continue
  case "$line" in \#*) continue ;; esac

  consumer="$(trim "$(printf '%s' "$line" | cut -d'|' -f1)")"
  [ -n "$consumer" ] || { note "  BAD  unparseable registry line: ${line}"; fail "registry-line"; continue; }
  [ -z "$ONLY" ] || [ "$ONLY" = "$consumer" ] || continue
  org="${consumer%%/*}"
  repos=$((repos+1))

  tok="$(token_for "$org")" || {
    printf '  FAIL %-26s no credential for %s (tried $GH_TOKEN_%s, %s/gh-%s.token, $GH_TOKEN)\n' \
      "$consumer" "$org" "${org//-/_}" "$CRED_DIR" "$org"
    fail "${consumer}(no-token)"; continue; }

  # Probe the repo BEFORE reading files, so "no access" never masquerades as "no
  # submodules" -- both are a 404.
  api_get "$tok" "/repos/${consumer}"
  if [ "$STATUS" != "200" ]; then
    printf '  FAIL %-26s not readable with the %s credential (HTTP %s)\n' "$consumer" "$org" "$STATUS"
    fail "${consumer}(no-access:${STATUS})"; continue
  fi
  cdefault="$(jqs '.default_branch // ""')"
  [ -n "$cdefault" ] || { printf '  FAIL %-26s reports no default branch\n' "$consumer"; fail "${consumer}(no-default-branch)"; continue; }

  api_get "$tok" "/repos/${consumer}/contents/.gitmodules"
  if [ "$STATUS" != "200" ]; then
    printf '  FAIL %-26s declares no submodules (no .gitmodules) — remove it from the registry\n' "$consumer"
    fail "${consumer}(no-gitmodules)"; continue
  fi
  gitmodules="$(jqs '.content // ""' | tr -d '\n' | base64 -d 2>/dev/null)"

  # Pair each `path =` with the `url =` in the same [submodule] block. A path whose URL
  # does not resolve to THIS source is not this sweep's business -- the registry lists
  # consumers of every submodule in the fleet, not of one library.
  paths="$(printf '%s\n' "$gitmodules" | awk '
    /^[[:space:]]*path[[:space:]]*=/  { sub(/^[^=]*=[[:space:]]*/, ""); gsub(/[[:space:]]+$/, ""); p=$0 }
    /^[[:space:]]*url[[:space:]]*=/   { sub(/^[^=]*=[[:space:]]*/, ""); gsub(/[[:space:]]+$/, ""); if (p != "") { print p "\t" $0; p="" } }
  ')"
  if [ -z "$paths" ]; then
    printf '  FAIL %-26s .gitmodules declares no path/url pairs — remove it from the registry\n' "$consumer"
    fail "${consumer}(no-paths)"; continue
  fi

  matched=0
  while IFS="$(printf '\t')" read -r path url; do
    [ -n "$path" ] || continue
    sub="$(slug_of "$url")" || continue
    [ "$sub" = "$SOURCE" ] || continue
    matched=1
    applicable=$((applicable+1))
    branch="${BRANCH_PREFIX}${path}"

    api_get "$tok" "/repos/${consumer}/contents/${path}"
    if [ "$STATUS" != "200" ]; then
      printf '  FAIL %-26s %-14s .gitmodules names it but the tree does not (HTTP %s)\n' "$consumer" "$path" "$STATUS"
      fail "${consumer}:${path}(not-in-tree)"; continue
    fi
    kind="$(jqs '.type // ""')"; pin="$(jqs '.sha // ""')"
    if [ "$kind" != "submodule" ] || [ -z "$pin" ]; then
      printf '  FAIL %-26s %-14s is a %s in the tree, not a submodule — .gitmodules is stale\n' \
        "$consumer" "$path" "${kind:-?}"
      fail "${consumer}:${path}(not-a-submodule)"; continue
    fi

    # Is there already an open bump PR? Asked up front because it is the answer either
    # way: refresh it when there is drift, close it when there is not.
    api_get "$tok" "/repos/${consumer}/pulls?state=open&head=${org}:${branch}"
    prnum=""; [ "$STATUS" = "200" ] && prnum="$(jqs '.[0].number // ""')"

    # ---- already current: close any open PR, delete the branch, move on -------------
    if [ "$pin" = "$SOURCE_HEAD" ]; then
      if [ -n "$prnum" ]; then
        if [ "$DRY" = 1 ]; then
          printf '  ok   %-26s %-14s current — would CLOSE #%s and delete %s\n' "$consumer" "$path" "$prnum" "$branch"
        else
          printf '{"state":"closed"}' > "${WORKROOT}/close.json"
          api_send "$tok" PATCH "/repos/${consumer}/pulls/${prnum}" "${WORKROOT}/close.json"
          if [ "$STATUS" != "200" ]; then
            printf '  FAIL %-26s %-14s current, but could not close #%s (HTTP %s)\n' "$consumer" "$path" "$prnum" "$STATUS"
            fail "${consumer}:${path}(close-failed:${STATUS})"; continue
          fi
          api_send "$tok" DELETE "/repos/${consumer}/git/refs/heads/${branch}"
          printf '  ok   %-26s %-14s current — closed stale PR #%s and deleted %s\n' "$consumer" "$path" "$prnum" "$branch"
        fi
      else
        printf '  ok   %-26s %-14s current with %s@%s\n' "$consumer" "$path" "$sub" "$SOURCE_BRANCH"
      fi
      current=$((current+1)); continue
    fi

    # ---- how far, and how long -------------------------------------------------------
    api_get "$STOK" "/repos/${SOURCE}/compare/${pin}...${SOURCE_HEAD}"
    if [ "$STATUS" != "200" ]; then
      printf '  FAIL %-26s %-14s pin %s unknown to %s (HTTP %s)\n' "$consumer" "$path" "${pin:0:8}" "$sub" "$STATUS"
      fail "${consumer}:${path}(pin-unknown)"; continue
    fi
    behind="$(jqs '.ahead_by // 0')"           # base=pin, head=source: the PIN's lag is ahead_by
    is_num "$behind" || behind="?"
    firstmissed="$(jqs '.commits[0].commit.committer.date // ""')"
    age="?"; [ -n "$firstmissed" ] && age="$(days_since "$firstmissed")"
    printf '%s' "$BODY" | jq -r '.commits[]?.commit.message // "" | split("\n")[0]' 2>/dev/null \
      | tail -20 > "${WORKROOT}/subjects.txt"
    claudemd="no"
    printf '%s' "$BODY" | jq -e '(.files // []) | map(.filename) | index("CLAUDE.md")' >/dev/null 2>&1 && claudemd="yes"

    # Does merging actually deploy? Ask the consumer, do not assume (see pr_body).
    api_get "$tok" "/repos/${consumer}/contents/.github/workflows/ci-build.yml"
    cibuild="no"; [ "$STATUS" = "200" ] && cibuild="yes"

    # ---- move the pointer for real ----------------------------------------------------
    wd="${WORKROOT}/$(printf '%s' "${consumer}-${path}" | tr '/' '_')"
    curl_url="$(clone_url "$consumer" "$tok")"
    if ! git clone --quiet --depth 50 --branch "$cdefault" "$curl_url" "$wd" 2>"${WORKROOT}/err"; then
      printf '  FAIL %-26s %-14s clone failed: %s\n' "$consumer" "$path" "$(tail -1 "${WORKROOT}/err")"
      fail "${consumer}:${path}(clone-failed)"; continue
    fi
    git -C "$wd" config user.name  "$GIT_AUTHOR_NAME_"
    git -C "$wd" config user.email "$GIT_AUTHOR_EMAIL_"

    # Hydrate the submodule being moved, plus `common/` when it is a different path --
    # `make bump-patch` lives in common/make/version.mk, so a stack-common bump still
    # needs common on disk. NOT --recursive: a nested pin (dev-common inside
    # home-stack-common) belongs to the SOURCE's commit and must not be rewritten from a
    # consumer. That ordering is home-infra#362 §4 -- bump dev-common inside
    # home-stack-common first, then let the stack-common sweep carry it out.
    stok_for_sub="$STOK"
    subrewrite=""
    if [ -n "$GIT_BASE" ]; then
      subrewrite="url.${GIT_BASE}.insteadOf=https://github.com/"
    else
      subrewrite="url.https://x-access-token:${stok_for_sub}@github.com/.insteadOf=https://github.com/"
    fi
    for want in "$path" common; do
      [ -d "${wd}/${want}" ] || continue
      # No --depth here: the sources are small, and a shallow submodule clone cannot
      # always reach an arbitrary sha, which is precisely what the next step asks for.
      git -C "$wd" -c "$subrewrite" submodule update --init "$want" >/dev/null 2>&1 || true
    done

    if [ ! -e "${wd}/${path}/.git" ]; then
      printf '  FAIL %-26s %-14s could not hydrate the submodule to move it\n' "$consumer" "$path"
      fail "${consumer}:${path}(hydrate-failed)"; continue
    fi
    # Fetch the target sha by name first (GitHub allows it); fall back to fetching every
    # branch for remotes that do not, e.g. a plain bare repo.
    git -C "${wd}/${path}" fetch --quiet origin "$SOURCE_HEAD" 2>/dev/null \
      || git -C "${wd}/${path}" fetch --quiet origin "+refs/heads/*:refs/remotes/origin/*" 2>/dev/null \
      || true
    if ! git -C "${wd}/${path}" checkout --quiet --detach "$SOURCE_HEAD" 2>/dev/null; then
      printf '  FAIL %-26s %-14s %s not reachable in the submodule clone\n' "$consumer" "$path" "${SOURCE_HEAD:0:8}"
      fail "${consumer}:${path}(head-unreachable)"; continue
    fi

    git -C "$wd" checkout --quiet -B "$branch" >/dev/null 2>&1
    git -C "$wd" add "$path"
    if git -C "$wd" diff --cached --quiet; then
      printf '  FAIL %-26s %-14s pointer move produced no change (pin %s vs head %s)\n' \
        "$consumer" "$path" "${pin:0:8}" "${SOURCE_HEAD:0:8}"
      fail "${consumer}:${path}(no-diff)"; continue
    fi
    if ! git -C "$wd" commit --quiet -m "chore: bump ${path} to ${SOURCE_HEAD:0:8} (${behind} commits)" \
         -m "Moves ${path} from ${pin:0:8} to ${sub}@${SOURCE_BRANCH}. Opened by bump-submodule-pins.sh (home-infra#362)."; then
      printf '  FAIL %-26s %-14s could not commit the pointer move\n' "$consumer" "$path"
      fail "${consumer}:${path}(commit-failed)"; continue
    fi

    # ---- the consumer's own version -----------------------------------------------------
    #
    # `make bump-patch`, never a sed: it moves Makefile VERSION, __version__, package.json
    # and version.txt together, which is exactly the drift the consumer's version-check
    # exists to catch.
    #
    # A repo with no VERSION= is not a failure. home-infra is the standing case -- the
    # architect workspace ships no image and carries no version -- and that is a property
    # readable from the Makefile, not an error swallowed. A repo that HAS a VERSION and
    # whose bump-patch fails IS a failure, and stops before anything is pushed.
    #
    # And a bump-patch that exits 0 having changed NOTHING is a failure too, which is why
    # the version is read back out of the commit rather than trusted. It happens for real:
    # `-include common/make/version.mk` on a consumer whose common/ did not hydrate leaves
    # `bump-patch` undefined-but-satisfiable, and any consumer-local stub target exits 0
    # silently. What that produces is a bump PR carrying no version change -- the same
    # silent version collision that hit five repos on 2026-08-11 (finzeug/ledger-io#42
    # rebased clean, no conflict, no warning, and would have shipped under a published
    # version). An empty result reported as success is home-infra#343, applied here to
    # this script's own tool.
    newver=""
    if [ -f "${wd}/Makefile" ] && grep -qE '^VERSION[[:space:]]*=' "${wd}/Makefile"; then
      oldver="$(makefile_version "$wd" HEAD)"
      if ! ( cd "$wd" && make bump-patch >"${WORKROOT}/bump.log" 2>&1 ); then
        printf '  FAIL %-26s %-14s make bump-patch failed: %s\n' "$consumer" "$path" "$(tail -1 "${WORKROOT}/bump.log")"
        fail "${consumer}:${path}(bump-patch-failed)"; continue
      fi
      # Out of the COMMIT, not the worktree: a version that moved but was never committed
      # is invisible to the PR, and reads identically to one that never moved at all.
      newver="$(makefile_version "$wd" HEAD)"
      if [ -z "$newver" ] || [ "$newver" = "$oldver" ]; then
        printf '  FAIL %-26s %-14s make bump-patch exited 0 but committed no version change: %s Makefile VERSION=%s before and after (%s)\n' \
          "$consumer" "$path" "$consumer" "${oldver:-<none>}" "$(tail -1 "${WORKROOT}/bump.log")"
        fail "${consumer}:${path}(bump-patch-noop)"; continue
      fi
    fi

    if [ "$DRY" = 1 ]; then
      printf '  DRY  %-26s %-14s would open/refresh %s: %s behind, oldest %sd%s\n' \
        "$consumer" "$path" "$branch" "$behind" "$age" \
        "$([ -n "$newver" ] && printf ', version -> %s' "$newver")"
      bumped=$((bumped+1)); continue
    fi

    if ! push_branch "$wd" "$branch" "$cdefault" "$curl_url"; then
      printf '  FAIL %-26s %-14s could not force-push %s\n' "$consumer" "$path" "$branch"
      fail "${consumer}:${path}(push-failed)"; continue
    fi

    title="chore: bump ${path} to ${sub}@${SOURCE_BRANCH} (${behind} commits)"
    pr_body "$consumer" "$path" "$sub" "$pin" "$behind" "$age" "${WORKROOT}/subjects.txt" "$claudemd" "$newver" "$cibuild" \
      > "${WORKROOT}/body.md"
    jq -n --arg t "$title" --arg h "$branch" --arg b "$cdefault" --rawfile body "${WORKROOT}/body.md" \
      '{title:$t, head:$h, base:$b, body:$body}' > "${WORKROOT}/pr.json"

    if [ -n "$prnum" ]; then
      jq -n --arg t "$title" --rawfile body "${WORKROOT}/body.md" '{title:$t, body:$body}' > "${WORKROOT}/prpatch.json"
      api_send "$tok" PATCH "/repos/${consumer}/pulls/${prnum}" "${WORKROOT}/prpatch.json"
      if [ "$STATUS" != "200" ]; then
        printf '  FAIL %-26s %-14s pushed, but could not refresh PR #%s (HTTP %s)\n' "$consumer" "$path" "$prnum" "$STATUS"
        fail "${consumer}:${path}(pr-update-failed:${STATUS})"; continue
      fi
      printf '  BUMP %-26s %-14s refreshed PR #%-5s %s behind, oldest %sd%s\n' \
        "$consumer" "$path" "$prnum" "$behind" "$age" \
        "$([ -n "$newver" ] && printf ', version -> %s' "$newver")"
    else
      api_send "$tok" POST "/repos/${consumer}/pulls" "${WORKROOT}/pr.json"
      if [ "$STATUS" != "201" ]; then
        printf '  FAIL %-26s %-14s pushed, but could not open a PR (HTTP %s): %s\n' \
          "$consumer" "$path" "$STATUS" "$(jqs '.message // ""')"
        fail "${consumer}:${path}(pr-open-failed:${STATUS})"; continue
      fi
      prnum="$(jqs '.number // ""')"
      printf '  BUMP %-26s %-14s opened PR #%-5s   %s behind, oldest %sd%s\n' \
        "$consumer" "$path" "$prnum" "$behind" "$age" \
        "$([ -n "$newver" ] && printf ', version -> %s' "$newver")"
    fi
    bumped=$((bumped+1))
  done <<<"$paths"

  [ "$matched" = 1 ] || { nopin=$((nopin+1)); printf '  --   %-26s does not pin %s\n' "$consumer" "$SOURCE"; }
done <<<"$CONSUMERS"

# ---------------------------------------------------------------------------- reporting
#
# Discovery must be provable, not assumed (home-infra#232, #343). "0 problems" over 0
# consumers is the false green this whole family of scripts exists to prevent, so an
# empty sweep exits 2 and says what it looked at.

log ""
if [ "$applicable" -eq 0 ]; then
  note "FAIL: no consumer in the registry pins ${SOURCE} (${repos} entries considered, ${nopin} pin something else)."
  note "This is NOT a pass. Check --source, the registry (${REGISTRY}), --only, and org access."
  [ -n "$problems" ] && note "could not process:${problems}"
  exit 2
fi

log "bump-submodule-pins: ${SOURCE} -> ${applicable} pins across ${repos} repos — ${current} already current, ${bumped} $([ "$DRY" = 1 ] && echo 'would be bumped' || echo 'bumped'), ${failed} could not be processed"
[ "$DRY" = 1 ] && log "DRY RUN: nothing was pushed, no PR was opened or closed."

if [ "$failed" -gt 0 ]; then
  note "could not process:${problems}"
  note "A consumer this sweep could not cover is a FAILURE, not a skip (home-infra#343) — fix and re-run."
  exit 1
fi
exit 0
