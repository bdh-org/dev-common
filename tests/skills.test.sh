#!/usr/bin/env bash
# skills.test.sh -- the shared Claude Code skills (P14) as SHIPPED: that the
# installer in devcontainer/setup-claude.sh really links a new skill, that the
# skill's frontmatter parses, and that every dev-common path the skill names
# still exists (bdh-org/dev-common#326).
#
# WHY A SUITE AT ALL
#
# A skill is instructions, so nothing about it is compiled, imported or run --
# every one of its failure modes is silent:
#
#   * The installer loop does not pick it up. `setup-claude.sh` GLOBS
#     skills/*/, so a new directory is linked for free -- until someone
#     narrows the glob, moves skills/, or lands a skill whose directory name
#     and `name:` disagree. The skill then simply does not appear in any
#     session, and no command fails.
#   * The frontmatter does not parse. Claude Code drops the skill rather than
#     erroring, so the only symptom is absence -- the same shape as the bug
#     above, and indistinguishable from it.
#   * A path the skill names has moved. The skill keeps "working": a session
#     reads it, is sent to a file that is not there, and improvises. Three of
#     this repo's skills point at files in this repo by path, which is the
#     cheapest kind of documentation to let rot.
#
# The first case therefore EXTRACTS the real install block out of
# setup-claude.sh and runs it against a throwaway repo tree, rather than
# re-implementing the loop -- a re-implementation would pass while the shipped
# script did something else, the trap tests/version-bumped.test.sh spells out.
#
# SCOPE. The path and frontmatter cases run over SKILLS below, not over every
# skill in skills/: `ship`, `update-common` and `incorporate-devtemplate`
# predate the frontmatter convention and have none. Adding a skill to that list
# is one line, and the install case covers all of them already.
#
# Usage:  bash tests/skills.test.sh      (or: make test)

set -uo pipefail   # deliberately NOT -e: every case runs, then we report

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SETUP="$REPO_ROOT/devcontainer/setup-claude.sh"

# Skills whose frontmatter and named paths are checked. See SCOPE above.
SKILLS="incorporate-stack-repo"

# The skill this suite was written for; the install case asserts the shipped
# installer links it, with an older skill beside it as the control.
NEW_SKILL="incorporate-stack-repo"
CONTROL_SKILL="ship"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

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

CASE="the files under test exist"
if [ -f "$SETUP" ]; then
  ok "devcontainer/setup-claude.sh is where this suite expects it"
else
  notok "no devcontainer/setup-claude.sh at $SETUP -- moved or renamed"
  printf '\npassed: %d   failed: %d\n' "$pass" "$fail"
  exit 1
fi

# --- 1. the SHIPPED installer links the skill ------------------------------
#
# The block runs from `echo "==> Installing shared Claude Code skills` up to
# the next top-level `# Install the claude-prod shim` comment. Everything
# around it in setup-claude.sh needs sudo and a real container; this block
# needs only $HOME and a repo tree, so it is the part that can be run for real.

extract_install_block() {
  awk '
    /^echo "==> Installing shared Claude Code skills/ { inblock = 1 }
    inblock && /^# Install the claude-prod shim/      { exit }
    inblock                                           { print }
  ' "$SETUP"
}

CASE="the install block is extractable"
BLOCK="$TMP/install-skills.sh"
# The trailing `exit 0` is about the CUT, not about ignoring failures: the last
# statement of the block is the conditional retirement of the legacy
# host-level link (`[ -L ... ] && rm -f ...`), whose status leaks out as the
# extracted script's own when nothing follows it. In setup-claude.sh proper the
# claude-prod shim follows, so it never does. `set -e` above is what still
# fails this case on a real error.
{ echo 'set -euo pipefail'; extract_install_block; echo 'exit 0'; } > "$BLOCK"
if grep -q 'ln -s' "$BLOCK"; then
  ok "setup-claude.sh still carries a skills-install block that symlinks"
else
  notok "no skills-install block found in setup-claude.sh -- renamed or removed" \
        "$(wc -l < "$BLOCK") line(s) extracted"
  printf '\npassed: %d   failed: %d\n' "$pass" "$fail"
  exit 1
fi

# A throwaway consumer repo: <repo>/common/{skills,devcontainer}. The block
# locates itself with BASH_SOURCE, so it must live at common/devcontainer/.
# skills/ is COPIED rather than symlinked: the block resolves its own path with
# `cd .. && pwd`, which is physical, so a symlink would send it at the real
# checkout's PARENT and have it write there.
FAKE_REPO="$TMP/repo"
mkdir -p "$FAKE_REPO/common/devcontainer"
cp -R "$REPO_ROOT/skills" "$FAKE_REPO/common/skills"
cp "$BLOCK" "$FAKE_REPO/common/devcontainer/install-skills.sh"
FAKE_HOME="$TMP/home"
mkdir -p "$FAKE_HOME/.claude/skills"

CASE="the installer runs against a throwaway repo"
if out=$(HOME="$FAKE_HOME" bash "$FAKE_REPO/common/devcontainer/install-skills.sh" 2>&1); then
  ok "the extracted block ran clean"
else
  notok "the extracted block failed" "$out"
fi

for name in "$NEW_SKILL" "$CONTROL_SKILL"; do
  if [ "$name" = "$CONTROL_SKILL" ]; then
    CASE="the installer links $name (control)"
  else
    CASE="the installer links $name"
  fi
  link="$FAKE_REPO/.claude/skills/$name"
  want="../../common/skills/$name"
  if [ ! -L "$link" ]; then
    notok "no project-level symlink at .claude/skills/$name" \
          "$(ls -a "$FAKE_REPO/.claude/skills" 2>/dev/null | tr '\n' ' ')"
  elif [ "$(readlink "$link")" != "$want" ]; then
    # An absolute target is the dangling-link defect the comment in
    # setup-claude.sh exists for: ~/.claude is shared across containers.
    notok "link target is not the relative in-workspace path $want" "$(readlink "$link")"
  elif [ ! -f "$link/SKILL.md" ]; then
    notok "the link resolves to no SKILL.md -- dangling"
  else
    ok "linked as $want and resolves to a SKILL.md"
  fi
done

# --- 2. the frontmatter parses ---------------------------------------------
#
# Deliberately not a YAML library: this must run on a bare ubuntu-latest with
# no pip step. What it enforces is the subset that can silently break -- fences
# present, `name:` agreeing with the DIRECTORY (the installer names the link
# after the directory, Claude Code reads `name:`, and a mismatch makes the
# skill unfindable by the name a session types), a non-empty description, and
# every line inside the fences being a top-level `key:` or a comment. That last
# one is the real catch: a description wrapped onto a second line is valid
# Markdown, invalid YAML, and invisible.

for skill in $SKILLS; do
  f="$REPO_ROOT/skills/$skill/SKILL.md"

  CASE="[$skill] SKILL.md exists"
  if [ -f "$f" ]; then
    ok "skills/$skill/SKILL.md is present"
  else
    notok "no skills/$skill/SKILL.md"
    continue
  fi

  CASE="[$skill] the frontmatter is fenced"
  if [ "$(head -1 "$f")" != "---" ]; then
    notok "the first line is not '---'" "$(head -1 "$f")"
    continue
  fi
  close=$(awk 'NR > 1 && $0 == "---" { print NR; exit }' "$f")
  if [ -z "$close" ]; then
    notok "no closing '---'"
    continue
  fi
  ok "opens on line 1 and closes on line $close"

  FM="$TMP/fm-$skill.yml"
  sed -n "2,$((close - 1))p" "$f" > "$FM"

  CASE="[$skill] every frontmatter line is a key or a comment"
  bad=""
  while IFS= read -r line; do
    case "$line" in
      "" | "#"*) continue ;;
      *) printf '%s\n' "$line" | grep -qE '^[a-z][a-z_-]*:[[:space:]]' || bad="$line" ;;
    esac
  done < "$FM"
  if [ -z "$bad" ]; then
    ok "no wrapped value or stray text inside the fences"
  else
    notok "a line inside the fences is neither 'key: value' nor a comment" "$bad"
  fi

  CASE="[$skill] name: matches the directory"
  fm_name=$(grep -m1 '^name:' "$FM" | sed -E 's/^name:[[:space:]]*//; s/[[:space:]]*$//')
  if [ "$fm_name" = "$skill" ]; then
    ok "name: $fm_name"
  else
    notok "name: disagrees with the directory skills/$skill" "name: ${fm_name:-<absent>}"
  fi

  CASE="[$skill] description: is present and says when to use it"
  fm_desc=$(grep -m1 '^description:' "$FM" | sed -E 's/^description:[[:space:]]*//')
  if [ -z "$fm_desc" ]; then
    notok "no description: -- the only thing a session matches on to pick the skill"
  elif [ "${#fm_desc}" -lt 40 ]; then
    notok "description: is too short to match a request against" "$fm_desc"
  else
    ok "${#fm_desc} characters"
  fi
done

# --- 3. every dev-common path the skill names exists ----------------------
#
# Extracts backticked tokens and keeps the ones that are dev-common-relative:
# either prefixed `common/` (how a CONSUMER repo sees this repo, which is how
# the skills write it) or starting with one of this repo's own top-level dirs.
# Everything else is out of scope by construction -- `stack-common/CLAUDE.md`,
# `dags/`, `schema/*.sql` and the like live in other repos, and asserting on
# them here would be asserting on a checkout this suite does not have.
# Tokens holding a `<placeholder>` are skipped.

dev_common_paths() { # SKILL.md
  grep -oE '`[^`]+`' "$1" \
    | tr -d '`' \
    | tr ' ' '\n' \
    | grep -E '/' \
    | grep -v '<' \
    | sed -E 's/[.,;:)]+$//' \
    | sort -u \
    | while IFS= read -r tok; do
        case "$tok" in
          common/*) printf '%s\n' "${tok#common/}" ;;
          docs/* | skills/* | make/* | devcontainer/* | tests/* | github/* | vault/*)
            printf '%s\n' "$tok" ;;
        esac
      done | sort -u
}

for skill in $SKILLS; do
  f="$REPO_ROOT/skills/$skill/SKILL.md"
  [ -f "$f" ] || continue

  paths="$(dev_common_paths "$f")"

  CASE="[$skill] the extraction found paths to check"
  if [ -n "$paths" ]; then
    ok "$(printf '%s\n' "$paths" | wc -l | tr -d ' ') dev-common path(s) named"
  else
    # Not a failure in itself, but it means this case measured nothing -- and a
    # silently-empty check is the thing tests/verification-discipline warns of.
    notok "no dev-common paths extracted -- this case is measuring nothing"
  fi

  while IFS= read -r p; do
    [ -n "$p" ] || continue
    CASE="[$skill] names an existing path"
    case "$p" in
      *[*?]*)
        # A glob (make/*.mk): at least one match must exist.
        if compgen -G "$REPO_ROOT/$p" >/dev/null; then
          ok "$p matches at least one file"
        else
          notok "the glob $p matches nothing in dev-common"
        fi ;;
      *)
        if [ -e "$REPO_ROOT/$p" ]; then
          ok "$p"
        else
          notok "skills/$skill/SKILL.md sends a session to $p, which is not in dev-common"
        fi ;;
    esac
  done <<< "$paths"
done

# --- 4. incorporate-stack-repo stays stack-neutral ------------------------
#
# Two rules from bdh-org/dev-common#326, and the reason for both is that
# dev-common is PUBLIC and feeds more than one stack: the skill must link the
# pattern definitions rather than copy them (a copy drifts from the original
# and there is nothing to notice), and it must carry no host name and no repo
# list (both are stack facts, and one of them is infrastructure detail that
# should not be public). The names below are the concrete leak risk -- the
# hosts and member repos a session working on this file would know offhand.
# `brianholland` is deliberately NOT here: the handoff rules in CLAUDE.md
# require that login by name.

SKILL_FILE="$REPO_ROOT/skills/incorporate-stack-repo/SKILL.md"
if [ -f "$SKILL_FILE" ]; then
  CASE="[incorporate-stack-repo] links the pattern definitions"
  if grep -q 'docs/stack-patterns.md' "$SKILL_FILE"; then
    ok "points at docs/stack-patterns.md instead of restating P1-P14"
  else
    notok "no link to docs/stack-patterns.md -- the definitions are being carried twice"
  fi

  CASE="[incorporate-stack-repo] names no host and no member repo"
  leaked=""
  for word in twix minerva forge home-infra home-site home-stack-common \
              fra-stack-common finriskanalytics finzeug hog oleo canary heller \
              panoptikon refdims ratecraft slingshot ledger-io; do
    grep -qiw -- "$word" "$SKILL_FILE" && leaked="$leaked $word"
  done
  if [ -z "$leaked" ]; then
    ok "stack-neutral: every concrete fact is read from stack-common/CLAUDE.md"
  else
    notok "the skill text names a host or member repo" "$leaked"
  fi
fi

printf '\npassed: %d   failed: %d\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
