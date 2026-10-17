#!/usr/bin/env bash
# ci-build.test.sh -- the CI gate for .github/workflows/ci-build.yml, the
# reusable build -> push -> deploy (bdh-org/dev-common#304).
#
# Why this suite exists at all: that workflow ships as YAML that runs on OTHER
# repos' events. Nothing in this repo executes it, so without these cases the
# first time any of it runs is a production deploy in a consumer repo -- which is
# exactly how the defect that prompted centralising it survived in 14 hand-copied
# files at once (`:latest` moved from any branch that built,
# bdh-org/home-infra#1323).
#
# The headline property is ONE LINE of shell: `:latest` is tagged and pushed only
# inside `if [ "$GITHUB_REF" = "refs/heads/main" ]`. It is asserted twice, on
# purpose and in two different ways -- the Push step is RUN for real against a
# stub docker at main and at a branch ref, and the file is scanned statically so
# that a second `:latest` added anywhere outside that guard fails even if the
# behavioural case still passes.
#
# Everything else here is run for real too, with the step bodies extracted out of
# the workflow: a reusable workflow has no dev-common on disk to call a script
# from, so its scripts are embedded, and an embedded script is only testable by
# extraction.
#
# Usage:  bash tests/ci-build.test.sh      (or: make test)

set -uo pipefail   # deliberately NOT -e: every case runs, then we report

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WF="$REPO_ROOT/.github/workflows/ci-build.yml"
WF_CI="$REPO_ROOT/.github/workflows/self-hosted-ci.yml"
WF_AGENT="$REPO_ROOT/.github/workflows/agent-issue-to-pr.yml"
HYDRATE_STEP='Hydrate the selected submodules (per-submodule org tokens)'
AGENT_HYDRATE_STEP='Hydrate submodules (per-submodule org tokens)'

pass=0
fail=0
CASE="(none)"

# --- harness ---------------------------------------------------------------

ok()    { pass=$((pass + 1)); printf 'ok     - %s: %s\n' "$CASE" "$1"; }
notok() {
  fail=$((fail + 1))
  printf 'NOT OK - %s: %s\n' "$CASE" "$1"
  [ -n "${2:-}" ] && printf '         got: %s\n' "$2"
  return 0
}

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
# ones the extracted script makes (GIT_CONFIG_* is inherited).
export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=protocol.file.allow GIT_CONFIG_VALUE_0=always
export GIT_TERMINAL_PROMPT=0   # never block on a credential prompt
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t

# The named step's `run: |` body, dedented out of a workflow. Same extractor as
# tests/ci-submodules.test.sh.
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

# The line range of a step, so a case can say "inside the Push step" and mean it.
step_start() { grep -n "^      - name: $1\$" "$WF" | head -1 | cut -d: -f1; }
step_end()   { awk -v s="$1" 'NR > s && /^      - name: /{print NR; exit} END{if (!f) print NR}' "$WF"; }

# A `docker` on PATH that records its argv and succeeds. The workflow's whole job
# is the argv it hands docker, so that is what every build/push case inspects.
mkdir -p "$TMP/shim"
cat > "$TMP/shim/docker" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$DOCKER_LOG"
exit 0
EOF
chmod +x "$TMP/shim/docker"

# --- 0. the file is there and parses ---------------------------------------

CASE="the workflow"
if [ -f "$WF" ]; then ok "ci-build.yml exists"
else notok "no .github/workflows/ci-build.yml"; printf '1..%d\n' "$((pass + fail))"; exit 1; fi

jobs_block="$(awk '/^jobs:/{inj = 1; next} inj' "$WF" | grep -E '^  [a-z][a-z0-9_-]*:' || true)"
assert_eq "  build-and-push:
  deploy:" "$jobs_block" "it declares exactly the two jobs, build-and-push and deploy"

# PyYAML is a BONUS here, not the gate: every structural property this would
# catch is also asserted textually below, and a suite that goes red on whether
# the runner image ships a library is a suite that gets ignored. When it is
# present it catches the one thing grep cannot -- that the file is valid YAML at
# all, which otherwise surfaces as a consumer's build failing to start.
if python3 -c 'import yaml' 2>/dev/null; then
  if python3 -I -c '
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
# PyYAML resolves the bare key `on` to the boolean True.
trig = d[True] if True in d else d["on"]
assert list(trig) == ["workflow_call"], list(trig)
assert set(d["jobs"]) == {"build-and-push", "deploy"}, list(d["jobs"])
' "$WF" 2>"$TMP/yamlerr"; then
    ok "it is valid YAML, workflow_call only, with the two expected jobs"
  else
    notok "YAML/shape check failed:"; sed 's/^/         /' "$TMP/yamlerr"
  fi
else
  ok "valid-YAML parse not run (no PyYAML here); the textual checks below still ran"
fi

# Every step body must at least parse as bash: a `run:` that does not is a
# failure in a consumer repo's deploy, discovered there.
CASE="every embedded script parses"
for s in "Resolve the registry from the image path" "$HYDRATE_STEP" Build Push "Log out" Deploy; do
  extract "$WF" "$s" > "$TMP/step.sh"
  if [ ! -s "$TMP/step.sh" ]; then notok "no '$s' step with a run: | body"; continue; fi
  if bash -n "$TMP/step.sh" 2>"$TMP/syn"; then ok "'$s' parses"
  else notok "'$s' does not parse:"; sed 's/^/         /' "$TMP/syn"; fi
done

# --- 1. triggers: workflow_call only, and no stale branch trigger ----------

# The second half of bdh-org/home-infra#1323 was a leftover test-branch trigger
# in the consumers' `on:` blocks, which built and pushed from a branch nobody
# was watching. This file must carry no `on:` events of its own at all -- the
# events belong to the caller's wrapper -- so the assertion is the strong one:
# nothing in the trigger block but workflow_call, and no branch list anywhere.
CASE="triggers"
on_block="$(awk '/^on:/{inon=1; next} inon && /^[a-z]/{exit} inon{print}' "$WF" | grep -vE '^[[:space:]]*#')"
assert_contains "$on_block" "workflow_call:" "the trigger block declares workflow_call"
assert_absent "$on_block" "push:"         "no push trigger of its own"
assert_absent "$on_block" "pull_request"  "no pull_request trigger of its own"
assert_absent "$on_block" "ci-test"       "no stale test-branch trigger (home-infra#1323)"

code="$(grep -vE '^[[:space:]]*#' "$WF")"
assert_absent "$code" "branches:" \
  "no branch list anywhere in the file -- a branch filter here could only be the caller's"
# The name itself, not just inside a trigger: a `ci-test` left in a guard or a
# comparison would reintroduce the same build-from-a-dead-branch shape.
assert_absent "$code" "ci-test" "the dead test branch is named nowhere in the code"

# --- 2. inputs and wiring --------------------------------------------------

# A default is part of the contract: a consumer wrapper that passes nothing gets
# these, and a changed default changes every wrapper at once. The runner labels
# and the docker endpoint matter most -- `forge` is the priority reservation that
# keeps a deploy ahead of queued agent work (home-infra#357), and 996 is the
# forge RUNNER's uid, whose rootless socket is the only one the build can reach.
CASE="inputs"
input_block() { # name -> that input's own block, properties only
  awk -v n="      $1:" '
    $0 == n              { ins = 1; next }
    ins && /^      [a-z_]+:$/ { exit }
    ins                  { print }
  ' "$WF"
}
assert_input() { # name type default-line ('<required>' for a required input)
  local b; b="$(input_block "$1")"
  if [ -z "$b" ]; then notok "there is no '$1' input"; return 0; fi
  assert_contains "$b" "type: $2" "input $1 is a $2"
  if [ "$3" = "<required>" ]; then
    assert_contains "$b" "required: true" "input $1 is required"
    assert_absent "$b" "default:" "and carries no default -- there is no sensible image to build"
  else
    assert_contains "$b" "$3" "input $1 defaults to ${3#default: }"
  fi
}
assert_input image          string  '<required>'
assert_input dockerfile     string  'default: Dockerfile'
assert_input build_args     string  'default: ""'
assert_input submodules     string  'default: ""'
assert_input deploy_command string  'default: ""'
assert_input deploy_ssh_key boolean 'default: false'
assert_input runs_on        string  "default: '[\"self-hosted\", \"forge\"]'"
assert_input docker_host    string  'default: unix:///run/user/996/docker.sock'

# And nothing else: an input this file does not need is one every consumer has to
# read before writing a wrapper (the issue's rule -- a repo that needs more keeps
# its own file).
got_inputs="$(awk '/^    inputs:/{ini = 1; next} ini && /^  [a-z]/{exit} ini && /^      [a-z_]+:$/{gsub(/[ :]/, ""); print}' "$WF" | LC_ALL=C sort | tr '\n' ' ')"
assert_eq "build_args deploy_command deploy_ssh_key docker_host dockerfile image runs_on submodules " \
  "$got_inputs" "those eight inputs and no more"

CASE="job wiring"
assert_contains "$code" 'runs-on: ${{ fromJSON(inputs.runs_on) }}' \
  "the runner labels come from the runs_on input"
assert_eq "2" "$(printf '%s\n' "$code" | grep -c 'fromJSON(inputs.runs_on)')" \
  "BOTH jobs use it -- a deploy job pinned to another runner cannot reach the host"
assert_contains "$code" 'DOCKER_HOST: ${{ inputs.docker_host }}' \
  "the docker endpoint comes from the docker_host input"
assert_contains "$code" 'DOCKER_CONFIG: /tmp/docker-config-${{ github.run_id }}' \
  "the docker config is run-scoped (home-infra#154)"
assert_contains "$code" 'IMAGE: ${{ inputs.image }}' "the image path reaches the steps as \$IMAGE"

# A secret interpolated into a `run:` body is written into the script file on the
# runner's disk; through `env:` it is not. Both vault fetches here hand their
# value over as an environment variable, and the login reads it from there.
CASE="credentials"
for s in Build Push "Log out" Deploy "Resolve the registry from the image path" "$HYDRATE_STEP"; do
  body="$(extract "$WF" "$s")"
  assert_absent "$body" 'steps.vault.outputs' "the '$s' script does not interpolate the registry credential"
  assert_absent "$body" 'steps.key.outputs'   "the '$s' script does not interpolate the deploy key"
done
login="$(awk '/^      - name: Log in to the registry$/,/^      - name: Build$/' "$WF")"
assert_contains "$login" 'REGISTRY_PW: ${{ steps.vault.outputs.registry_pw }}' \
  "the login takes the credential through env"
assert_contains "$login" '--password-stdin' "and feeds it to docker login on stdin, never as a flag"

# --- 3. the registry is derived from the image ----------------------------

CASE="registry resolution"
extract "$WF" "Resolve the registry from the image path" > "$TMP/registry.sh"
resolve() { # image -> rc; $OUT holds output, $RESOLVED the REGISTRY it exported
  local img="$1" rc
  : > "$TMP/gh-env"
  OUT="$(IMAGE="$img" GITHUB_ENV="$TMP/gh-env" bash "$TMP/registry.sh" 2>&1)"; rc=$?
  RESOLVED="$(sed -n 's/^REGISTRY=//p' "$TMP/gh-env")"
  return $rc
}

if resolve registry.home.arpa/roy; then
  assert_eq "registry.home.arpa" "$RESOLVED" "a full path yields the registry host"
else notok "a valid image path was rejected" "$OUT"; fi

if resolve registry.home.arpa/team/roy; then
  assert_eq "registry.home.arpa" "$RESOLVED" "a nested repository path still yields the host"
else notok "a nested image path was rejected" "$OUT"; fi

if resolve "registry:5000/roy"; then
  assert_eq "registry:5000" "$RESOLVED" "a host:port registry survives"
else notok "a host:port registry was rejected" "$OUT"; fi

# The wrong-input cases, which must fail HERE rather than 40 lines into a docker
# log that says nothing about the input that caused them.
if resolve registry.home.arpa/roy:latest; then
  notok "an image carrying a tag was accepted -- the build would be <image>:latest:<sha>"
else assert_contains "$OUT" "must carry NO tag" "an image with a tag is refused, by name"; fi

if resolve roy; then notok "a bare name was accepted -- there is no registry to log in to"
else assert_contains "$OUT" "full registry path" "a bare image name is refused"; fi

if resolve library/roy; then notok "a Docker Hub namespace was accepted as a registry host"
else assert_contains "$OUT" "is not a registry host" "a first segment with no dot or port is refused"; fi

# --- 4. the build tags the SHA, and only the SHA --------------------------

CASE="build"
extract "$WF" Build > "$TMP/build.sh"
build() { # dir dockerfile build_args -> rc; $OUT output, $DOCKER_LOG argv
  local d="$1" rc
  DOCKER_LOG="$TMP/docker.log"; : > "$DOCKER_LOG"
  OUT="$(cd "$d" && PATH="$TMP/shim:$PATH" DOCKER_LOG="$DOCKER_LOG" \
          IMAGE=registry.home.arpa/roy GITHUB_SHA=deadbeef \
          DOCKERFILE="${2:-Dockerfile}" BUILD_ARGS="${3:-}" bash "$TMP/build.sh" 2>&1)"; rc=$?
  ARGV="$(cat "$DOCKER_LOG")"
  return $rc
}

ctx="$TMP/ctx"; mkdir -p "$ctx/apache"
: > "$ctx/Dockerfile"; : > "$ctx/apache/Dockerfile"
printf 'VERSION=1.2.3\n' > "$ctx/Makefile"

if build "$ctx"; then
  assert_eq "build -f Dockerfile -t registry.home.arpa/roy:deadbeef ." "$ARGV" \
    "a plain build tags the SHA and nothing else"
else notok "the build step failed on a plain repo" "$OUT"; fi

if build "$ctx" apache/Dockerfile; then
  assert_contains "$ARGV" "-f apache/Dockerfile" \
    "the dockerfile input is honoured (home-site builds apache/Dockerfile)"
  assert_contains "$ARGV" " ." "and the context stays the repo root"
else notok "the build step failed with a dockerfile input" "$OUT"; fi

if build "$ctx" Dockerfile $'ROY_VERSION=${VERSION}\nROY_BUILD=${GITHUB_SHA}'; then
  assert_contains "$ARGV" "--build-arg ROY_VERSION=1.2.3" \
    "\${VERSION} becomes the Makefile's VERSION (what brief and roy pass)"
  assert_contains "$ARGV" "--build-arg ROY_BUILD=deadbeef" "\${GITHUB_SHA} becomes the SHA"
else notok "the build step failed with build_args" "$OUT"; fi

if build "$ctx" Dockerfile $'\n# a comment\nA=1\n\nB=two words\n'; then
  assert_contains "$ARGV" "--build-arg A=1 --build-arg B=two words" \
    "blank lines and comments are skipped; a value with spaces stays one argument"
else notok "the build step failed on a mixed build_args block" "$OUT"; fi

if build "$ctx" Dockerfile 'NOT_A_PAIR'; then
  notok "a build_args line with no '=' was accepted"
else assert_contains "$OUT" "not KEY=VALUE" "a build_args line with no '=' is refused"; fi

if build "$ctx" Dockerfile 'LITERAL=$HOME/x'; then
  assert_contains "$OUT" "keeps a literal" \
    "an unexpanded \$ is reported -- it reaches docker as those characters"
  assert_contains "$ARGV" '--build-arg LITERAL=$HOME/x' "and is passed through unchanged"
else notok "a literal \$ turned the build red instead of warning" "$OUT"; fi

noversion="$TMP/noversion"; mkdir -p "$noversion"; : > "$noversion/Dockerfile"
if build "$noversion" Dockerfile 'X=${VERSION}'; then
  notok "\${VERSION} with no VERSION in the Makefile silently baked an empty version"
else assert_contains "$OUT" "no VERSION line" "\${VERSION} with nothing to substitute is refused"; fi

if build "$TMP/ctx" missing/Dockerfile; then
  notok "a missing Dockerfile was handed to docker instead of being named here"
else assert_contains "$OUT" "no Dockerfile at" "a missing Dockerfile is named, with its path"; fi

build_code="$(extract "$WF" Build | grep -vE '^[[:space:]]*#')"
assert_absent "$build_code" ":latest" \
  "the build never tags :latest -- the push step moves it, and only from main"
assert_eq "1" "$(printf '%s\n' "$build_code" | grep -c -- ' -t ')" \
  "and carries exactly one -t, the SHA"

# --- 5. THE HEADLINE: :latest moves only from main ------------------------

CASE=":latest only from main"
extract "$WF" Push > "$TMP/push.sh"
push() { # ref -> rc; $ARGV every docker argv, one per line
  local rc
  DOCKER_LOG="$TMP/docker.log"; : > "$DOCKER_LOG"
  OUT="$(PATH="$TMP/shim:$PATH" DOCKER_LOG="$DOCKER_LOG" \
          IMAGE=registry.home.arpa/roy GITHUB_SHA=deadbeef GITHUB_REF="$1" \
          bash "$TMP/push.sh" 2>&1)"; rc=$?
  ARGV="$(cat "$DOCKER_LOG")"
  return $rc
}

if push refs/heads/main; then
  assert_contains "$ARGV" "push registry.home.arpa/roy:deadbeef" "main pushes the SHA"
  assert_contains "$ARGV" "tag registry.home.arpa/roy:deadbeef registry.home.arpa/roy:latest" \
    "main tags :latest from the SHA it just pushed"
  assert_contains "$ARGV" "push registry.home.arpa/roy:latest" "main pushes :latest"
else notok "the push step failed at main" "$OUT"; fi

for ref in refs/heads/agent/issue-304 refs/heads/ci-test refs/tags/v1 refs/pull/7/merge; do
  if push "$ref"; then
    assert_contains "$ARGV" "push registry.home.arpa/roy:deadbeef" "$ref still pushes the SHA"
    assert_absent "$ARGV" ":latest" "$ref does NOT touch :latest (home-infra#1323)"
  else notok "the push step failed at $ref" "$OUT"; fi
done

# Statically, too. The behavioural cases above pass as long as the guard holds
# for the two lines that exist today; this one fails if a THIRD `:latest` is ever
# added anywhere else in the file, which is how the defect spread in the first
# place.
CASE=":latest containment"
latest_lines="$(grep -nE 'docker[[:space:]]+(tag|push)[^#]*:latest' "$WF" \
                | grep -vE '^[0-9]+:[[:space:]]*#' || true)"
n_latest="$(printf '%s' "$latest_lines" | grep -c . || true)"
assert_eq "2" "$n_latest" "exactly two docker commands name :latest (one tag, one push)"

p_start="$(step_start Push)"; p_end="$(step_end "$p_start")"
guard="$(awk -v s="$p_start" -v e="$p_end" \
  'NR > s && NR < e && /if \[ "\$GITHUB_REF" = "refs\/heads\/main" \]/ {print NR; exit}' "$WF")"
closer="$(awk -v s="${guard:-0}" -v e="$p_end" \
  'NR > s && NR < e && /^          (else|fi)$/ {print NR; exit}' "$WF")"
if [ -n "${guard:-}" ] && [ -n "${closer:-}" ]; then
  ok "the Push step carries a refs/heads/main guard that closes"
  inside=0; outside=0
  while IFS= read -r l; do
    [ -n "$l" ] || continue
    n="${l%%:*}"
    if [ "$n" -gt "$guard" ] && [ "$n" -lt "$closer" ]; then inside=$((inside + 1))
    else outside=$((outside + 1)); echo "         outside the guard: $l"; fi
  done <<< "$latest_lines"
  assert_eq "0" "$outside" "no :latest tag or push sits outside the main-only guard"
  assert_eq "2" "$inside"  "both of them sit inside it"
else
  notok "could not find the 'if [ \"\$GITHUB_REF\" = \"refs/heads/main\" ]' guard in the Push step"
fi

# --- 6. the deploy job gate ----------------------------------------------

CASE="deploy gate"
deploy_if="$(awk '/^  deploy:/,/^    steps:/' "$WF" | grep -E '^    if:' || true)"
assert_contains "$deploy_if" "github.ref == 'refs/heads/main'" \
  "the deploy job requires refs/heads/main"
assert_contains "$deploy_if" "github.event_name == 'push'" "and a real push"
assert_contains "$deploy_if" "github.event_name == 'workflow_dispatch'" \
  "or a manual dispatch -- excluding it builds, pushes and silently skips the deploy (home-infra#140)"
assert_contains "$deploy_if" "inputs.deploy_command != ''" \
  "and does not run at all for a repo that only builds and pushes"
assert_contains "$(awk '/^  deploy:/,/^    steps:/' "$WF")" "needs: build-and-push" \
  "and never deploys an image the build did not push"

CASE="deploy step"
extract "$WF" Deploy > "$TMP/deploy.sh"
deploy() { # command need_key key_b64 -> rc; $OUT output
  local rc
  OUT="$(RUNNER_TEMP="$TMP" GITHUB_SHA=deadbeef DEPLOY_HOST=minerva \
          DEPLOY_COMMAND="$1" NEED_KEY="${2:-false}" KEY_B64="${3:-}" \
          bash "$TMP/deploy.sh" 2>&1)"; rc=$?
  return $rc
}

if deploy 'echo deployed "$GITHUB_SHA" to "$DEPLOY_HOST"'; then
  assert_contains "$OUT" "deployed deadbeef to minerva" \
    "the command runs, and sees \$GITHUB_SHA and \$DEPLOY_HOST"
else notok "a plain deploy command failed" "$OUT"; fi

if deploy 'exit 3'; then notok "a failing deploy command reported success"
else ok "a failing deploy command fails the step"; fi

if deploy 'deploy.sh registry.home.arpa/roy:latest'; then
  notok "a deploy_command naming :latest was allowed -- that deploys whatever main pushed last"
else assert_contains "$OUT" "names :latest" "a deploy_command naming :latest is refused"; fi

if deploy 'echo no sha here'; then
  assert_contains "$OUT" "does not mention" \
    "a deploy_command with no \$GITHUB_SHA is flagged (but still runs -- it may be right)"
else notok "a deploy_command without \$GITHUB_SHA was turned into a failure" "$OUT"; fi

# deploy_ssh_key: the cross-host shape. A key that did not arrive must fail
# before the ssh, whose own error reads like a server-side refusal.
if deploy 'echo unreachable' true ''; then
  notok "deploy_ssh_key was true, Vault returned nothing, and the deploy ran anyway"
else assert_contains "$OUT" "Vault returned no key" "an empty key is refused, naming the cause"; fi

printf 'PRIVATE-KEY-BYTES\n' > "$TMP/key.pem"
KEY_B64="$(openssl base64 -A < "$TMP/key.pem")"
if deploy 'printf "%s %s\n" "$(stat -c %a "$DEPLOY_KEY")" "$(cat "$DEPLOY_KEY")"' true "$KEY_B64"; then
  assert_contains "$OUT" "600 PRIVATE-KEY-BYTES" \
    "the key is decoded to a mode-600 file the command reads as \$DEPLOY_KEY"
else notok "the cross-host deploy shape failed" "$OUT"; fi

if deploy 'printf "%s\n" "$DEPLOY_KEY" > '"$TMP/keypath" true "$KEY_B64"; then
  left="$(cat "$TMP/keypath" 2>/dev/null)"
  if [ -n "$left" ] && [ ! -e "$left" ]; then ok "the key file is removed when the step ends"
  else notok "the decoded private key was left on the runner at '$left'"; fi
else notok "the deploy step failed while recording the key path" "$OUT"; fi

if deploy 'test -z "${DEPLOY_KEY:-}"'; then
  ok "a deploy that needs no key is handed none"
else notok "\$DEPLOY_KEY was set for a deploy with deploy_ssh_key false" "$OUT"; fi

# The command is taken from the environment rather than interpolated into the
# step's script: a `with:` value spliced into YAML changes what the script IS.
deploy_body="$(extract "$WF" Deploy)"
assert_contains "$deploy_body" 'bash -c "$DEPLOY_COMMAND"' "the command is run from the environment"
assert_absent "$deploy_body" 'inputs.deploy_command' "and is not interpolated into the script"

# There is no checkout in the deploy job, so a command that reads the workspace
# would be reading whatever the build job left there.
CASE="deploy job has no checkout"
deploy_block="$(awk '/^  deploy:/,0' "$WF")"
assert_absent "$deploy_block" "actions/checkout" "the deploy job checks nothing out"

# --- 7. submodule hydration ----------------------------------------------

# sm_map / sm_org are bdh-org/dev-common#169's, and their coverage lives in
# tests/hydrate-submodules.test.sh. Keeping the copies textually identical is
# what lets that coverage stand for this one; a drifting copy is an untested one.
CASE="hydration library"
lib() { # script -> the code (comments and blanks dropped) up to the LIB_ONLY guard
  awk '/HYDRATE_LIB_ONLY/ { print; exit } { print }' "$1" \
    | grep -vE '^[[:space:]]*(#|$)'
}
extract "$WF" "$HYDRATE_STEP" > "$TMP/hydrate.sh"
for peer in "$WF_CI|$HYDRATE_STEP" "$WF_AGENT|$AGENT_HYDRATE_STEP"; do
  f="${peer%%|*}"; s="${peer#*|}"
  extract "$f" "$s" > "$TMP/peer.sh"
  if [ ! -s "$TMP/peer.sh" ]; then notok "could not extract '$s' from $(basename "$f")"; continue; fi
  if diff -u <(lib "$TMP/peer.sh") <(lib "$TMP/hydrate.sh") > "$TMP/drift.diff"; then
    ok "sm_map/sm_org are byte-identical to $(basename "$f")'s"
  else
    notok "the shared hydration library has drifted from $(basename "$f"):"
    sed 's/^/         /' "$TMP/drift.diff"
  fi
done

hydrate_body="$(cat "$TMP/hydrate.sh")"
assert_absent "$hydrate_body" 'repository_owner' \
  "the org comes from the submodule URL, not the caller's org (dev-common#170)"
assert_absent "$hydrate_body" 'github.com/bdh-org/.insteadOf' \
  "and not from a hardcoded bdh-org (the same bug inverted, panoptikon#700)"
assert_absent "$hydrate_body" 'update --init --recursive' \
  "hydration stays selective -- what is in the build context is what the repo named"
assert_contains "$hydrate_body" 'submodule update --init --force -- "${WANT[@]}"' \
  "the update is limited to the path list it built, and --force is kept (dev-common#176)"

# sm_org, for real, through the library guard this copy also carries.
CASE="sm_org"
# shellcheck disable=SC1090
HYDRATE_LIB_ONLY=1 . "$TMP/hydrate.sh" || { echo "FATAL: could not source the extracted script"; exit 1; }
# The script opens with `set -euo pipefail`, which sourcing leaks into THIS
# shell -- and this harness deliberately runs every case rather than dying on
# the first failure. Put the options back.
set +e +u +o pipefail
set -uo pipefail
assert_eq "bdh-org" "$(sm_org 'https://github.com/bdh-org/dev-common.git')" "https URL -> org"
assert_eq "finzeug" "$(sm_org 'git@github.com:finzeug/ledger-io.git')"      "ssh URL -> org"
assert_eq ""        "$(sm_org '../sibling.git')"                           "relative URL -> no org"

# --- 7b. hydration, end to end against throwaway local repos -------------

mkdir -p "$TMP/remotes" "$TMP/build"
mkrepo() { # name
  local name="$1" w="$TMP/build/$1"
  git init -q --bare -b main "$TMP/remotes/$name.git"
  mkdir -p "$w"; git init -q -b main "$w"; echo "$name" > "$w/file"
  git -C "$w" add -A; git -C "$w" commit -qm init
  git -C "$w" push -q "$TMP/remotes/$name.git" main
}

cat > "$TMP/mint-stub.sh" <<'EOF'
#!/usr/bin/env bash
# stands in for /srv/github-runner/bin/mint-coder-app-token.sh, and records
# which orgs were asked for -- the whole point of dev-common#169/#170.
printf '%s\n' "$1" >> "$MINT_LOG"
printf '::add-mask::%s\n' "stub-token-for-$1"
printf 'coder_token=stub-token-for-%s\n' "$1" >> "$GITHUB_OUTPUT"
EOF
chmod +x "$TMP/mint-stub.sh"

run_hydrate() { # workdir submodules -> rc; $OUT output, $MINT_LOG orgs minted
  local d="$1" rc
  MINT_LOG="$TMP/minted.$(basename "$d")"; : > "$MINT_LOG"
  OUT="$(cd "$d" && MINT="$TMP/mint-stub.sh" SUBMODULES="${2:-}" MINT_LOG="$MINT_LOG" \
          bash "$TMP/hydrate.sh" 2>&1)"; rc=$?
  return $rc
}

mkrepo dev-common
mkrepo vendored
w="$TMP/build/consumer"; mkdir -p "$w"; git init -q -b main "$w"
git init -q --bare -b main "$TMP/remotes/consumer.git"
echo consumer > "$w/file"
for s in "dev-common common" "vendored vendor/thing"; do
  set -- $s
  git -C "$w" submodule add -q "$TMP/remotes/$1.git" "$2" >/dev/null 2>&1
done
git -C "$w" add -A; git -C "$w" commit -qm init
git -C "$w" push -q "$TMP/remotes/consumer.git" main

CASE="e2e: only what the repo named is in the build context"
git clone -q "$TMP/remotes/consumer.git" "$TMP/co-sel"
# Leave vendor/thing populated, the way an agent job's --recursive init would on
# the shared forge workspace.
git -C "$TMP/co-sel" submodule update --init --recursive -- vendor/thing >/dev/null 2>&1
if run_hydrate "$TMP/co-sel" "common"; then
  assert_contains "$OUT" "submodule hydration OK" "it reports success explicitly"
  if [ -f "$TMP/co-sel/common/file" ]; then ok "the named submodule is populated"
  else notok "common is empty -- the Dockerfile's COPY would fail or ship nothing"; fi
  if [ -f "$TMP/co-sel/vendor/thing/file" ]; then
    notok "vendor/thing is still on disk -- an earlier job's checkout would be baked in (heller#356)"
  else ok "a submodule this build did not name is deinitialised, not inherited"; fi
else notok "hydration failed" "$OUT"; fi

CASE="e2e: an empty list still clears the context"
# The property that is NEW here, and the reason this step runs even with no
# submodules requested: whatever an earlier job left populated must not be baked
# into the image by a Dockerfile that COPYs a whole directory.
git clone -q "$TMP/remotes/consumer.git" "$TMP/co-empty"
git -C "$TMP/co-empty" submodule update --init --recursive >/dev/null 2>&1
if run_hydrate "$TMP/co-empty" ""; then
  assert_contains "$OUT" "build context carries none" "it says so rather than passing silently"
  leftover=""
  for p in common vendor/thing; do
    [ -n "$(ls -A "$TMP/co-empty/$p" 2>/dev/null | grep -vx '.git' || true)" ] && leftover="$leftover $p"
  done
  assert_eq "" "$leftover" "every submodule left by an earlier job is gone"
  assert_eq "" "$(cat "$MINT_LOG")" "and nothing is minted for a build that asked for nothing"
else notok "hydration failed with an empty submodules input" "$OUT"; fi

CASE="e2e: a path that is not a submodule"
# self-hosted-ci.yml warns here and runs the tests anyway. A BUILD cannot: the
# Dockerfile is about to COPY from that path, and the failure 40 lines later
# names a file, not the input that was wrong.
git clone -q "$TMP/remotes/consumer.git" "$TMP/co-typo"
if run_hydrate "$TMP/co-typo" "commmon"; then
  notok "a misspelt submodule path was waved through to docker build"
else assert_contains "$OUT" "is not a submodule of this repo" "it fails, naming the path"; fi

CASE="e2e: an emptied working tree"
# dev-common#176's shape: .git and HEAD survive at the pin while every tracked
# file is gone, so `git submodule status` calls the path clean. The guard asks
# the working tree instead.
git clone -q "$TMP/remotes/consumer.git" "$TMP/co-empty-tree"
git -C "$TMP/co-empty-tree" submodule update --init -- common >/dev/null 2>&1
rm -f "$TMP/co-empty-tree/common/file"
if run_hydrate "$TMP/co-empty-tree" "common"; then
  if [ -f "$TMP/co-empty-tree/common/file" ]; then ok "--force restores the emptied working tree"
  else notok "common is still empty and the step passed -- the build would ship nothing"; fi
else
  assert_contains "$OUT" "refusing to build against a partial checkout" \
    "or, failing that, it refuses to build (never silently ships an empty directory)"
fi

# --- report ---------------------------------------------------------------

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
