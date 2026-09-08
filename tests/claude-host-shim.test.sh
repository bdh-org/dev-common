#!/usr/bin/env bash
# claude-host-shim.test.sh -- the CI gate for the claude-prod / claude-dev shims
# that devcontainer/setup-claude.sh installs into /usr/local/bin (finzeug/slingshot#184).
#
# The defect these assertions pin down is not that the shim fails. It is WHAT IT
# SAYS when it fails. `claude-prod` defaults to the literal host `prod`, which
# resolves nowhere, so a repo without the stack-common submodule -- the submodule
# whose setup-stack-hosts.sh writes CLAUDE_PROD_HOST -- gets:
#
#     ssh: Could not resolve hostname prod: Name or service not known
#
# That reads as "production is unreachable from here". A session acted on that
# reading for a full day: it reported having no prod access and routed container
# checks, artifact listings and migration verification through a human by hand.
# The scoped account was usable the entire time. The access was never missing;
# one environment variable was.
#
# So the contract under test is: when the variable is UNSET and the fallback does
# not resolve, name the variable and the script that sets it, and do NOT reach
# ssh at all. And -- the half that keeps this from being a regression -- when the
# variable IS set, behave exactly as before and go straight to ssh.
#
# The shims are heredocs inside setup-claude.sh rather than standalone files, so
# each case extracts the REAL heredoc and runs it. Nothing here re-implements the
# shim. `getent` and `ssh` are stubbed on PATH so resolution is decided by the
# test rather than by whatever DNS the runner happens to have -- otherwise
# claude-dev's `twix` fallback would resolve on twix and not in CI.
#
# Usage:  bash tests/claude-host-shim.test.sh      (or: make test)

set -uo pipefail   # deliberately NOT -e: every case runs, then we report

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SETUP="$REPO_ROOT/devcontainer/setup-claude.sh"

pass=0
fail=0
CASE="(none)"

ok()   { pass=$((pass+1)); echo "ok   $CASE: $1"; }
bad()  { fail=$((fail+1)); echo "FAIL $CASE: $1"; }

check_contains() {  # haystack needle label
  case "$1" in
    *"$2"*) ok "$3" ;;
    *)      bad "$3 -- expected to find '$2' in:"; printf '%s\n' "$1" | sed 's/^/       | /' ;;
  esac
}
check_missing() {   # haystack needle label
  case "$1" in
    *"$2"*) bad "$3 -- did NOT expect '$2' in:"; printf '%s\n' "$1" | sed 's/^/       | /' ;;
    *)      ok "$3" ;;
  esac
}
check_rc() {        # actual expected label
  if [ "$1" = "$2" ]; then ok "$3 (rc=$1)"; else bad "$3 -- rc=$1, expected $2"; fi
}

# --- extract a shim from its heredoc in setup-claude.sh --------------------
extract() {  # marker -> stdout
  awk -v m="$1" '
    $0 ~ ("<<." m "." ) { grab=1; next }
    grab && $0 == m     { grab=0; next }
    grab                { print }
  ' "$SETUP"
}

D="$(mktemp -d)"
trap 'rm -rf "$D"' EXIT

extract CLAUDE_PROD_EOF > "$D/claude-prod"; chmod +x "$D/claude-prod"
extract CLAUDE_DEV_EOF  > "$D/claude-dev";  chmod +x "$D/claude-dev"

for f in claude-prod claude-dev; do
  if [ ! -s "$D/$f" ]; then
    echo "FAIL harness: extracted an EMPTY $f from $SETUP -- the heredoc marker moved."
    exit 1
  fi
  if ! bash -n "$D/$f"; then
    echo "FAIL harness: extracted $f is not valid bash."
    exit 1
  fi
done

# --- stubs: PATH decides resolution, and ssh must be observable ------------
mkdir -p "$D/bin"
# resolves ONLY the names listed in $D/resolvable
cat > "$D/bin/getent" <<'STUB'
#!/usr/bin/env bash
[ "${1:-}" = "hosts" ] || exit 2
grep -qxF "${2:-}" "${RESOLVABLE:-/dev/null}" 2>/dev/null || exit 2
echo "10.0.0.1 ${2}"
STUB
cat > "$D/bin/ssh" <<'STUB'
#!/usr/bin/env bash
echo "STUB-SSH-REACHED args: $*"
STUB
chmod +x "$D/bin/getent" "$D/bin/ssh"

export RESOLVABLE="$D/resolvable"
: > "$RESOLVABLE"

# a readable key, so the key guard never masks what we are testing
FAKE_HOME="$D/home"
mkdir -p "$FAKE_HOME/.config/ai/claude/credentials"
echo "not-a-real-key" > "$FAKE_HOME/.config/ai/claude/credentials/prod-readonly"
echo "not-a-real-key" > "$FAKE_HOME/.config/ai/claude/credentials/dev-readonly"

run() {  # shim env... -- args...   ; sets $o and $RC in the CALLER.
  local shim="$1"; shift
  # Deliberately not o="$(...)": a command substitution is a subshell, so an RC
  # assigned inside it never reaches the test.
  # "$@" FIRST: env's -u option must precede the variable assignments, and a
  # `-u` placed after them is taken as the command name (rc=127, not rc=2).
  env "$@" PATH="$D/bin:$PATH" HOME="$FAKE_HOME" RESOLVABLE="$RESOLVABLE" \
    bash "$D/$shim" docker-ps > "$D/out.txt" 2>&1
  RC=$?
  o="$(cat "$D/out.txt")"
}

# === 1. the reported failure: unset var, unresolvable fallback =============
CASE="claude-prod, CLAUDE_PROD_HOST unset and 'prod' does not resolve"
run claude-prod -u CLAUDE_PROD_HOST
check_rc "$RC" 2 "refuses rather than trying"
check_contains "$o" "CLAUDE_PROD_HOST is not set"        "names the variable"
check_contains "$o" "MISSING SETTING, not missing access" "says it is a setting, not access"
check_contains "$o" "setup-stack-hosts.sh"                "names the script that sets it"
check_contains "$o" "stack-common"                        "names the submodule"
check_missing  "$o" "STUB-SSH-REACHED"                    "never reaches ssh"

# === 2. the regression guard: a SET host still goes straight to ssh ========
CASE="claude-prod, CLAUDE_PROD_HOST set to an unresolvable host"
run claude-prod CLAUDE_PROD_HOST=deliberately-unresolvable
check_rc "$RC" 0 "does not second-guess an explicit setting"
check_contains "$o" "STUB-SSH-REACHED"          "reaches ssh"
check_contains "$o" "claude@deliberately-unresolvable" "uses the host it was given"
check_missing  "$o" "MISSING SETTING"           "stays silent when configured"

# === 3. unset but the fallback DOES resolve: unchanged behaviour ===========
CASE="claude-prod, unset but 'prod' resolves"
echo "prod" > "$RESOLVABLE"
run claude-prod -u CLAUDE_PROD_HOST
check_rc "$RC" 0 "uses the working default"
check_contains "$o" "claude@prod"     "ssh's to the default host"
check_missing  "$o" "MISSING SETTING" "no diagnosis when the default works"
: > "$RESOLVABLE"

# === 4. the pre-existing guards still fire ================================
CASE="claude-prod, missing key"
mv "$FAKE_HOME/.config/ai/claude/credentials/prod-readonly" "$D/keep-key"
run claude-prod CLAUDE_PROD_HOST=whatever
check_rc "$RC" 2 "refuses without a key"
check_contains "$o" "missing key at" "still reports the missing key"
mv "$D/keep-key" "$FAKE_HOME/.config/ai/claude/credentials/prod-readonly"

CASE="claude-prod, no arguments"
env -u CLAUDE_PROD_HOST PATH="$D/bin:$PATH" HOME="$FAKE_HOME" RESOLVABLE="$RESOLVABLE" \
  bash "$D/claude-prod" > "$D/out.txt" 2>&1
RC=$?; o="$(cat "$D/out.txt")"
check_rc "$RC" 2 "refuses with no verb"
check_contains "$o" "usage: claude-prod" "still prints usage"

# === 5. claude-dev carries the identical contract ==========================
CASE="claude-dev, CLAUDE_DEV_HOST unset and 'twix' does not resolve"
run claude-dev -u CLAUDE_DEV_HOST
check_rc "$RC" 2 "refuses rather than trying"
check_contains "$o" "CLAUDE_DEV_HOST is not set" "names the variable"
check_contains "$o" "setup-stack-hosts.sh"       "names the script that sets it"
check_missing  "$o" "STUB-SSH-REACHED"           "never reaches ssh"

CASE="claude-dev, CLAUDE_DEV_HOST set"
run claude-dev CLAUDE_DEV_HOST=some-dev-host
check_rc "$RC" 0 "does not second-guess an explicit setting"
check_contains "$o" "claude@some-dev-host" "uses the host it was given"

# --- report ---------------------------------------------------------------
echo
echo "claude-host-shim: ${pass} passed, ${fail} failed"
[ "$fail" -eq 0 ] || exit 1
