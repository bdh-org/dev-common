#!/usr/bin/env bash
# hydrate-submodules.test.sh -- the CI gate for the submodule-hydration step
# embedded in .github/workflows/agent-issue-to-pr.yml and agent-pr-revise.yml
# (bdh-org/dev-common#169).
#
# That step decides whether the headless agent runs against a complete checkout
# or a partial one, and it has now failed in BOTH directions within one day:
# hydrating everything with a bdh-org token left finzeug/panoptikon#700 dead 11
# seconds in, and hydrating with the parent repo's org token left every bdh-org
# nested submodule uninitialised across the fleet. Neither org is the right
# default; the URL in .gitmodules is. These assertions encode that.
#
# The step's script is embedded verbatim in two workflows because a reusable
# workflow runs against the CALLER's checkout -- there is no dev-common on disk
# to call a script from, and hydration is the step that would put it there. So
# the two copies must not drift, which is the first case below. Everything else
# runs the REAL extracted script: as a library (HYDRATE_LIB_ONLY=1) for the
# .gitmodules parsing, and end to end against throwaway local repos.
#
# Usage:  bash tests/hydrate-submodules.test.sh      (or: make test)

set -uo pipefail   # deliberately NOT -e: every case runs, then we report

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WF_ISSUE="$REPO_ROOT/.github/workflows/agent-issue-to-pr.yml"
WF_REVISE="$REPO_ROOT/.github/workflows/agent-pr-revise.yml"
STEP_NAME='Hydrate submodules (per-submodule org tokens)'

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

# file:// submodule clones are refused since CVE-2022-39253; the fixtures below
# are all local repos, so allow it for the test's git invocations AND for the
# ones the script makes (GIT_CONFIG_* is inherited).
export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=protocol.file.allow GIT_CONFIG_VALUE_0=always
export GIT_TERMINAL_PROMPT=0   # never block on a credential prompt
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t

# The extracted script, dedented out of a workflow's `run: |` block.
extract() { # workflow-file
  awk -v name="      - name: $STEP_NAME" '
    $0 == name          { instep = 1; next }
    instep && /^        run: \|$/ { inbody = 1; instep = 0; next }
    inbody {
      if ($0 == "") { print ""; next }
      if ($0 !~ /^          /) { exit }
      print substr($0, 11)
    }
  ' "$1"
}

# --- 1. the two embedded copies are one script -----------------------------

CASE="embedded copies"
SCRIPT="$TMP/hydrate.sh"
extract "$WF_ISSUE" > "$SCRIPT"
extract "$WF_REVISE" > "$TMP/hydrate-revise.sh"

if [ -s "$SCRIPT" ]; then ok "agent-issue-to-pr.yml carries a '$STEP_NAME' step"
else notok "agent-issue-to-pr.yml has no '$STEP_NAME' step body"; fi

if diff -u "$SCRIPT" "$TMP/hydrate-revise.sh" > "$TMP/drift.diff"; then
  ok "agent-pr-revise.yml embeds the identical script"
else
  notok "the two embedded copies have drifted:"; sed 's/^/         /' "$TMP/drift.diff"
fi

if bash -n "$SCRIPT" 2>"$TMP/syntax"; then ok "the embedded script parses"
else notok "bash -n failed:"; sed 's/^/         /' "$TMP/syntax"; fi

# The bug itself: one org, hardcoded, applied to every submodule.
body="$(cat "$SCRIPT")"
assert_absent "$body" 'github.com/bdh-org/.insteadOf' \
  "no hardcoded bdh-org rewrite (that is finzeug/panoptikon#700)"
assert_absent "$body" 'repository_owner' \
  "no parent-org rewrite (that is the same bug inverted)"

# --- 2. sm_map / sm_org, the real functions --------------------------------

# shellcheck disable=SC1090
HYDRATE_LIB_ONLY=1 . "$SCRIPT" || { echo "FATAL: could not source the extracted script"; exit 1; }
# The script opens with `set -euo pipefail`, which sourcing leaks into THIS
# shell -- and this harness deliberately runs every case rather than dying on
# the first failure. Put the options back.
set +e +u +o pipefail
set -uo pipefail

CASE="sm_org"
assert_eq "bdh-org"  "$(sm_org 'https://github.com/bdh-org/dev-common.git')" "https URL -> org"
assert_eq "finzeug"  "$(sm_org 'git@github.com:finzeug/ledger-io.git')"      "ssh URL -> org"
assert_eq ""         "$(sm_org '../sibling.git')"                           "relative URL -> no org"
assert_eq ""         "$(sm_org 'https://gitlab.com/x/y.git')"               "non-GitHub URL -> no org"
assert_eq ""         "$(sm_org '')"                                         "empty URL -> no org"

CASE="sm_map"
FIX="$TMP/fixture"
mkdir -p "$FIX/stack-common"
cat > "$FIX/.gitmodules" <<'EOF'
[submodule "common"]
	path = common
	url = https://github.com/bdh-org/dev-common.git
[submodule "stack-common"]
	path = stack-common
	url = https://github.com/bdh-org/home-stack-common.git
[submodule "lib/ledger-io"]
	path = lib/ledger-io
	url = https://github.com/finzeug/ledger-io.git
EOF
# stack-common vendors dev-common again, one level down -- the nested case that
# only becomes visible after its parent is checked out.
cat > "$FIX/stack-common/.gitmodules" <<'EOF'
[submodule "common"]
	path = common
	url = https://github.com/bdh-org/dev-common.git
EOF

map="$( cd "$FIX" && sm_map )"
assert_contains "$map" "$(printf 'lib/ledger-io\thttps://github.com/finzeug/ledger-io.git')" \
  "maps a top-level submodule to its URL"
assert_contains "$map" "$(printf 'stack-common/common\thttps://github.com/bdh-org/dev-common.git')" \
  "prefixes a nested path the way 'submodule status --recursive' reports it"
assert_eq "4" "$(printf '%s\n' "$map" | grep -c .)" "every declared submodule is mapped"

orgs="$(printf '%s\n' "$map" | cut -f2 | while IFS= read -r u; do sm_org "$u"; done | sort -u | tr '\n' ' ')"
assert_eq "bdh-org finzeug " "$orgs" "a two-org repo yields BOTH orgs, not just the parent's"

# --- 3. end to end, against throwaway local repos ---------------------------

# A bare repo with one commit, plus optional .gitmodules content.
mkrepo() { # name [gitmodules-content]
  local name="$1" gm="${2:-}" w="$TMP/build/$1"
  # -b main on the BARE repo too: its HEAD is what a clone checks out, and a
  # bare repo defaulting to master hands back an empty working tree.
  git init -q --bare -b main "$TMP/remotes/$name.git"
  mkdir -p "$w"; git init -q -b main "$w"; echo "$name" > "$w/file"
  if [ -n "$gm" ]; then printf '%s' "$gm" > "$w/.gitmodules"; fi
  git -C "$w" add -A; git -C "$w" commit -qm init
  git -C "$w" push -q "$TMP/remotes/$name.git" main
}

# Runs the REAL script in $1 with a stub minter, capturing everything.
run_hydrate() { # workdir -> exit status; output in $OUT, orgs minted in $MINT_LOG,
                #                       every git command line in $GIT_LOG
  local d="$1" rc
  MINT_LOG="$TMP/minted.$(basename "$d")"; : > "$MINT_LOG"
  GIT_LOG="$TMP/gitcalls.$(basename "$d")";  : > "$GIT_LOG"
  OUT="$( cd "$d" && PATH="$TMP/shim:$PATH" MINT="$TMP/mint-stub.sh" \
            MINT_LOG="$MINT_LOG" GIT_LOG="$GIT_LOG" bash "$SCRIPT" 2>&1 )"; rc=$?
  return $rc
}

# A `git` on PATH that records how the script invoked it, then delegates. The
# per-org rewrite is passed with `git -c` (so no token is ever written to a
# config file), which makes the argv the only place its correctness is visible.
mkdir -p "$TMP/shim"
cat > "$TMP/shim/git" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "\$GIT_LOG"
exec "$(command -v git)" "\$@"
EOF
chmod +x "$TMP/shim/git"

cat > "$TMP/mint-stub.sh" <<'EOF'
#!/usr/bin/env bash
# stands in for /srv/github-runner/bin/mint-coder-app-token.sh, and records
# which orgs were asked for -- the whole point of dev-common#169.
printf '%s\n' "$1" >> "$MINT_LOG"
printf '::add-mask::%s\n' "stub-token-for-$1"
printf 'coder_token=stub-token-for-%s\n' "$1" >> "$GITHUB_OUTPUT"
EOF
chmod +x "$TMP/mint-stub.sh"

mkdir -p "$TMP/remotes" "$TMP/build"

CASE="e2e: no submodules"
mkrepo plain
git clone -q "$TMP/remotes/plain.git" "$TMP/co-plain"
if run_hydrate "$TMP/co-plain"; then ok "a repo with no submodules succeeds and mints nothing"
else notok "failed on a repo with no submodules:"; printf '%s\n' "$OUT" | sed 's/^/         /'; fi
assert_eq "" "$(cat "$MINT_LOG")" "no token minted when there is nothing to hydrate"

CASE="e2e: nested submodules hydrate"
mkrepo leaf
mkrepo mid "$(printf '[submodule "leaf"]\n\tpath = leaf\n\turl = %s/remotes/leaf.git\n' "$TMP")"
mkrepo top "$(printf '[submodule "mid"]\n\tpath = mid\n\turl = %s/remotes/mid.git\n' "$TMP")"
# record the real gitlinks (mkrepo only wrote .gitmodules)
w="$TMP/build/mid"; git -C "$w" -c protocol.file.allow=always submodule add -q "$TMP/remotes/leaf.git" leaf >/dev/null 2>&1
git -C "$w" commit -qam "add leaf"; git -C "$w" push -qf "$TMP/remotes/mid.git" main
w="$TMP/build/top"; git -C "$w" -c protocol.file.allow=always submodule add -q "$TMP/remotes/mid.git" mid >/dev/null 2>&1
git -C "$w" commit -qam "add mid"; git -C "$w" push -qf "$TMP/remotes/top.git" main

git clone -q "$TMP/remotes/top.git" "$TMP/co-top"
if run_hydrate "$TMP/co-top"; then ok "hydrates a nested submodule tree"
else notok "hydration failed:"; printf '%s\n' "$OUT" | sed 's/^/         /'; fi
assert_contains "$OUT" "submodule hydration OK" "reports success explicitly"
if [ -f "$TMP/co-top/mid/leaf/file" ]; then ok "the NESTED submodule is populated"
else notok "mid/leaf is empty -- --recursive did not reach it"; fi

CASE="e2e: two orgs, unhydratable"
# The panoptikon shape: submodules in TWO orgs, neither of which is the parent
# repo's. Their URLs are unservable, so the run must also fail loudly -- the
# failure this step must never swallow (home-infra#343, home-infra#359).
w="$TMP/build/top"
add_broken() { # path url
  git -C "$w" -c protocol.file.allow=always submodule add -q -- "$TMP/remotes/leaf.git" "$1" >/dev/null 2>&1
  git -C "$w" config -f .gitmodules "submodule.$1.url" "$2"
}
add_broken lib/ledger-io https://github.com/finzeug/ledger-io-does-not-exist.git
add_broken common       https://github.com/bdh-org/dev-common-does-not-exist.git
git -C "$w" commit -qam "add unreachable submodules"; git -C "$w" push -qf "$TMP/remotes/top.git" main

git clone -q "$TMP/remotes/top.git" "$TMP/co-bad"
if run_hydrate "$TMP/co-bad"; then
  notok "exited 0 with submodules it never populated"
  printf '%s\n' "$OUT" | sed 's/^/         /'
else
  ok "fails the run rather than handing on an empty directory"
fi
assert_eq "bdh-org finzeug" "$(sort -u "$MINT_LOG" | tr '\n' ' ' | sed 's/ $//')" \
  "mints a token for EVERY org named in .gitmodules"
assert_eq "2" "$(wc -l < "$MINT_LOG")" "and mints each org exactly once, however many submodules it owns"
gitlog="$(cat "$GIT_LOG")"
for o in finzeug bdh-org; do
  assert_contains "$gitlog" \
    "url.https://x-access-token:stub-token-for-${o}@github.com/${o}/.insteadOf=https://github.com/${o}/" \
    "the ${o} token reaches git as a rewrite for ${o} URLs"
done
assert_absent "$gitlog" "stub-token-for-finzeug@github.com/bdh-org/" \
  "no org is fetched with another org's token"
assert_contains "$OUT" "lib/ledger-io" "names the submodule that is missing"
assert_contains "$OUT" "org finzeug" "names the org whose token it needed"
assert_contains "$OUT" "::error::" "annotates the failure for the GitHub UI"

# --- report -----------------------------------------------------------------

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
