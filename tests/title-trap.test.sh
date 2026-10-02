#!/usr/bin/env bash
# title-trap.test.sh -- the CI gate for the title-trap removal that
# devcontainer/setup-base.sh writes into ~/.bashrc.
#
# The bug this encodes: the devcontainers base image's ~/.bashrc, when TERM is
# exactly "xterm" (what `docker exec -t` injects, so what `make dc-shell` gets),
# installs a DEBUG trap that echoes every command into the terminal title with
# `echo -ne`. Our PS1 assignment runs later in the same file and contains
# literal \033[..m codes; echoed with -e they become real ESC bytes inside the
# title sequence, the terminal aborts the title, and the rest of the PS1 line is
# printed as junk in front of the first prompt.
#
# Two properties, because the fix has two halves:
#   1. BEHAVIOUR -- with our block between the image's block and the PS1 line,
#      sourcing the file under TERM=xterm emits no PS1 text. A control case
#      without our block must LEAK, or this test could not see the bug at all.
#   2. PLACEMENT -- the installer puts the block BEFORE the PS1 line both in a
#      fresh ~/.bashrc and in one that already carries the devcontainer block
#      (every already-built container), and does so exactly once.
#
# Every case runs text taken from the REAL setup-base.sh; nothing here
# re-implements the fix. The harness mirrors path-dedup.test.sh.
#
# Usage:  bash tests/title-trap.test.sh      (or: make test)

set -uo pipefail   # deliberately NOT -e: every case runs, then we report

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$REPO_ROOT/devcontainer/setup-base.sh"

pass=0
fail=0
CASE="(none)"

ok()   { pass=$((pass + 1)); printf 'ok     - %s: %s\n' "$CASE" "$1"; }
notok() {
  fail=$((fail + 1))
  printf 'NOT OK - %s: %s\n' "$CASE" "$1"
  [ -n "${2:-}" ] && printf '         got: %s\n' "$2"
  return 0
}

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT

MARKER="# --- devcontainer setup ---"
TITLE_MARKER="# --- devcontainer title trap off ---"

# The installer section of setup-base.sh, verbatim, between its two sentinels.
# It needs only $BASHRC and $MARKER, so it can run here without the rest of the
# script (which installs miniforge and a runtime).
INSTALL="$T/install.sh"
awk '/^# >>> title-trap install >>>$/,/^# <<< title-trap install <<<$/' "$SCRIPT" > "$INSTALL"

# The PS1 line setup-base.sh emits, with its heredoc escaping undone and the
# host label filled in -- the line whose \033 codes are what leaks.
PS1_LINE="$T/ps1.sh"
grep -m1 -F "PS1='\\\${debian_chroot" "$SCRIPT" \
  | sed -e 's/\\\\\\\$/\\$/' -e 's/\\\$/$/g' -e 's/\${PS1_HOST}/host:proj/' > "$PS1_LINE"

# The base image's block, verbatim from mcr.microsoft.com/devcontainers/python
# ~/.bashrc. A fixture: it is the image's code, not ours, and it is the thing
# being defended against.
IMAGE_BLOCK="$T/image.sh"
cat > "$IMAGE_BLOCK" <<'EOF'
if [[ "$TERM" == "xterm" ]]; then
    preexec() {
        local cmd="${BASH_COMMAND}"
        echo -ne "\033]0;${USER}@${HOSTNAME}: ${cmd}\007"
    }
    precmd() {
        echo -ne "\033]0;${USER}@${HOSTNAME}: ${SHELL}\007"
    }
    trap 'preexec' DEBUG
    PROMPT_COMMAND="${PROMPT_COMMAND:+$PROMPT_COMMAND; }precmd"
fi
EOF

CASE="extraction"
# Without these, a rename in setup-base.sh would empty a fragment and every
# case below would pass against nothing.
if grep -qF 'trap - DEBUG' "$INSTALL" && grep -qF "$TITLE_MARKER" "$INSTALL"; then
  ok "extracted the installer section, with the trap removal in it"
else
  notok "no installer section extracted from $SCRIPT -- did the sentinels change?"
fi
if grep -qF '\[\033[01;32m\]' "$PS1_LINE" && bash -n "$PS1_LINE" 2>/dev/null; then
  ok "extracted the PS1 line, still carrying its literal \\033 codes"
else
  notok "did not extract a usable PS1 line from $SCRIPT" "$(cat "$PS1_LINE")"
fi

# Run the real installer against a given bashrc.
install_into() { BASHRC="$1" MARKER="$MARKER" bash -euo pipefail "$INSTALL"; }

# What a shell prints while sourcing a bashrc, made visible. USER/HOSTNAME are
# pinned so `set -u`-less expansion in the image block is deterministic.
emitted() { TERM="$2" USER=u HOSTNAME=h bash -c ". '$1'" 2>&1 | cat -v; }

# --- behaviour -------------------------------------------------------------

CASE="control: the bug is visible to this test"
BAD="$T/bad.bashrc"
cat "$IMAGE_BLOCK" "$PS1_LINE" > "$BAD"
out="$(emitted "$BAD" xterm)"
if printf '%s' "$out" | grep -qF '^[[01;32m'; then
  ok "without the fix, TERM=xterm leaks the PS1 line with real ESC bytes"
else
  notok "the unfixed fixture did not leak -- this test cannot detect the bug" "$out"
fi

CASE="fresh bashrc"
FRESH="$T/fresh.bashrc"
cp "$IMAGE_BLOCK" "$FRESH"
install_into "$FRESH"
# then what setup-base.sh appends next: the devcontainer block, PS1 included
{ printf '\n%s\n' "$MARKER"; cat "$PS1_LINE"; } >> "$FRESH"
out="$(emitted "$FRESH" xterm)"
if printf '%s' "$out" | grep -qF '01;32m'; then
  notok "PS1 text still reaches the terminal" "$out"
else
  ok "nothing from the PS1 line reaches the terminal under TERM=xterm"
fi

CASE="already-built container"
# The devcontainer block is already there; the fix must land IN FRONT of it.
OLD="$T/old.bashrc"
{ cat "$IMAGE_BLOCK"; printf '\n%s\n' "$MARKER"; cat "$PS1_LINE"; printf 'alias l=ls\n'; } > "$OLD"
cp "$OLD" "$T/old.before"
install_into "$OLD"
t_line="$(grep -nxF -- "$TITLE_MARKER" "$OLD" | cut -d: -f1)"
m_line="$(grep -nxF -- "$MARKER" "$OLD" | cut -d: -f1)"
if [ -n "$t_line" ] && [ -n "$m_line" ] && [ "$t_line" -lt "$m_line" ]; then
  ok "block inserted before the existing devcontainer block"
else
  notok "block is not ahead of the devcontainer block" "title=$t_line marker=$m_line"
fi
out="$(emitted "$OLD" xterm)"
if printf '%s' "$out" | grep -qF '01;32m'; then
  notok "PS1 text still reaches the terminal" "$out"
else
  ok "nothing from the PS1 line reaches the terminal under TERM=xterm"
fi
# Insertion must add lines only: removing ours gives back the original file.
awk -v t="$TITLE_MARKER" -v m="$MARKER" '
  $0 == t { skip = 1 } $0 == m { skip = 0 } !skip { print }' "$OLD" > "$T/old.stripped"
if diff -q <(sed '/^$/d' "$T/old.before") <(sed '/^$/d' "$T/old.stripped") >/dev/null; then
  ok "every pre-existing line survived, in order"
else
  notok "the insert changed pre-existing content" "$(diff "$T/old.before" "$T/old.stripped" | head -5)"
fi

CASE="idempotence"
cp "$OLD" "$T/old.once"
install_into "$OLD"
if cmp -s "$OLD" "$T/old.once"; then
  ok "a second run changes nothing"
else
  notok "second run modified the bashrc" "$(grep -cxF -- "$TITLE_MARKER" "$OLD") marker lines"
fi

# --- what the block does to the shell --------------------------------------

BLOCK="$T/block.sh"
awk -v t="$TITLE_MARKER" '$0 == t { on = 1 } on { print }' "$FRESH" \
  | awk -v m="$MARKER" '$0 == m { exit } { print }' > "$BLOCK"

# Each case below is ONE file, as ~/.bashrc is. That is not a convenience: bash
# hides the DEBUG trap from a file it sources (no functrace), so a block sourced
# on its own sees no trap, removes nothing, and the case fails for a reason that
# has nothing to do with the code under test.
REPORT='printf "trap=[%s] pc=[%s]" "$(trap -p DEBUG)" "$PROMPT_COMMAND"'

CASE="shell state after the block"
{ printf "PROMPT_COMMAND='history -a'\n"; cat "$IMAGE_BLOCK" "$BLOCK"; printf '%s\n' "$REPORT"; } > "$T/state.bashrc"
state="$(emitted "$T/state.bashrc" xterm | sed 's/.*trap=/trap=/')"
if [ "$state" = "trap=[] pc=[history -a]" ]; then
  ok "DEBUG trap gone, precmd stripped, the user's own PROMPT_COMMAND kept"
else
  notok "unexpected trap / PROMPT_COMMAND" "$state"
fi

CASE="someone else's DEBUG trap"
{ printf "mine() { :; }\ntrap 'mine' DEBUG\nPROMPT_COMMAND='a; precmd'\n"; cat "$BLOCK"; printf '%s\n' "$REPORT"; } > "$T/foreign.bashrc"
state="$(emitted "$T/foreign.bashrc" xterm)"
if [ "$state" = "trap=[trap -- 'mine' DEBUG] pc=[a; precmd]" ]; then
  ok "a DEBUG trap that is not the image's is left alone, PROMPT_COMMAND untouched"
else
  notok "the block touched a trap it does not own" "$state"
fi

echo
echo "passed: $pass   failed: $fail"
[ "$fail" -eq 0 ]
