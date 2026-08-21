#!/usr/bin/env bash
# path-dedup.test.sh -- the CI gate for the PATH handling that
# devcontainer/setup-base.sh writes into ~/.bashrc (bdh-org/dev-common#224).
#
# The bug this encodes: PATH resolution is first-match-wins, so a duplicated
# entry is a latent precedence bug -- which copy of a binary runs starts to
# depend on shell nesting depth. Three files prepend unconditionally and are
# re-sourced once per nested shell (/etc/profile.d/00-restore-env.sh, ~/.profile,
# and our own block), and PATH was measured growing 8 entries per level: 10, 18,
# 26 at depths 1, 2, 3.
#
# The property under test is therefore NOT "our line is guarded" -- it is
# IDEMPOTENCE: sourcing the emitted bashrc twice must give the same PATH as
# sourcing it once, and must give it in the same ORDER. Order matters because
# the whole point of the conda prepend is that conda shadows pip.
#
# Every case sources the REAL emitted file; nothing here re-implements the
# dedupe. The harness mirrors setup-claude-identity.test.sh.
#
# Usage:  bash tests/path-dedup.test.sh      (or: make test)

set -uo pipefail   # deliberately NOT -e: every case runs, then we report

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$REPO_ROOT/devcontainer/setup-base.sh"

pass=0
fail=0
CASE="(none)"

# --- harness ---------------------------------------------------------------

ok()   { pass=$((pass + 1)); printf 'ok     - %s: %s\n' "$CASE" "$1"; }
notok() {
  fail=$((fail + 1))
  printf 'NOT OK - %s: %s\n' "$CASE" "$1"
  [ -n "${2:-}" ] && printf '         got: %s\n' "$2"
  return 0
}

# Extract just the two PATH-relevant fragments setup-base.sh emits, without
# running the whole script (which installs miniforge, tmux and a runtime).
# Taking them from the file keeps this test honest: edit the script and this
# test follows, which is the point of not re-implementing the dedupe here.
extract_bashrc_path_parts() {
  local out="$1"
  : > "$out"
  # The conda/.local prepend line, with setup-base.sh's heredoc escaping undone.
  #
  # Matched on its full escaped text, NOT on '^export PATH=', because the script
  # has three such lines and the first is its own install-time
  # `export PATH="$MINIFORGE_DIR/bin:$PATH"` at the top. Anchoring loosely
  # silently extracted that one instead, and with MINIFORGE_DIR unset it
  # expanded to a bare "/bin:$PATH" -- the cases below then ran against a PATH
  # our block had never touched, and the two sanity checks still said ok.
  grep -m1 -F 'export PATH="\$HOME/miniforge3/bin' "$SCRIPT" | sed 's/\\\$/$/g' >> "$out"
  # the dedupe block: from its marker to the function's teardown
  awk '/^# --- devcontainer PATH dedupe ---$/,/^unset -f _dc_dedup_path$/' \
    "$SCRIPT" >> "$out"
}

FRAG="$(mktemp)"
trap 'rm -f "$FRAG"' EXIT
extract_bashrc_path_parts "$FRAG"

# Sanity: the extraction found both halves. Without this, a rename in
# setup-base.sh would silently empty the fragment and every case below would
# "pass" against nothing -- the skipped-test false green.
CASE="extraction"
# Assert on the CONTENT, not merely that some line matched. The first version
# of this check asked only for '^export PATH=' and passed against the wrong
# line for exactly that reason.
if grep -q 'miniforge3/bin:\$HOME/\.local/bin' "$FRAG"; then
  ok "extracted the line that prepends BOTH miniforge and .local/bin"
else
  notok "did not extract the conda/.local prepend from $SCRIPT" "$(head -1 "$FRAG")"
fi
if grep -q '_dc_dedup_path$' "$FRAG"; then
  ok "found the dedupe block"
else
  notok "no dedupe block extracted from $SCRIPT -- did the marker change?"
fi

# Run the fragment N times over a starting PATH, print the resulting PATH.
path_after() {
  local times="$1" start="$2" i
  local script="PATH='$start'; HOME=/home/tester"
  for ((i = 0; i < times; i++)); do script="$script; . '$FRAG'"; done
  script="$script; printf '%s' \"\$PATH\""
  bash -c "$script"
}

# --- cases -----------------------------------------------------------------

CASE="idempotence"
BASE="/usr/local/bin:/usr/bin:/bin"
one="$(path_after 1 "$BASE")"
two="$(path_after 2 "$BASE")"
seven="$(path_after 7 "$BASE")"
if [ "$one" = "$two" ]; then
  ok "sourcing twice equals sourcing once"
else
  notok "second source changed PATH" "once=$one twice=$two"
fi
if [ "$one" = "$seven" ]; then
  ok "sourcing seven times equals sourcing once (the observed nesting depth)"
else
  notok "PATH still grows with nesting" "once=$one seven=$seven"
fi

CASE="no duplicates"
dupes="$(printf '%s' "$one" | tr ':' '\n' | sort | uniq -d)"
if [ -z "$dupes" ]; then
  ok "no entry appears twice"
else
  notok "duplicate entries survived" "$(printf '%s' "$dupes" | tr '\n' ' ')"
fi

CASE="precedence"
# The reason the prepend exists: conda must shadow pip's ~/.local/bin.
conda_pos="$(printf '%s' "$one" | tr ':' '\n' | grep -n '^/home/tester/miniforge3/bin$' | cut -d: -f1)"
local_pos="$(printf '%s' "$one" | tr ':' '\n' | grep -n '^/home/tester/.local/bin$' | cut -d: -f1)"
if [ -n "$conda_pos" ] && [ -n "$local_pos" ] && [ "$conda_pos" -lt "$local_pos" ]; then
  ok "miniforge/bin still precedes .local/bin (conda shadows pip)"
else
  notok "conda no longer takes priority" "conda=$conda_pos local=$local_pos"
fi
if [ "$(printf '%s' "$one" | cut -d: -f1)" = "/home/tester/miniforge3/bin" ]; then
  ok "miniforge/bin is first"
else
  notok "miniforge/bin is not first" "$one"
fi

CASE="order is stable under re-sourcing"
# Not implied by "twice == once" alone if a future edit reorders on each pass;
# assert the ordering explicitly against a PATH that already contains our
# entries in the wrong order, which is exactly the re-source case.
pre="/home/tester/.local/bin:/usr/bin:/home/tester/miniforge3/bin"
a="$(path_after 1 "$pre")"
b="$(path_after 4 "$pre")"
if [ "$a" = "$b" ]; then
  ok "converges from a PATH that already holds the entries out of order"
else
  notok "did not converge" "1x=$a 4x=$b"
fi

CASE="degenerate input"
# A stray leading, trailing or doubled colon means "current directory" on PATH.
# The dedupe drops empty entries, so assert that rather than leaving it to luck.
weird="$(path_after 1 ":/usr/bin::/bin:")"
case ":$weird:" in
  *"::"*) notok "an empty PATH entry survived" "$weird" ;;
  *)      ok "empty entries dropped (no implicit current directory)" ;;
esac
if [ "${weird#:}" = "$weird" ] && [ "${weird%:}" = "$weird" ]; then
  ok "no leading or trailing colon"
else
  notok "leading or trailing colon survived" "$weird"
fi

CASE="no leakage into the shell"
# The helper must not stay defined -- ~/.bashrc is the user's interactive
# namespace, and a stray _dc_dedup_path there is ours leaking into it.
leaked="$(bash -c "PATH='$BASE'; HOME=/home/tester; . '$FRAG'; declare -F _dc_dedup_path || true")"
if [ -z "$leaked" ]; then
  ok "_dc_dedup_path is unset afterwards"
else
  notok "_dc_dedup_path leaked into the shell" "$leaked"
fi

CASE="rollout"
# The dedupe MUST sit behind its own marker. If it were inside the $MARKER
# block, every already-built container -- which all carry that marker -- would
# never receive it, and the fix would reach only new containers.
if grep -q 'PATH_MARKER="# --- devcontainer PATH dedupe ---"' "$SCRIPT"; then
  ok "dedupe is appended behind its own marker"
else
  notok "dedupe has no separate marker: existing containers would never get it"
fi

# --- report ----------------------------------------------------------------

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
