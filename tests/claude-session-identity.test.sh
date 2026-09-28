#!/usr/bin/env bash
# claude-session-identity.test.sh -- the gate for
# devcontainer/claude-session-identity.sh (bdh-org/home-infra#755).
#
# The hook decides the author name on every commit a Claude session makes, and
# it loads in headless agent runs too. What a careless edit would break:
#
#   - a session's commits name the session (the point);
#   - a headless agent run is left alone, or its commits stop naming
#     bdh-org-coder[bot] (home-infra issues/862);
#   - a non-bdh-ai identity is left alone (a human's own session);
#   - re-running (resume/compact) replaces its own lines and nobody else's;
#   - the value written into a sourced file cannot carry shell syntax.
#
# Usage:  bash tests/claude-session-identity.test.sh      (or: make test)

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOOK="$REPO_ROOT/devcontainer/claude-session-identity.sh"

pass=0
fail=0
CASE="(none)"
ok()    { pass=$((pass + 1)); printf 'ok     - %s: %s\n' "$CASE" "$1"; }
notok() { fail=$((fail + 1)); printf 'NOT OK - %s: %s\n' "$CASE" "$1"; }
assert_eq() { if [ "$1" = "$2" ]; then ok "$3"; else notok "$3"; printf '         want: %s\n         got:  %s\n' "$1" "$2"; fi; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

SID="eea68fda-c4e7-49af-8443-f3cda303785c"

# A HOME whose global gitconfig carries NAME, and an empty env file.
setup() { # name
  H="$TMP/home-$RANDOM"; mkdir -p "$H"; ENVF="$H/session-env.sh"; : > "$ENVF"
  if [ -n "$1" ]; then printf '[user]\n\tname = %s\n\temail = bdh-ai@example.invalid\n' "$1" > "$H/.gitconfig"; fi
}

run_hook() { # stdin-json [extra env...]
  local json="$1"; shift
  printf '%s' "$json" | env -u GITHUB_ACTIONS -u CLAUDE_CODE_SESSION_ID HOME="$H" CLAUDE_ENV_FILE="$ENVF" \
    GIT_CONFIG_NOSYSTEM=1 "$@" bash "$HOOK"
}

# What git itself would record, in a fresh repo, with the env file sourced the
# way Claude Code applies it before each Bash command.
author_of() {
  ( set +u; cd "$TMP" && rm -rf repo && git init -q repo && cd repo &&
    HOME="$H" GIT_CONFIG_NOSYSTEM=1 bash -c ". '$ENVF'; git var GIT_AUTHOR_IDENT" | sed 's/ <.*//' )
}

CASE="script"
if bash -n "$HOOK"; then ok "the hook parses"; else notok "the hook has a syntax error"; fi

CASE="architect"
setup "bdh-ai (architect)"
run_hook "{\"session_id\":\"$SID\",\"hook_event_name\":\"SessionStart\"}"
assert_eq "0" "$?" "exits 0"
assert_eq "bdh-ai (architect, session eea68fda)" "$(author_of)" "git records the role AND the session"
assert_eq "bdh-ai (architect, session eea68fda)" \
  "$( (cd "$TMP/repo" && HOME="$H" GIT_CONFIG_NOSYSTEM=1 bash -c ". '$ENVF'; git var GIT_COMMITTER_IDENT") | sed 's/ <.*//')" \
  "and as the committer"

CASE="plain"
setup "bdh-ai"
run_hook "{\"session_id\":\"$SID\"}"
assert_eq "bdh-ai (session eea68fda)" "$(author_of)" "a bare bdh-ai name gains a session"

CASE="env-fallback"
setup "bdh-ai (contractor/hog)"
run_hook "" CLAUDE_CODE_SESSION_ID="0123abcd-0000"
assert_eq "bdh-ai (contractor/hog, session 0123abcd)" "$(author_of)" "falls back to CLAUDE_CODE_SESSION_ID when stdin carries none"

CASE="headless"
setup "bdh-ai (architect)"
run_hook "{\"session_id\":\"$SID\"}" GITHUB_ACTIONS=true
assert_eq "0" "$(wc -c < "$ENVF" | tr -d ' ')" "writes nothing inside GitHub Actions, where commits must name bdh-org-coder[bot]"

CASE="human"
setup "Brian Holland"
run_hook "{\"session_id\":\"$SID\"}"
assert_eq "0" "$(wc -c < "$ENVF" | tr -d ' ')" "writes nothing for an identity that is not bdh-ai"

CASE="no-env-file"
setup "bdh-ai (architect)"
printf '{"session_id":"%s"}' "$SID" | env -u GITHUB_ACTIONS -u CLAUDE_ENV_FILE HOME="$H" bash "$HOOK"
assert_eq "0" "$?" "exits 0 when Claude Code provides no CLAUDE_ENV_FILE"

CASE="rerun"
setup "bdh-ai (architect)"
echo "export OTHER_HOOK=1" > "$ENVF"
run_hook "{\"session_id\":\"$SID\"}"
run_hook "{\"session_id\":\"$SID\"}"
assert_eq "2" "$(grep -c 'GIT_' "$ENVF")" "a second SessionStart replaces its own lines instead of stacking them"
assert_eq "1" "$(grep -c 'OTHER_HOOK' "$ENVF")" "and leaves another hook's line alone"

CASE="hostile-id"
setup "bdh-ai (architect)"
run_hook '{"session_id":"x$(touch /tmp/pwned-755)y"}'
if [ -e /tmp/pwned-755 ]; then notok "shell syntax in the session id executed"; rm -f /tmp/pwned-755; else ok "shell syntax in the session id never executes"; fi
( set +u; . "$ENVF" ) 2>/dev/null
if [ -e /tmp/pwned-755 ]; then notok "sourcing the env file executed the id"; rm -f /tmp/pwned-755; else ok "and sourcing the env file is inert"; fi
case "$(cat "$ENVF")" in *'$('*|*'`'*) notok "shell syntax reached the env file";; *) ok "only hex survives into the env file";; esac

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
