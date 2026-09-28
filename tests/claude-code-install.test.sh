#!/usr/bin/env bash
# claude-code-install.test.sh -- the gate for .github/actions/claude-code-install
# (bdh-org/home-infra#881).
#
# That action is the ONLY place the host-wide Claude Code install lock is now
# held: it installs the CLI, copies it somewhere private, and releases, so the
# long agent step runs unlocked. The properties a careless rewrite would break:
#
#   - the installer runs INSIDE the lock (the whole point of the lock);
#   - the lock is released on every exit path -- success, installer failure,
#     wrong version -- or one bad install wedges every agent run on the host;
#   - the path handed back is a private COPY, so a later run's install cannot
#     rewrite the file this run's agent is executing (#541, moved to the run);
#   - the version is claude-code-action's own pin, read from its checkout, and
#     an unreadable pin degrades to `stable` with a warning, not a red fleet;
#   - an already-installed version is reused without running the installer.
#
# The installer is a stub: no network, sub-second.
#
# Usage:  bash tests/claude-code-install.test.sh      (or: make test)

set -uo pipefail   # deliberately NOT -e: every case runs, then we report

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL_SH="$REPO_ROOT/.github/actions/claude-code-install/install.sh"
LOCK_SH="$REPO_ROOT/.github/actions/claude-install-lock/lock.sh"

pass=0
fail=0
CASE="(none)"

ok()    { pass=$((pass + 1)); printf 'ok     - %s: %s\n' "$CASE" "$1"; }
notok() { fail=$((fail + 1)); printf 'NOT OK - %s: %s\n' "$CASE" "$1"; }
assert_eq() { if [ "$1" = "$2" ]; then ok "$3"; else notok "$3"; printf '         want: %s\n         got:  %s\n' "$1" "$2"; fi; }
assert_contains() { case "$1" in *"$2"*) ok "$3";; *) notok "$3 (no '$2' in output)";; esac; }
assert_absent() { case "$1" in *"$2"*) notok "$3 (found '$2')";; *) ok "$3";; esac; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# A fake claude-code-action checkout carrying a pin the way upstream writes it.
CCA="$TMP/cca"
mkdir -p "$CCA/src/entrypoints"
printf '  const claudeCodeVersion = "2.1.283";\n' > "$CCA/src/entrypoints/run.ts"

# The stub installer mimics the real layout -- versions/<v> behind a
# ~/.local/bin/claude symlink -- and RECORDS whether the lock was held while it
# ran, which is the property under test. `stable` resolves to 9.9.9.
# STUB_REPORTS overrides what the installed binary claims to be.
STUB="$TMP/stub-install.sh"
cat > "$STUB" <<'EOF'
v="$1"; [ "$v" = stable ] && v=9.9.9
echo "called $1" >> "$HOME/installer.log"
if [ -d "$HOME/.claude/install.lock.d" ]; then echo held >> "$HOME/lock-during-install"; else echo FREE >> "$HOME/lock-during-install"; fi
[ -z "${STUB_FAIL:-}" ] || exit 1
mkdir -p "$HOME/.local/share/claude/versions" "$HOME/.local/bin"
printf '#!/bin/sh\necho "%s (Claude Code)"\n' "${STUB_REPORTS:-$v}" > "$HOME/.local/share/claude/versions/$v"
chmod +x "$HOME/.local/share/claude/versions/$v"
ln -sfn "$HOME/.local/share/claude/versions/$v" "$HOME/.local/bin/claude"
EOF

fresh_home() { H="$TMP/home-$1"; rm -rf "$H"; mkdir -p "$H"; OUT="$H/out"; GO="$H/github-output"; : > "$GO"; }

run_install() { # extra env assignments...
  env HOME="$H" LOCK_OWNER="test-run" LOCK_SH="$LOCK_SH" CCA_DIR="$CCA" \
      CLAUDE_OUT_DIR="$OUT" GITHUB_OUTPUT="$GO" INSTALL_RETRY_SLEEP=0 \
      CLAUDE_INSTALL_CMD="bash '$STUB' \"\$1\"" \
      LOCK_WAIT_SECONDS=1 LOCK_POLL_SECONDS=1 \
      "$@" bash "$INSTALL_SH" 2>&1
}

CASE="script"
if bash -n "$INSTALL_SH" 2>/dev/null; then ok "install.sh parses"; else notok "install.sh has a syntax error"; fi

# --- the normal path ----------------------------------------------------------

CASE="install"
fresh_home install
out="$(run_install)"; rc=$?
assert_eq "0" "$rc" "a fresh install succeeds"
assert_eq "held" "$(cat "$H/lock-during-install" 2>/dev/null)" "the installer ran INSIDE the lock"
assert_eq "called 2.1.283" "$(cat "$H/installer.log" 2>/dev/null)" "it installed claude-code-action's pinned version"
assert_contains "$out" "claude-code-action's own pin" "and says where the version came from"
if [ -d "$H/.claude/install.lock.d" ]; then notok "the lock is still held after the step ended"; else ok "the lock is released when the install is done"; fi
assert_eq "path=$OUT/claude" "$(grep '^path=' "$GO")" "outputs the private copy's path"
assert_eq "version=2.1.283" "$(grep '^version=' "$GO")" "outputs the version it verified"
if [ -x "$OUT/claude" ] && [ ! -L "$OUT/claude" ]; then ok "the copy is a real executable file, not a link into the shared tree"; else notok "the handed-back path is missing or a symlink"; fi

CASE="isolation"
# A later run's install rewrites the shared file. The copy this run is executing
# must not change -- that is the whole reason for copying.
printf '#!/bin/sh\necho "0.0.1 (Claude Code)"\n' > "$H/.local/share/claude/versions/2.1.283"
assert_eq "2.1.283 (Claude Code)" "$("$OUT/claude" --version)" "rewriting the shared install does not touch this run's copy"

CASE="reuse"
fresh_home reuse
run_install >/dev/null
: > "$H/installer.log"
out="$(run_install STUB_FAIL=1)"; rc=$?
assert_eq "0" "$rc" "an already-installed pinned version succeeds even with a broken installer"
assert_eq "" "$(cat "$H/installer.log")" "and the installer is not run at all"
assert_contains "$out" "reusing it" "and says it reused the install"

# --- every failure releases the lock -----------------------------------------

CASE="installer-fails"
fresh_home fails
out="$(run_install STUB_FAIL=1)"; rc=$?
assert_eq "1" "$rc" "a failing installer fails the step"
assert_eq "3" "$(wc -l < "$H/installer.log" | tr -d ' ')" "after three attempts, as claude-code-action itself retried"
assert_contains "$out" "failed 3 times" "and says so"
if [ -d "$H/.claude/install.lock.d" ]; then notok "a failed install left the lock held -- every later run would wait out the stale window"; else ok "the lock is released after a failed install"; fi

CASE="wrong-version"
fresh_home wrong
out="$(run_install STUB_REPORTS=1.0.0)"; rc=$?
assert_eq "1" "$rc" "a binary reporting a different version fails the step"
assert_contains "$out" "reports 1.0.0" "and names what it got"
if [ -d "$H/.claude/install.lock.d" ]; then notok "the lock is still held after a version mismatch"; else ok "the lock is released after a version mismatch"; fi

CASE="explicit-version"
fresh_home explicit
out="$(run_install CLAUDE_CODE_VERSION=2.2.0)"; rc=$?
assert_eq "0" "$rc" "an explicit version input is honoured"
assert_eq "called 2.2.0" "$(cat "$H/installer.log" 2>/dev/null)" "and overrides the action's pin"

CASE="bad-version"
fresh_home bad
out="$(run_install CLAUDE_CODE_VERSION='1; rm -rf /')"; rc=$?
assert_eq "1" "$rc" "a version that is not a version is refused"
if [ -f "$H/installer.log" ]; then notok "the installer ran with a malformed version"; else ok "before the installer ever runs"; fi

# --- an unreadable pin degrades, it does not fail the fleet ------------------

CASE="no-pin"
fresh_home nopin
out="$(run_install CCA_DIR="$TMP/nowhere")"; rc=$?
assert_eq "0" "$rc" "an unreadable action pin still installs"
assert_contains "$out" "::warning::" "but warns"
assert_eq "called stable" "$(cat "$H/installer.log" 2>/dev/null)" "and installs stable"
assert_eq "version=9.9.9" "$(grep '^version=' "$GO")" "resolving the binary through ~/.local/bin/claude"

# --- contention: the lock still blocks ---------------------------------------

CASE="contention"
fresh_home busy
mkdir -p "$H/.claude/install.lock.d" && echo "other-run" > "$H/.claude/install.lock.d/owner"
out="$(run_install)"; rc=$?
assert_eq "1" "$rc" "a held lock is waited on, then the step fails rather than installing anyway"
if [ -f "$H/installer.log" ]; then notok "the installer ran while another run held the lock"; else ok "the installer never ran"; fi
assert_eq "other-run" "$(cat "$H/.claude/install.lock.d/owner" 2>/dev/null)" "and the other run's lock is left alone"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
