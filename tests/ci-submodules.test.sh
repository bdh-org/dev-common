#!/usr/bin/env bash
# ci-submodules.test.sh -- the CI gate for the submodule-hydration step embedded
# in .github/workflows/self-hosted-ci.yml (bdh-org/dev-common#170).
#
# That workflow used to fetch `common` with no token at all and mint the extras'
# token for `github.repository_owner` -- the caller repo's org. Both are the
# defect dev-common#169 fixed in the agent workflows, pointing the other way:
# `common` is bdh-org/dev-common however finzeug the caller is, and panoptikon /
# heller / slingshot vendor finzeug's lib/* alongside bdh-org's common and
# stack-common. Neither org is the right default; the URL in .gitmodules is.
#
# What this workflow does NOT share with the agent one is `--recursive`: it
# initialises a SELECTED path list and deinits everything else, so that a test
# guarded on "is this submodule checked out?" cannot run against whatever an
# earlier agent job left on the shared runner workspace (finzeug/heller#356).
# That selection is as much of this step's contract as the org resolution, so it
# is asserted here too -- reusing #169's hydration verbatim would silently undo
# it, and nothing else would notice.
#
# The script is embedded in the workflow rather than called from a file because
# a reusable workflow runs against the CALLER's checkout -- there is no
# dev-common on disk to call a script from, and hydration is the step that puts
# it there. So the cases below run the REAL extracted script: as a library
# (HYDRATE_LIB_ONLY=1) for the .gitmodules parsing, and end to end against
# throwaway local repos.
#
# Usage:  bash tests/ci-submodules.test.sh      (or: make test)

set -uo pipefail   # deliberately NOT -e: every case runs, then we report

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WF_CI="$REPO_ROOT/.github/workflows/self-hosted-ci.yml"
WF_AGENT="$REPO_ROOT/.github/workflows/agent-issue-to-pr.yml"
STEP_NAME='Hydrate the selected submodules (per-submodule org tokens)'
AGENT_STEP_NAME='Hydrate submodules (per-submodule org tokens)'

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

# The named step's `run: |` body, dedented out of a workflow.
extract() { # workflow-file step-name
  awk -v name="      - name: $2" '
    $0 == name          { instep = 1; next }
    instep && /^        run: \|$/ { inbody = 1; instep = 0; next }
    inbody {
      if ($0 == "") { print ""; next }
      if ($0 !~ /^          /) { exit }
      print substr($0, 11)
    }
  ' "$1"
}

# --- 1. the step is there, parses, and does not read the parent's org -------

CASE="embedded script"
SCRIPT="$TMP/hydrate-ci.sh"
extract "$WF_CI" "$STEP_NAME" > "$SCRIPT"

if [ -s "$SCRIPT" ]; then ok "self-hosted-ci.yml carries a '$STEP_NAME' step"
else notok "self-hosted-ci.yml has no '$STEP_NAME' step body"; fi

if bash -n "$SCRIPT" 2>"$TMP/syntax"; then ok "the embedded script parses"
else notok "bash -n failed:"; sed 's/^/         /' "$TMP/syntax"; fi

body="$(cat "$SCRIPT")"
# The bug itself, in both of the forms it took here.
assert_absent "$body" 'repository_owner' \
  "no parent-org rewrite (that is dev-common#170)"
assert_absent "$body" 'github.com/bdh-org/.insteadOf' \
  "no hardcoded bdh-org rewrite (that is the same bug inverted, panoptikon#700)"
assert_absent "$body" 'update --init --recursive' \
  "still selective, not recursive -- #169's hydration must not be pasted in whole (heller#356)"
assert_contains "$body" 'submodule update --init --force -- "${WANT[@]}"' \
  "and the update is limited to the path list it built"

# sm_map / sm_org are dev-common#169's, and their coverage lives in
# tests/hydrate-submodules.test.sh. Keeping the two copies textually identical is
# what lets that coverage stand for this one; a drifting copy is an untested one.
CASE="shared with the agent workflow"
lib() { # script -> the code (comments and blanks dropped) up to the LIB_ONLY guard
  awk '/HYDRATE_LIB_ONLY/ { print; exit } { print }' "$1" \
    | grep -vE '^[[:space:]]*(#|$)'
}
extract "$WF_AGENT" "$AGENT_STEP_NAME" > "$TMP/hydrate-agent.sh"
if [ -s "$TMP/hydrate-agent.sh" ]; then
  if diff -u <(lib "$TMP/hydrate-agent.sh") <(lib "$SCRIPT") > "$TMP/drift.diff"; then
    ok "sm_map/sm_org are byte-identical to the agent workflow's"
  else
    notok "the shared hydration library has drifted from agent-issue-to-pr.yml:"
    sed 's/^/         /' "$TMP/drift.diff"
  fi
else
  notok "could not extract '$AGENT_STEP_NAME' from agent-issue-to-pr.yml"
fi

# --- 2. sm_map / sm_org, the real functions ---------------------------------

# shellcheck disable=SC1090
HYDRATE_LIB_ONLY=1 . "$SCRIPT" || { echo "FATAL: could not source the extracted script"; exit 1; }
# The script opens with `set -euo pipefail`, which sourcing leaks into THIS
# shell -- and this harness deliberately runs every case rather than dying on
# the first failure. Put the options back.
set +e +u +o pipefail
set -uo pipefail

CASE="sm_org"
assert_eq "bdh-org" "$(sm_org 'https://github.com/bdh-org/dev-common.git')" "https URL -> org"
assert_eq "finzeug" "$(sm_org 'git@github.com:finzeug/ledger-io.git')"      "ssh URL -> org"
assert_eq ""        "$(sm_org '../sibling.git')"                           "relative URL -> no org"

CASE="sm_map"
FIX="$TMP/fixture"
mkdir -p "$FIX"
cat > "$FIX/.gitmodules" <<'EOF'
[submodule "common"]
	path = common
	url = https://github.com/bdh-org/dev-common.git
[submodule "lib/ledger-io"]
	path = lib/ledger-io
	url = https://github.com/finzeug/ledger-io.git
EOF
map="$( cd "$FIX" && sm_map )"
orgs="$(printf '%s\n' "$map" | cut -f2 | while IFS= read -r u; do sm_org "$u"; done | sort -u | tr '\n' ' ')"
assert_eq "bdh-org finzeug " "$orgs" "a two-org repo yields BOTH orgs, not just the caller's"

# --- 3. end to end, against throwaway local repos ---------------------------

# A bare repo with one commit.
mkrepo() { # name
  local name="$1" w="$TMP/build/$1"
  # -b main on the BARE repo too: its HEAD is what a clone checks out, and a
  # bare repo defaulting to master hands back an empty working tree.
  git init -q --bare -b main "$TMP/remotes/$name.git"
  mkdir -p "$w"; git init -q -b main "$w"; echo "$name" > "$w/file"
  git -C "$w" add -A; git -C "$w" commit -qm init
  git -C "$w" push -q "$TMP/remotes/$name.git" main
}

# Runs the REAL script in $1 with a stub minter, capturing everything.
run_hydrate() { # workdir [extra-submodules] -> exit status; output in $OUT,
                #   orgs minted in $MINT_LOG, every git command line in $GIT_LOG
  local d="$1" rc
  MINT_LOG="$TMP/minted.$(basename "$d")"; : > "$MINT_LOG"
  GIT_LOG="$TMP/gitcalls.$(basename "$d")";  : > "$GIT_LOG"
  OUT="$( cd "$d" && PATH="$TMP/shim:$PATH" MINT="$TMP/mint-stub.sh" EXTRA="${2:-}" \
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
# which orgs were asked for -- the whole point of dev-common#169/#170.
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

CASE="e2e: only the selected paths"
# The heller#356 shape: a repo whose submodules include one this CI run does not
# want. It must be gone, and the wanted ones present -- whatever an earlier agent
# job left on the persistent workspace.
mkrepo dev-common
mkrepo ledger-io
mkrepo unwanted
w="$TMP/build/consumer"; mkdir -p "$w"; git init -q -b main "$w"
git init -q --bare -b main "$TMP/remotes/consumer.git"
echo consumer > "$w/file"
for s in "dev-common common" "ledger-io lib/ledger-io" "unwanted vendor/unwanted"; do
  set -- $s
  git -C "$w" submodule add -q "$TMP/remotes/$1.git" "$2" >/dev/null 2>&1
done
git -C "$w" add -A; git -C "$w" commit -qm init
git -C "$w" push -q "$TMP/remotes/consumer.git" main

git clone -q "$TMP/remotes/consumer.git" "$TMP/co-sel"
# Leave vendor/unwanted populated, the way an agent job's --recursive init would.
git -C "$TMP/co-sel" submodule update --init --recursive -- vendor/unwanted >/dev/null 2>&1
if run_hydrate "$TMP/co-sel" "lib/ledger-io"; then ok "hydrates the selected paths"
else notok "hydration failed:"; printf '%s\n' "$OUT" | sed 's/^/         /'; fi
assert_contains "$OUT" "submodule hydration OK" "reports success explicitly"
if [ -f "$TMP/co-sel/common/file" ]; then ok "common is populated"
else notok "common is empty"; fi
if [ -f "$TMP/co-sel/lib/ledger-io/file" ]; then ok "the extra submodule is populated"
else notok "lib/ledger-io is empty -- the extras were not initialised"; fi
if [ -f "$TMP/co-sel/vendor/unwanted/file" ]; then
  notok "vendor/unwanted survived -- an earlier job's checkout is still on disk (heller#356)"
else ok "a submodule this run did not ask for is deinited, not inherited"; fi
assert_eq "" "$(cat "$MINT_LOG")" "a local (non-GitHub) URL costs no mint attempt"

CASE="e2e: emptied worktree, .git intact"
# THE panoptikon/ratecraft SHAPE (dev-common#176), and the one the first version of this
# guard could not see. On the persistent runner a submodule directory can lose every tracked
# file while .git and HEAD survive. In that state:
#
#   * `git submodule status` prints a LEADING SPACE -- not '-' and not '+' -- because HEAD
#     still equals the pin. The status-only guard therefore passes.
#   * `git submodule update --init` is a NO-OP for the same reason: it compares HEAD to the
#     pin and never looks at the working tree.
#
# So hydration reported OK and pip failed two steps later with "Directory lib/ratecraft is not
# installable", which sends the reader to ratecraft's packaging -- a dead end, since the
# pinned commit does contain pyproject.toml.
mkrepo dev-common
mkrepo ratecraft
w="$TMP/build/empties"; mkdir -p "$w"; git init -q -b main "$w"
git init -q --bare -b main "$TMP/remotes/empties.git"
echo consumer > "$w/file"
for s in "dev-common common" "ratecraft lib/ratecraft"; do
  set -- $s
  git -C "$w" submodule add -q "$TMP/remotes/$1.git" "$2" >/dev/null 2>&1
done
git -C "$w" add -A; git -C "$w" commit -qm init
git -C "$w" push -q "$TMP/remotes/empties.git" main

git clone -q "$TMP/remotes/empties.git" "$TMP/co-empty"
git -C "$TMP/co-empty" submodule update --init -- lib/ratecraft >/dev/null 2>&1
# Delete the tracked files but keep .git -- exactly what was on forge.
find "$TMP/co-empty/lib/ratecraft" -mindepth 1 -maxdepth 1 ! -name .git -exec rm -rf {} +
# Prove the fixture really is the blind spot before asserting the fix handles it.
if git -C "$TMP/co-empty" submodule status -- lib/ratecraft | grep -qE '^[-+]'; then
  notok "fixture is wrong: status already flags this, so it is not the blind spot"
else ok "fixture reproduces it: status reports the emptied submodule as clean"; fi

if run_hydrate "$TMP/co-empty" "lib/ratecraft"; then
  if [ -f "$TMP/co-empty/lib/ratecraft/file" ]; then
    ok "--force re-checks-out an emptied worktree instead of no-opping"
  else
    notok "hydration reported success over an EMPTY directory -- the exact dev-common#176 bug"
  fi
else
  # Failing loudly is also acceptable; silently succeeding is not.
  assert_contains "$OUT" "EMPTY" "if it cannot restore it, it says the tree is empty"
fi

CASE="e2e: an unrequested path"
if run_hydrate "$TMP/co-sel" "lib/nope"; then ok "an extra that is not a submodule does not fail the run"
else notok "failed on an unknown extra-submodules path:"; printf '%s\n' "$OUT" | sed 's/^/         /'; fi
assert_contains "$OUT" "::warning::lib/nope is not a submodule" "says so rather than failing opaquely"

CASE="e2e: two orgs, unhydratable"
# The panoptikon shape: `common` in bdh-org and an extra in finzeug, called from
# a repo in whichever org -- so a per-caller-org token can only ever cover half
# of them. Their URLs are unservable, so the run must also fail loudly: a
# submodule this workflow asked for and did not populate must never be handed on
# as an empty directory (home-infra#343, home-infra#359).
w="$TMP/build/consumer"
git -C "$w" config -f .gitmodules submodule.common.url https://github.com/bdh-org/dev-common-does-not-exist.git
git -C "$w" config -f .gitmodules submodule.lib/ledger-io.url https://github.com/finzeug/ledger-io-does-not-exist.git
git -C "$w" commit -qam "point the submodules at unreachable URLs"
git -C "$w" push -qf "$TMP/remotes/consumer.git" main

git clone -q "$TMP/remotes/consumer.git" "$TMP/co-bad"
if run_hydrate "$TMP/co-bad" "lib/ledger-io"; then
  notok "exited 0 with submodules it never populated"
  printf '%s\n' "$OUT" | sed 's/^/         /'
else
  ok "fails the run rather than handing on an empty directory"
fi
assert_eq "bdh-org finzeug" "$(sort -u "$MINT_LOG" | tr '\n' ' ' | sed 's/ $//')" \
  "mints a token for EVERY org named in .gitmodules, not just the caller's"
assert_eq "2" "$(wc -l < "$MINT_LOG")" "and mints each org exactly once, however many submodules it owns"
gitlog="$(cat "$GIT_LOG")"
for o in finzeug bdh-org; do
  assert_contains "$gitlog" \
    "url.https://x-access-token:stub-token-for-${o}@github.com/${o}/.insteadOf=https://github.com/${o}/" \
    "the ${o} token reaches git as a rewrite for ${o} URLs"
done
assert_absent "$gitlog" "stub-token-for-finzeug@github.com/bdh-org/" \
  "no org is fetched with another org's token"
# vendor/unwanted DOES appear in the log -- as the argument to `deinit`. What
# must never happen is it appearing on the fetch.
assert_absent "$(grep -F 'submodule update --init' "$GIT_LOG" || true)" "vendor/unwanted" \
  "and the deinited submodule is never fetched"
assert_contains "$OUT" "lib/ledger-io" "names the submodule that is missing"
assert_contains "$OUT" "org finzeug" "names the org whose token it needed"
assert_contains "$OUT" "::error::" "annotates the failure for the GitHub UI"

# --- report -----------------------------------------------------------------

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
