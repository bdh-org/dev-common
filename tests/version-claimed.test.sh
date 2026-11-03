#!/usr/bin/env bash
# version-claimed.test.sh -- the "Version claimed by another open PR" gate, which
# is now ONE file: .github/actions/version-guard/version-claimed.sh, the second
# step of the composite action that ci.yml, self-hosted-ci.yml and
# version-guard.yml each call (bdh-org/dev-common#255, #338;
# bdh-org/home-infra#674, #675).
#
# WHAT THE GATE IS FOR, and why the other half could not do it.
#
# "Version bumped" (tests/version-bumped.test.sh) compares a branch against its
# BASE. That sees a collision only once the other PR has MERGED. While both PRs
# are open, each one's base is untouched and each one is individually correct --
# so two branches cut from the same main each run `make bump-patch`, each writes
# the IDENTICAL VERSION line, and git merges an identical edit as AGREEMENT
# rather than as a conflict. Both land and one version silently never exists.
#
# Three of these in one afternoon, 2026-09-20, all in finzeug/heller, all fixed
# by hand. The middle one (#559) was a submodule bump carrying no version change
# at all, which would also have cut no tag, because tag-version.yml then
# triggered on `paths: ['Makefile']` and the Makefile would have been
# byte-identical (filter dropped fleet-wide in bdh-org/home-infra#625).
#
# WHAT THIS FILE USED TO DO, AND WHY IT NO LONGER DOES IT. The body was inline in
# all three workflows. This suite EXTRACTED it from each, ran every case against
# all three copies, and ended with a case asserting the three were BYTE-IDENTICAL
# -- because the SIBLING step's copies had drifted twice under a comment telling
# them not to (dev-common#182, #232), both times staying green because the cases
# compared exit codes and the divergence was in a MESSAGE.
#
# The byte-identity case is GONE, and that is the point of #338 rather than a loss
# of coverage: with one implementation there is nothing left for it to compare,
# and a test asserting a tautology is worse than no test. Two cases went with it
# -- "the token arrives by env" and "the secret is never interpolated" -- because
# both scanned the workflow YAML for an `env:` block that is no longer there.
# THEIR PROPERTY IS NOT DROPPED, only re-aimed: the action is now what must pass
# the token by env and the script is now what must carry no templating, and both
# are asserted below. That property is the whole reason #338 was split out of
# #235, so losing it to a file move would have been the one unacceptable outcome.
#
# WHAT REPLACES THE IDENTITY CASE is structural -- every workflow CALLS the
# action, no workflow still carries the logic inline, and (asserted in
# version-bumped.test.sh, which owns the job-shape cases for the same action) no
# workflow has grown a new JOB for it, because `ci / ci` is the required status
# check in nine consumer repos.
#
# The behavioural cases run the REAL script with `curl` stubbed on PATH -- not a
# re-implementation of its logic, which would pass while the action shipped
# something else.
#
# Usage:  bash tests/version-claimed.test.sh      (or: make test)

set -uo pipefail   # deliberately NOT -e: every case runs, then we report

HERE="$(cd "$(dirname "$0")" && pwd)"
ACTION_DIR="$HERE/../.github/actions/version-guard"
SCRIPT="$ACTION_DIR/version-claimed.sh"
ACTION_YML="$ACTION_DIR/action.yml"
# Every workflow that calls the action. A file that stops calling it fails the
# cases below rather than silently dropping out of coverage.
WORKFLOWS="ci.yml self-hosted-ci.yml version-guard.yml"
# The step NAME inside the action, which is what the log keys on.
STEP_NAME="Version claimed by another open PR"
# The only form that works from inside a `workflow_call`: a relative `uses: ./`
# resolves against the CALLING repo's checkout, where this action does not exist.
ACTION_REF="bdh-org/dev-common/.github/actions/version-guard@main"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass=0; fail=0
ok()    { echo "ok   - $CASE: $1"; pass=$((pass+1)); }
notok() { echo "NOT OK - $CASE: $1"; fail=$((fail+1)); }

# ------------------------------------------------------------ the action is --
CASE="the action exists"
if [ -s "$SCRIPT" ] && [ -s "$ACTION_YML" ]; then
  ok "version-claimed.sh and action.yml are both present and non-empty"
else
  notok "no version-claimed.sh at .github/actions/version-guard -- every case below is moot"
  echo; echo "passed: $pass   failed: $fail"; exit 1
fi

CASE="action.yml runs the script this file tests"
# Without this, action.yml could point at some other body and every behavioural
# case below would be green against a script nothing executes.
if grep -qF 'version-claimed.sh' "$ACTION_YML"; then
  ok "action.yml invokes version-claimed.sh"
else
  notok "action.yml does not mention version-claimed.sh -- the tested script is not the shipped one"
fi

CASE="the script parses as bash"
if bash -n "$SCRIPT" 2>"$TMP/syn"; then
  ok "version-claimed.sh is syntactically valid"
else
  notok "the shipped script does not parse:"; sed 's/^/         /' "$TMP/syn"
fi

CASE="the action still runs BOTH gates, in order"
# version-bumped.sh must not be displaced by its sibling: the action is one call
# site now, so a step lost here is a gate lost in every consumer at once, with
# nothing red to show it. Order matters too -- a branch whose version is wrong
# against its own base has nothing to learn yet about other PRs' versions.
if python3 -c 'import yaml' 2>/dev/null; then
  if python3 -I -c '
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
assert d["runs"]["using"] == "composite", d["runs"]["using"]
steps = d["runs"]["steps"]
runs = [s["run"] for s in steps]
assert len(steps) == 2, f"{len(steps)} steps, expected 2 (bumped then claimed)"
assert "version-bumped.sh" in runs[0], runs[0]
assert "version-claimed.sh" in runs[1], runs[1]
assert steps[1]["shell"] == "bash", steps[1].get("shell")
assert steps[1].get("name") == sys.argv[2], steps[1].get("name")
' "$ACTION_YML" "$STEP_NAME" 2>"$TMP/yamlerr"; then
    ok "two composite steps: version-bumped.sh then version-claimed.sh, the latter named '$STEP_NAME'"
  else
    notok "action.yml shape check failed:"; sed 's/^/         /' "$TMP/yamlerr"
  fi
else
  # PyYAML is a BONUS, not the gate -- same reasoning as version-bumped.test.sh:
  # a suite that goes red on whether the runner image ships a library is a suite
  # that gets ignored. Assert what can be asserted textually instead.
  if grep -qF 'version-bumped.sh' "$ACTION_YML" && grep -qF 'version-claimed.sh' "$ACTION_YML"; then
    ok "both scripts are invoked (no PyYAML here, so order was not checked)"
  else
    notok "action.yml does not invoke both scripts"
  fi
fi

# ---------------------------------------------------- the secret's handling --
# THE REASON #338 WAS SPLIT OUT OF #235. This half carries a token, and getting
# its delivery wrong either leaks it into a command echo or leaves every caller in
# the fleet warning "could not list open PRs" forever. These two cases are the
# re-aimed replacements for the workflow-scanning ones the move retired.
CASE="the token reaches the script by env, not in the command"
# A token in argv is visible in process listings and in the log's own command
# echo. `github.token`, not `secrets.GITHUB_TOKEN`: the `secrets` context is not
# available inside an action file at all.
if grep -qE 'GITHUB_TOKEN:[[:space:]]*\$\{\{[[:space:]]*github\.token[[:space:]]*\}\}' "$ACTION_YML"; then
  ok "action.yml sets env GITHUB_TOKEN from github.token"
else
  notok "action.yml does not set GITHUB_TOKEN from \${{ github.token }} -- the gate cannot list PRs, or the token is arriving some other way"
fi

CASE="the secret is never interpolated into the shell body"
if grep -qF '${{' "$SCRIPT"; then
  notok "version-claimed.sh contains \${{ ... }} -- it is shell, Actions does not expand a script file, and a templated secret would land in the log's command echo"
else
  ok "the script is plain shell, so what runs in CI is what runs here"
fi

CASE="the PR number and base ref reach the script by env"
# Same argument as BASE_REF in version-bumped.sh: passing them in rather than
# templating them into the body is what lets this file run the shipped script
# verbatim, and an extracted copy is how the old suite could pass while the
# workflow shipped something else.
missing_env=""
for v in PR_NUMBER BASE_REF; do
  grep -qE "^[[:space:]]*$v:[[:space:]]*\\\$\{\{" "$ACTION_YML" || missing_env="$missing_env $v"
done
if [ -z "$missing_env" ]; then
  ok "action.yml passes PR_NUMBER and BASE_REF from the github context"
else
  notok "action.yml does not set:$missing_env -- the gate has no PR to exclude or no base to narrow to"
fi

# --------------------------------------------------- every workflow calls it --
# Every line of a named step, from its `- name:` to the next step or the end of
# the job's steps. Used to assert no workflow kept an inline body.
step_block() { # workflow-file step-name
  awk -v name="      - name: $2" '
    $0 == name        { instep = 1; next }
    instep && /^      - / { exit }   # the next step
    instep && /^[^ ]/     { exit }   # dedented out of the job entirely
    instep                { print }
  ' "$1"
}

for WF_NAME in $WORKFLOWS; do
  WF="$HERE/../.github/workflows/$WF_NAME"
  if [ ! -f "$WF" ]; then
    CASE="[$WF_NAME] the workflow exists"
    notok "no such workflow -- WORKFLOWS names a file that is not here"
    continue
  fi

  CASE="[$WF_NAME] calls the shared action"
  if grep -qF "uses: $ACTION_REF" "$WF"; then
    ok "uses $ACTION_REF"
  else
    notok "$WF_NAME does not call the action -- it has either been unwired or gone back to a copy"
  fi

  CASE="[$WF_NAME] carries no inline copy of the gate"
  # The step name is gone from the workflows -- it is a step of the ACTION now --
  # so a `- name: $STEP_NAME` here means the inline body came back.
  if grep -qF "      - name: $STEP_NAME" "$WF"; then
    notok "the '$STEP_NAME' step is inline again -- the duplication #338 removed is back"
  else
    ok "no inline '$STEP_NAME' step"
  fi

  CASE="[$WF_NAME] the gate's logic is nowhere else in the file"
  # Catches the body pasted back under a DIFFERENT step name, which the case
  # above cannot see. Keyed on message text the gate owns outright.
  stray="$(grep -nF 'VERSION COLLISION WITH AN OPEN PR' "$WF" || true)"
  if [ -n "$stray" ]; then
    notok "the gate's own error text appears in $WF_NAME: $stray"
  else
    ok "no copy of the gate's messages in the workflow"
  fi

  CASE="[$WF_NAME] the call is not guarded away from pull requests"
  # The gate is inert outside a pull request and says so, but a caller that
  # dropped the `if:` would run it on every push to main -- where it would warn
  # about a non-numeric PR number forever. A caller that INVERTED it would never
  # run the gate at all, which is the silent direction.
  if step_block "$WF" "Version guard" | grep -qF "if: github.event_name == 'pull_request'"; then
    ok "the action call is guarded with if: github.event_name == 'pull_request'"
  else
    notok "no pull_request guard on the 'Version guard' step in $WF_NAME"
  fi
done

# ---------------------------------------------------------------- curl stub --
# The script reaches the API twice: once to list open PRs, once per PR to read
# that PR's Makefile. Both go through `curl` by NAME (not an absolute path),
# which is what makes a PATH stub possible -- and is worth preserving if the
# script is ever rewritten.
STUBBIN="$TMP/bin"
mkdir -p "$STUBBIN"
cat > "$STUBBIN/curl" <<'STUB'
#!/usr/bin/env bash
out=""; url=""; prev=""
for a in "$@"; do
  [ "$prev" = "-o" ] && out="$a"
  case "$a" in http://*|https://*) url="$a";; esac
  prev="$a"
done
case "$url" in
  *"/pulls?"*)
    st="${STUB_PRS_STATUS:-200}"
    if [ "$st" = "000" ]; then
      echo "curl: (6) Could not resolve host" >&2
      exit 1
    fi
    if [ "$st" = "200" ]; then
      cat "$STUB_PRS_JSON" > "$out"
    else
      printf '%s' "${STUB_PRS_BODY:-}" > "$out"
    fi
    printf '%s' "$st"
    exit 0 ;;
  *"/contents/Makefile?ref="*)
    sha="${url##*ref=}"
    if [ -f "$STUB_MK_DIR/$sha" ]; then
      cat "$STUB_MK_DIR/$sha" > "$out"
      printf '200'
    else
      printf '404'
    fi
    exit 0 ;;
esac
printf '000'
exit 1
STUB
chmod +x "$STUBBIN/curl"

export STUB_MK_DIR="$TMP/makefiles"
mkdir -p "$STUB_MK_DIR"

# A Makefile for PR head <sha>, carrying <version>.
mk() { printf 'VERSION=%s\n' "$2" > "$STUB_MK_DIR/$1"; }

# An open-PR list. Each arg is "number:sha:draft:title".
prs() {
  local out first=1
  out="$(mktemp --suffix=.json "$TMP/prs-XXXXXX")"
  { printf '['
    for spec in "$@"; do
      IFS=: read -r n sha draft title <<< "$spec"
      [ $first -eq 1 ] || printf ','
      first=0
      printf '{"number":%s,"draft":%s,"title":"%s","head":{"sha":"%s"}}' \
        "$n" "$draft" "$title" "$sha"
    done
    printf ']'
  } > "$out"
  echo "$out"
}

# The repo the gate runs IN: a working tree with a Makefile at $1.
workdir() {
  local d; d="$(mktemp -d "$TMP/wd-XXXXXX")"
  mkdir -p "$d"
  [ "$1" = "NOVERSION" ] && printf 'all:\n\techo hi\n' > "$d/Makefile" \
                         || printf 'VERSION=%s\n' "$1" > "$d/Makefile"
  echo "$d"
}

# Run the shipped script in $1, as PR number $2. PR_NUMBER and BASE_REF arrive by
# env exactly as action.yml sets them, which is why no substitution is needed.
run_step() { # workdir pr_number
  ( cd "$1" \
    && PATH="$STUBBIN:$PATH" \
       PR_NUMBER="$2" \
       BASE_REF="${BASE_REF_OVERRIDE-main}" \
       GITHUB_REPOSITORY="${GITHUB_REPOSITORY_OVERRIDE:-finzeug/heller}" \
       GITHUB_API_URL="https://api.github.com" \
       bash "$SCRIPT" 2>&1 )
}

export GITHUB_TOKEN="stub-token"
export STUB_PRS_STATUS=200
unset STUB_PRS_BODY 2>/dev/null || true

# ---------------------------------------------------------------- behaviour --
CASE="a version an EARLIER open PR already claims"
mk sha558 1.3.268
export STUB_PRS_JSON="$(prs '558:sha558:false:fix the thing')"
d=$(workdir 1.3.268)
if out=$(run_step "$d" 559); then
  notok "PR #559 carrying 1.3.268 PASSED while open PR #558 already carries it"
else
  case "$out" in
    *"VERSION COLLISION WITH AN OPEN PR"*)
      case "$out" in
        *"#558"*) ok "rejected, and NAMES the colliding PR (#558)" ;;
        *) notok "rejected but does not name the PR -- the fix is not obvious: $out" ;;
      esac ;;
    *) notok "rejected for some other reason: $out" ;;
  esac
fi

CASE="the collision message carries the re-bump recipe"
case "$out" in
  *"make bump-patch"*) ok "tells the author exactly how to fix it" ;;
  *) notok "no remedy in the message: $out" ;;
esac

# -- the tiebreak: only the LATER PR goes red ---------------------------------
CASE="the EARLIER PR of a colliding pair is not failed"
# Same fixture, seen from the other side. Failing both would deadlock a pair that
# is each other's only problem and block the PR that did nothing wrong, so the
# lowest number keeps the version and only the later one must move.
mk sha563 1.3.268
export STUB_PRS_JSON="$(prs '563:sha563:false:a later PR')"
d=$(workdir 1.3.268)
if out=$(run_step "$d" 559); then
  case "$out" in
    *"::warning"*"563"*) ok "passes, and still REPORTS the later PR rather than staying silent" ;;
    *) notok "passed but said nothing about #563 -- a silent pass: $out" ;;
  esac
else
  notok "the earlier PR of a colliding pair was failed -- both sides are now red: $out"
fi

# -- the ordinary green path --------------------------------------------------
CASE="an open PR on a different version"
mk sha558 1.3.267
export STUB_PRS_JSON="$(prs '558:sha558:false:unrelated')"
d=$(workdir 1.3.268)
if out=$(run_step "$d" 559); then ok "1.3.268 against an open 1.3.267 passes"
else notok "a non-colliding PR was rejected: $out"; fi

CASE="no other open PR"
export STUB_PRS_JSON="$(prs)"
d=$(workdir 1.3.268)
if out=$(run_step "$d" 559); then
  case "$out" in
    *uncontested*) ok "passes and says so" ;;
    *) notok "passed but reported nothing: $out" ;;
  esac
else notok "a lone PR was rejected: $out"; fi

CASE="the PR does not collide with ITSELF"
# The list the API returns includes this PR. Comparing against itself would make
# every single PR in the fleet red.
mk shaSelf 1.3.268
export STUB_PRS_JSON="$(prs '559:shaSelf:false:this very PR')"
d=$(workdir 1.3.268)
if out=$(run_step "$d" 559); then
  # Exit 0 alone is too weak: a PR that fails to exclude itself lands in the
  # "opened later" bucket, which only warns -- so the case stayed green under a
  # mutation that removed the exclusion entirely. Assert it found NOTHING.
  case "$out" in
    *uncontested*) ok "a PR is excluded from its own collision check" ;;
    *) notok "the PR saw ITSELF as another claimant: $out" ;;
  esac
else notok "the PR collided with itself: $out"; fi

# -- a draft still holds the number -------------------------------------------
CASE="a DRAFT PR still claims its version"
mk shaDraft 1.3.268
export STUB_PRS_JSON="$(prs '558:shaDraft:true:wip')"
d=$(workdir 1.3.268)
if out=$(run_step "$d" 559); then
  notok "a draft holding 1.3.268 was ignored -- it can be marked ready and merged at any time"
else
  case "$out" in
    *"(draft)"*) ok "rejected, and labels the claimant a draft so the author can judge" ;;
    *) notok "rejected but does not say the claimant is a draft: $out" ;;
  esac
fi

# -- clean skips, none of them silent -----------------------------------------
CASE="a repo that does not version here"
export STUB_PRS_JSON="$(prs '558:sha558:false:x')"
d=$(workdir NOVERSION)
if out=$(run_step "$d" 559); then
  case "$out" in
    *"no VERSION in Makefile"*) ok "skipped, and says why" ;;
    *) notok "passed silently instead of announcing the skip: $out" ;;
  esac
else notok "a repo with no VERSION was FAILED: $out"; fi

CASE="a token that cannot list PRs warns, and does not fail"
# This action is consumed at @main by the whole fleet. Hard-failing on a missing
# `pull-requests: read` would turn every caller red at once over a permission
# none of them had been asked for.
export STUB_PRS_STATUS=403
export STUB_PRS_BODY='{"message":"Resource not accessible by integration"}'
mk sha558 1.3.268
export STUB_PRS_JSON="$(prs '558:sha558:false:x')"
d=$(workdir 1.3.268)
if out=$(run_step "$d" 559); then
  case "$out" in
    *"pull-requests: read"*) ok "warns with the exact permission to grant, exit 0" ;;
    *) notok "warned without naming the remedy: $out" ;;
  esac
else
  notok "a permissions failure turned the whole check red: $out"
fi

CASE="the API's OWN words reach the log"
# Never a parser's summary. A 403 reading "Resource not accessible by
# integration" ends this in one step; a jq KeyError sends the reader somewhere
# else entirely.
case "$out" in
  *"Resource not accessible by integration"*) ok "the server's message is shown verbatim" ;;
  *) notok "the server's own error was swallowed: $out" ;;
esac

CASE="an unreachable API warns, and does not fail"
export STUB_PRS_STATUS=000
d=$(workdir 1.3.268)
if out=$(run_step "$d" 559); then ok "a network failure is a warning, not a red check"
else notok "a transient network failure failed the build: $out"; fi
export STUB_PRS_STATUS=200
unset STUB_PRS_BODY

CASE="no token at all"
# Unreachable while action.yml sets GITHUB_TOKEN from `github.token`, and kept
# anyway: an empty token is what a direct invocation hands over, and
# `curl -H "Authorization: Bearer "` returns a 401 that explains nothing.
mk sha558 1.3.268
export STUB_PRS_JSON="$(prs '558:sha558:false:x')"
d=$(workdir 1.3.268)
if out=$(GITHUB_TOKEN="" run_step "$d" 559); then
  case "$out" in
    *"pull-requests: read"*) ok "warns with the remedy rather than failing" ;;
    *) notok "warned without naming the remedy: $out" ;;
  esac
else notok "a missing token failed the build: $out"; fi
export GITHUB_TOKEN="stub-token"

CASE="a PR whose Makefile cannot be read is not compared"
# A fork, a deleted branch, a repo with no Makefile on that ref. Unreadable must
# not mean "colliding", or an unrelated PR turns this one red.
export STUB_PRS_JSON="$(prs '558:shaMissing:false:gone')"
d=$(workdir 1.3.268)
if out=$(run_step "$d" 559); then
  case "$out" in
    *"not compared"*) ok "skipped that PR, and said so" ;;
    *) notok "passed without noting the PR it could not read: $out" ;;
  esac
else notok "an unreadable Makefile was treated as a collision: $out"; fi

CASE="no PR number at all"
# Reachable only from a caller that wired the action onto a push, since all three
# workflows guard the step with `if: github.event_name == 'pull_request'`. The
# gate must not query the API for PR "" and must not pass silently.
mk sha558 1.3.268
export STUB_PRS_JSON="$(prs '558:sha558:false:x')"
d=$(workdir 1.3.268)
if out=$(run_step "$d" ""); then
  case "$out" in
    *"not numeric"*) ok "skipped, and says the PR number was not usable" ;;
    *) notok "passed without saying why there was nothing to compare: $out" ;;
  esac
else notok "an empty PR number failed the build instead of skipping: $out"; fi

CASE="no base ref at all"
# Same shape, the other missing context. Without a base the open-PR query cannot
# be narrowed to this lineage, so comparing would be wrong rather than merely
# incomplete.
d=$(workdir 1.3.268)
if out=$(BASE_REF_OVERRIDE="" run_step "$d" 559); then
  case "$out" in
    *"No repository/base context"*) ok "skipped, and says which context was missing" ;;
    *) notok "passed without saying why there was nothing to compare: $out" ;;
  esac
else notok "an empty BASE_REF failed the build instead of skipping: $out"; fi

# The gate is inert in the two workflows that DECLARE permissions unless the
# scope is declared too: a workflow-level block REPLACES the caller's grant rather
# than adding to it, so the gate would warn "could not list open PRs" on every PR
# forever. ci.yml declares no block and inherits the caller's, so it is
# deliberately not in this list.
#
# THIS CASE SURVIVES THE MOVE TO THE ACTION (bdh-org/dev-common#338): an action
# has no `permissions:` block of its own, so the scope is still declared per
# workflow and is the one part of this gate that did NOT converge.
CASE="[all] the workflows that restrict permissions grant pull-requests: read"
missing=""
for WF_NAME in self-hosted-ci.yml version-guard.yml; do
  f="$HERE/../.github/workflows/$WF_NAME"
  if ! awk '/^permissions:/{p=1;next} p&&/^[^ ]/{exit} p' "$f" \
       | grep -q 'pull-requests:[[:space:]]*read'; then
    missing="$missing $WF_NAME"
  fi
done
if [ -z "$missing" ]; then
  ok "both restricting workflows grant the scope the gate needs"
else
  notok "no 'pull-requests: read' in:$missing -- the gate can never run there"
fi

echo
echo "passed: $pass   failed: $fail"
[ "$fail" -eq 0 ]
