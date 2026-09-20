#!/usr/bin/env bash
# version-claimed.test.sh -- the "Version claimed by another open PR" step, in
# ALL THREE workflows that embed it: .github/workflows/ci.yml,
# self-hosted-ci.yml and version-guard.yml (bdh-org/dev-common#255,
# bdh-org/home-infra#674, #675).
#
# WHAT THE STEP IS FOR, and why the existing gate could not do it.
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
# at all, which would also have cut no tag, because tag-version.yml triggers on
# `paths: ['Makefile']` and the Makefile would have been byte-identical.
#
# THE CASES RUN THE REAL STEP BODY, extracted from the workflow, with `curl`
# stubbed on PATH -- not a re-implementation of its logic, which would pass while
# the workflow shipped something else. Same discipline as version-bumped.test.sh,
# for the same reason: a comment cannot make three files agree, and these files
# have now drifted twice under a comment telling them not to (dev-common#182,
# #232).
#
# Usage:  bash tests/version-claimed.test.sh      (or: make test)

set -uo pipefail   # deliberately NOT -e: every case runs, then we report

HERE="$(cd "$(dirname "$0")" && pwd)"
WORKFLOWS="ci.yml self-hosted-ci.yml version-guard.yml"
STEP_NAME="Version claimed by another open PR"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass=0; fail=0
ok()    { echo "ok   - $CASE: $1"; pass=$((pass+1)); }
notok() { echo "NOT OK - $CASE: $1"; fail=$((fail+1)); }

# Same extractor as version-bumped.test.sh. The step carries an `env:` block
# between `name:` and `run: |`; those lines match neither pattern, so they are
# skipped rather than captured.
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

# ---------------------------------------------------------------- curl stub --
# The step reaches the API twice: once to list open PRs, once per PR to read
# that PR's Makefile. Both go through `curl` by NAME (not an absolute path),
# which is what makes a PATH stub possible -- and is worth preserving if the
# step is ever rewritten.
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
  local out="$TMP/prs-$RANDOM.json" first=1
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

# The repo the step runs IN: a working tree with a Makefile at $1.
workdir() {
  local d="$TMP/wd-$RANDOM"
  mkdir -p "$d"
  [ "$1" = "NOVERSION" ] && printf 'all:\n\techo hi\n' > "$d/Makefile" \
                         || printf 'VERSION=%s\n' "$1" > "$d/Makefile"
  echo "$d"
}

# Run the extracted step in $1, as PR number $2.
run_step() { # workdir pr_number
  ( cd "$1" \
    && PATH="$STUBBIN:$PATH" \
       GITHUB_REPOSITORY="${GITHUB_REPOSITORY_OVERRIDE:-finzeug/heller}" \
       GITHUB_API_URL="https://api.github.com" \
       bash "$SCRIPT_FOR" "$2" 2>&1 )
}

for WF_NAME in $WORKFLOWS; do
  WF="$HERE/../.github/workflows/$WF_NAME"
  if [ ! -f "$WF" ]; then
    CASE="[$WF_NAME] the workflow exists"
    notok "no such workflow -- WORKFLOWS names a file that is not here"
    continue
  fi

  SCRIPT="$TMP/version-claimed-$WF_NAME.sh"
  extract "$WF" "$STEP_NAME" > "$SCRIPT"

  CASE="[$WF_NAME] the step is extractable"
  if [ -s "$SCRIPT" ]; then ok "$WF_NAME carries a '$STEP_NAME' step with a body"
  else notok "$WF_NAME has no '$STEP_NAME' step -- renamed or removed"; continue; fi

  # The step reads the token from the environment rather than from an argv
  # interpolation, so a secret never lands in a process listing or the log's
  # command echo. The byte-identical case at the end compares `run:` bodies
  # ONLY, so without this the `env:` block could quietly drop out of one file
  # and every behavioural case would stay green.
  CASE="[$WF_NAME] the token arrives by env, not in the command"
  if grep -qF 'GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}' "$WF"; then
    ok "the step declares env: GITHUB_TOKEN"
  else
    notok "no 'GITHUB_TOKEN: \${{ secrets.GITHUB_TOKEN }}' env in $WF_NAME"
  fi
  CASE="[$WF_NAME] the secret is never interpolated into the shell body"
  if grep -qF 'secrets.GITHUB_TOKEN' "$SCRIPT"; then
    notok "the run body interpolates the secret -- it would land in shell history/logs"
  else
    ok "the body references \$GITHUB_TOKEN only as an env var"
  fi

  # `${{ ... }}` is GitHub templating, not shell. Substitute as Actions would.
  # The PR number is passed per-case as $1 so one extracted script covers all.
  sed -i 's/\${{ github\.event\.pull_request\.number }}/${1:-100}/g' "$SCRIPT"
  sed -i 's/\${{ github\.base_ref }}/main/g' "$SCRIPT"
  SCRIPT_FOR="$SCRIPT"

  export GITHUB_TOKEN="stub-token"
  export STUB_PRS_STATUS=200
  unset STUB_PRS_BODY 2>/dev/null || true

  # -- the case the whole step exists for -------------------------------------
  CASE="[$WF_NAME] a version an EARLIER open PR already claims"
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

  CASE="[$WF_NAME] the collision message carries the re-bump recipe"
  case "$out" in
    *"make bump-patch"*) ok "tells the author exactly how to fix it" ;;
    *) notok "no remedy in the message: $out" ;;
  esac

  # -- the tiebreak: only the LATER PR goes red -------------------------------
  CASE="[$WF_NAME] the EARLIER PR of a colliding pair is not failed"
  # Same fixture, seen from the other side. Failing both would deadlock a pair
  # that is each other's only problem and block the PR that did nothing wrong,
  # so the lowest number keeps the version and only the later one must move.
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

  # -- the ordinary green path ------------------------------------------------
  CASE="[$WF_NAME] an open PR on a different version"
  mk sha558 1.3.267
  export STUB_PRS_JSON="$(prs '558:sha558:false:unrelated')"
  d=$(workdir 1.3.268)
  if out=$(run_step "$d" 559); then ok "1.3.268 against an open 1.3.267 passes"
  else notok "a non-colliding PR was rejected: $out"; fi

  CASE="[$WF_NAME] no other open PR"
  export STUB_PRS_JSON="$(prs)"
  d=$(workdir 1.3.268)
  if out=$(run_step "$d" 559); then
    case "$out" in
      *uncontested*) ok "passes and says so" ;;
      *) notok "passed but reported nothing: $out" ;;
    esac
  else notok "a lone PR was rejected: $out"; fi

  CASE="[$WF_NAME] the PR does not collide with ITSELF"
  # The list the API returns includes this PR. Comparing against itself would
  # make every single PR in the fleet red.
  mk shaSelf 1.3.268
  export STUB_PRS_JSON="$(prs '559:shaSelf:false:this very PR')"
  d=$(workdir 1.3.268)
  if out=$(run_step "$d" 559); then
    # Exit 0 alone is too weak: a PR that fails to exclude itself lands in the
    # "opened later" bucket, which only warns -- so the case stayed green under
    # a mutation that removed the exclusion entirely. Assert it found NOTHING.
    case "$out" in
      *uncontested*) ok "a PR is excluded from its own collision check" ;;
      *) notok "the PR saw ITSELF as another claimant: $out" ;;
    esac
  else notok "the PR collided with itself: $out"; fi

  # -- a draft still holds the number -----------------------------------------
  CASE="[$WF_NAME] a DRAFT PR still claims its version"
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

  # -- clean skips, none of them silent ---------------------------------------
  CASE="[$WF_NAME] a repo that does not version here"
  export STUB_PRS_JSON="$(prs '558:sha558:false:x')"
  d=$(workdir NOVERSION)
  if out=$(run_step "$d" 559); then
    case "$out" in
      *"no VERSION in Makefile"*) ok "skipped, and says why" ;;
      *) notok "passed silently instead of announcing the skip: $out" ;;
    esac
  else notok "a repo with no VERSION was FAILED: $out"; fi

  CASE="[$WF_NAME] a token that cannot list PRs warns, and does not fail"
  # This reusable is consumed at @main by the whole fleet. Hard-failing on a
  # missing `pull-requests: read` would turn every caller red at once over a
  # permission none of them had been asked for.
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

  CASE="[$WF_NAME] the API's OWN words reach the log"
  # Never a parser's summary. A 403 reading "Resource not accessible by
  # integration" ends this in one step; a jq KeyError sends the reader
  # somewhere else entirely.
  case "$out" in
    *"Resource not accessible by integration"*) ok "the server's message is shown verbatim" ;;
    *) notok "the server's own error was swallowed: $out" ;;
  esac

  CASE="[$WF_NAME] an unreachable API warns, and does not fail"
  export STUB_PRS_STATUS=000
  d=$(workdir 1.3.268)
  if out=$(run_step "$d" 559); then ok "a network failure is a warning, not a red check"
  else notok "a transient network failure failed the build: $out"; fi
  export STUB_PRS_STATUS=200
  unset STUB_PRS_BODY

  CASE="[$WF_NAME] no token at all"
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

  CASE="[$WF_NAME] a PR whose Makefile cannot be read is not compared"
  # A fork, a deleted branch, a repo with no Makefile on that ref. Unreadable
  # must not mean "colliding", or an unrelated PR turns this one red.
  export STUB_PRS_JSON="$(prs '558:shaMissing:false:gone')"
  d=$(workdir 1.3.268)
  if out=$(run_step "$d" 559); then
    case "$out" in
      *"not compared"*) ok "skipped that PR, and said so" ;;
      *) notok "passed without noting the PR it could not read: $out" ;;
    esac
  else notok "an unreadable Makefile was treated as a collision: $out"; fi

done

# The cheapest of these checks and the strongest. Every case above asks each
# copy to BEHAVE; this asks them to be ONE THING. The two inline copies of the
# SIBLING step drifted twice under a comment telling them not to -- and both
# times the behavioural cases stayed green, because they compared exit codes and
# the divergence was in a MESSAGE.
CASE="[all] every copy of the step is byte-identical"
ref=""; ref_name=""; identical=1
for WF_NAME in $WORKFLOWS; do
  body="$(extract "$HERE/../.github/workflows/$WF_NAME" "$STEP_NAME")"
  if [ -z "$ref_name" ]; then ref="$body"; ref_name="$WF_NAME"; continue; fi
  if [ "$body" != "$ref" ]; then
    identical=0
    echo "--- $ref_name vs $WF_NAME ---"
    diff <(printf '%s\n' "$ref") <(printf '%s\n' "$body") || true
  fi
done
if [ "$identical" -eq 1 ]; then
  ok "all $(set -- $WORKFLOWS; echo $#) copies carry the same body"
else
  notok "the copies have drifted -- see the diff above"
fi

# The step is useless in the two workflows that DECLARE permissions unless the
# scope is declared too: a workflow-level block REPLACES the caller's grant
# rather than adding to it, so the step would warn "could not list open PRs" on
# every PR forever. ci.yml declares no block and inherits the caller's, so it is
# deliberately not in this list.
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
  ok "both restricting workflows grant the scope the step needs"
else
  notok "no 'pull-requests: read' in:$missing -- the step can never run there"
fi

echo
echo "passed: $pass   failed: $fail"
[ "$fail" -eq 0 ]
