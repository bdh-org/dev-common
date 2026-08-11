#!/usr/bin/env bash
# setup-claude-identity.test.sh -- the CI gate for
# devcontainer/setup-claude-identity.sh (bdh-org/dev-common#157).
#
# That script runs during setup in EVERY devcontainer across the fleet, and it
# writes to two files whose failure modes are expensive:
#
#   * the identity gitconfig, which is bind-mounted from the host and therefore
#     SHARED by every container -- a role-qualified name written there labels
#     every session identically, and a half-finished include migration leaves it
#     carrying two competing include.path entries where which one wins is decided
#     by ordering rather than by intent;
#   * ~/.gitconfig-role, container-local, which must set user.name and NOTHING
#     else -- a user.email there re-opens bdh-org/home-infra#317, where two repos
#     spent weeks attributing container commits to a person.
#
# Until this file existed, #154 and #156 both merged on the strength of the
# author running the script by hand against temporary $HOMEs. The assertions
# below are those manual checks, encoded.
#
# The script takes exactly two inputs -- $HOME and $PROJECT_NAME -- and touches
# nothing else, so a temp $HOME per case is a complete test bed. Every case runs
# the REAL script; nothing here re-implements it.
#
# Usage:  bash tests/setup-claude-identity.test.sh      (or: make test)

set -uo pipefail   # deliberately NOT -e: every case runs, then we report

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$REPO_ROOT/devcontainer/setup-claude-identity.sh"

BDH_EMAIL="282552773+bdh-ai@users.noreply.github.com"

pass=0
fail=0
CASE="(none)"
LOG=""

# --- harness ---------------------------------------------------------------

ok()   { pass=$((pass + 1)); printf 'ok     - %s: %s\n' "$CASE" "$1"; }
notok() {
  fail=$((fail + 1))
  printf 'NOT OK - %s: %s\n' "$CASE" "$1"
  if [ -n "$LOG" ] && [ -s "$LOG" ]; then
    printf '         --- script output ---\n'
    sed 's/^/         /' "$LOG"
  fi
}

assert_eq() { # want got description
  if [ "$1" = "$2" ]; then ok "$3"; else notok "$3 (want '$1', got '$2')"; fi
}

assert_absent() { # path description
  if [ -e "$1" ]; then notok "$2 ($1 still exists)"; else ok "$2"; fi
}

assert_symlink_to() { # link target description
  local got
  got=$(readlink "$1" 2>/dev/null || echo "<not a symlink>")
  assert_eq "$2" "$got" "$3"
}

# Run the real script against a throwaway $HOME. `env -i` means the case
# controls PROJECT_NAME absolutely -- including the case that leaves it unset,
# which would otherwise inherit whatever the CI runner exports.
run_script() { # home [project_name]
  local home="$1"
  LOG="$home/.script-output"
  mkdir -p "$home"
  if [ "$#" -ge 2 ]; then
    env -i HOME="$home" PATH="$PATH" GIT_CONFIG_NOSYSTEM=1 PROJECT_NAME="$2" \
      bash "$SCRIPT" >"$LOG" 2>&1
  else
    env -i HOME="$home" PATH="$PATH" GIT_CONFIG_NOSYSTEM=1 \
      bash "$SCRIPT" >"$LOG" 2>&1
  fi
}

# What git ACTUALLY resolves for a key in that $HOME -- the include chain
# followed, exactly as a commit in a devcontainer would see it. Run from a
# scratch cwd so no surrounding repo's .git/config can colour the answer, and
# with the system config off so a CI image's /etc/gitconfig cannot either.
effective() { # home key
  ( cd /tmp || exit 1
    env -i HOME="$1" PATH="$PATH" GIT_CONFIG_NOSYSTEM=1 \
      git config --get "$2" 2>/dev/null )
}

# The identity gitconfig -- the file that is shared across all containers.
gitconfig() { echo "$1/.config/ai/claude/identity/.gitconfig"; }

include_paths() { # home -> one per line
  env -i HOME="$1" PATH="$PATH" GIT_CONFIG_NOSYSTEM=1 \
    git config --file "$(gitconfig "$1")" --get-all include.path 2>/dev/null
}

new_home() { mktemp -d "${TMPDIR:-/tmp}/identity-test.XXXXXX"; }

# Assertions that must hold after EVERY run, whatever the case: the symlinks
# point into the identity tree, the shared file carries exactly one include,
# and neither file has picked up something it must never hold.
assert_invariants() { # home
  local home="$1" gc
  gc=$(gitconfig "$home")

  assert_symlink_to "$home/.gitconfig" "$gc" "~/.gitconfig symlinks to the identity gitconfig"
  assert_symlink_to "$home/.config/gh" "$home/.config/ai/claude/identity/gh" \
    "~/.config/gh symlinks to the identity gh dir"

  assert_eq "1" "$(include_paths "$home" | wc -l | tr -d ' ')" \
    "shared gitconfig carries exactly one include.path"
  assert_eq "~/.gitconfig-role" "$(include_paths "$home")" \
    "the one include.path is ~/.gitconfig-role"

  # The role belongs in the container-local file only. If a role-qualified name
  # ever lands in the shared file, every devcontainer on the host inherits it.
  if grep -q 'bdh-ai (' "$gc"; then
    notok "shared gitconfig must not carry a role-qualified user.name"
  else
    ok "shared gitconfig carries no role-qualified user.name"
  fi

  # home-infra#317: the role file is display-only. An email here is the exact
  # shape of the bug that took weeks to find.
  if grep -qi 'email' "$home/.gitconfig-role"; then
    notok "~/.gitconfig-role must not set user.email"
  else
    ok "~/.gitconfig-role sets no user.email"
  fi
}

# --- case 1: fresh host, architect workspace -------------------------------

CASE="fresh/home-infra"
H=$(new_home)
run_script "$H" home-infra
assert_eq "bdh-ai (architect)" "$(effective "$H" user.name)" "user.name is the architect role"
assert_eq "$BDH_EMAIL" "$(effective "$H" user.email)" "user.email is bdh-ai's, untouched"
assert_invariants "$H"
rm -rf "$H"

# --- case 2: fresh host, a contractor repo ---------------------------------

CASE="fresh/hog"
H=$(new_home)
run_script "$H" hog
assert_eq "bdh-ai (contractor/hog)" "$(effective "$H" user.name)" "user.name names the repo's devcontainer"
assert_eq "$BDH_EMAIL" "$(effective "$H" user.email)" "user.email is bdh-ai's, untouched"
assert_invariants "$H"
rm -rf "$H"

# --- case 3: PROJECT_NAME unset --------------------------------------------
# env.sh not sourced, or a container that predates it. Must still produce a
# valid config rather than "bdh-ai ()" or a hard failure.

CASE="fresh/no-PROJECT_NAME"
H=$(new_home)
run_script "$H"
assert_eq "bdh-ai (unknown)" "$(effective "$H" user.name)" "user.name falls back to unknown"
assert_invariants "$H"
rm -rf "$H"

# --- case 4: migration off the old ~/.gitconfig-seat name ------------------
# A host set up before #156 has the OLD include and the stale file. Both must
# go, or the shared gitconfig accumulates two includes and the dead one wins or
# loses by ordering.

CASE="migrate/seat-only"
H=$(new_home)
mkdir -p "$H/.config/ai/claude/identity"
cat > "$(gitconfig "$H")" <<EOF
[user]
	name = bdh-ai
	email = $BDH_EMAIL
[init]
	defaultBranch = main
[include]
	path = ~/.gitconfig-seat
EOF
printf '[user]\n\tname = bdh-ai (contractor/hog)\n' > "$H/.gitconfig-seat"
run_script "$H" hog
assert_eq "bdh-ai (contractor/hog)" "$(effective "$H" user.name)" "user.name comes from the new role file"
assert_eq "$BDH_EMAIL" "$(effective "$H" user.email)" "user.email survives the migration unchanged"
assert_absent "$H/.gitconfig-seat" "the stale seat file is removed"
if grep -q 'gitconfig-seat' "$(gitconfig "$H")"; then
  notok "the old seat include is gone from the shared gitconfig"
else
  ok "the old seat include is gone from the shared gitconfig"
fi
assert_invariants "$H"
rm -rf "$H"

# --- case 5: a half-migrated host carrying BOTH includes -------------------
# The state a host lands in if the migration ever runs partially. This is the
# "two competing include.path entries" failure named in #157, so it is asserted
# directly rather than inferred from case 4.

CASE="migrate/both-includes"
H=$(new_home)
mkdir -p "$H/.config/ai/claude/identity"
cat > "$(gitconfig "$H")" <<EOF
[user]
	name = bdh-ai
	email = $BDH_EMAIL
[include]
	path = ~/.gitconfig-seat
	path = ~/.gitconfig-role
EOF
printf '[user]\n\tname = bdh-ai (STALE)\n' > "$H/.gitconfig-seat"
run_script "$H" oleo
assert_eq "bdh-ai (contractor/oleo)" "$(effective "$H" user.name)" "the stale include cannot win"
assert_absent "$H/.gitconfig-seat" "the stale seat file is removed"
assert_invariants "$H"
rm -rf "$H"

# --- case 6: idempotency ----------------------------------------------------
# The script runs on every container start, not just on create.

CASE="idempotent/three-runs"
H=$(new_home)
run_script "$H" ferret
run_script "$H" ferret
run_script "$H" ferret
assert_eq "bdh-ai (contractor/ferret)" "$(effective "$H" user.name)" "user.name is stable across runs"
assert_eq "$BDH_EMAIL" "$(effective "$H" user.email)" "user.email is stable across runs"
assert_eq "1" "$(grep -c 'name = bdh-ai' "$H/.gitconfig-role")" "the role file is rewritten, not appended to"
assert_invariants "$H"
rm -rf "$H"

# --- case 7: the same host, a different devcontainer -----------------------
# One host runs many containers and they share the identity tree; only the
# container-local role file differs. Re-running with another PROJECT_NAME must
# replace the role outright.

CASE="rerun/role-changes"
H=$(new_home)
run_script "$H" home-infra
assert_eq "bdh-ai (architect)" "$(effective "$H" user.name)" "first run sets architect"
run_script "$H" canary
assert_eq "bdh-ai (contractor/canary)" "$(effective "$H" user.name)" "second run replaces it with the new role"
assert_invariants "$H"
rm -rf "$H"

# --- case 8: gh left a real ~/.config/gh directory behind ------------------
# gh creates one on first invocation if it beat us here; the script removes it
# so the symlink can take its place.

CASE="preexisting/gh-dir"
H=$(new_home)
mkdir -p "$H/.config/gh"
printf 'git_protocol: ssh\n' > "$H/.config/gh/config.yml"
run_script "$H" brief
assert_invariants "$H"
assert_eq "https" "$(grep -m1 '^git_protocol:' "$H/.config/gh/config.yml" | awk '{print $2}')" \
  "the identity gh config replaces the one gh left behind"
rm -rf "$H"

# --- case 9: a host whose identity gitconfig is already customised ---------
# The bootstrap heredoc must fire ONLY on a fresh host. On an existing one the
# script ensures the include and nothing else -- it must not overwrite a
# hand-edited user section.

CASE="existing/custom-gitconfig"
H=$(new_home)
mkdir -p "$H/.config/ai/claude/identity"
cat > "$(gitconfig "$H")" <<EOF
[user]
	name = bdh-ai
	email = custom@example.com
[core]
	editor = vim
EOF
run_script "$H" roy
assert_eq "custom@example.com" "$(effective "$H" user.email)" "an existing user.email is left alone"
assert_eq "vim" "$(effective "$H" core.editor)" "unrelated existing settings survive"
assert_eq "bdh-ai (contractor/roy)" "$(effective "$H" user.name)" "the role include is added to the existing file"
assert_invariants "$H"
rm -rf "$H"

# --- report ----------------------------------------------------------------

LOG=""
echo
echo "setup-claude-identity: $pass passed, $fail failed"
[ "$fail" -eq 0 ] || exit 1
