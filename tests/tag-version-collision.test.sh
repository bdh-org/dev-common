#!/usr/bin/env bash
# tag-version-collision.test.sh -- the "Check if tag exists" step in BOTH tagging
# workflows: .github/workflows/tag-version.yml and tag-version-self-hosted.yml.
# bdh-org/home-infra#617.
#
# RUNS EVERY CASE AGAINST BOTH FILES, deliberately. The sibling suite
# version-bumped.test.sh used to hardcode ci.yml, and that is exactly how
# dev-common#182's fix reached one workflow and not the other while the suite stayed
# green for ten days -- every repo in the stack runs the file that was missed. Two
# copies of a step need one test that refuses to pick a favourite.
#
# WHY THESE CASES
#
# The step used to answer a yes/no question -- does this tag exist? -- and skip when
# the answer was yes. But "exists" covers two situations that need OPPOSITE responses:
#
#   same commit      -> benign. A re-run. Skipping is correct.
#   DIFFERENT commit -> this tree is on main under a version belonging to another
#                       tree. Ten commits across slingshot and panoptikon are
#                       permanently in that state, and nothing ever went red.
#
# So the load-bearing case is #3. The rest exist to stop the fix over-firing, which
# would be worse than the bug: a tagging step that fails on a re-run blocks releases.
#
# The cases run the REAL step body, extracted from each workflow, against throwaway
# git repos -- not a re-implementation, which would pass while the workflow shipped
# something else.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
WORKFLOWS="tag-version.yml tag-version-self-hosted.yml"
STEP_NAME="Check if tag exists"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass=0; fail=0
ok()    { echo "ok   - $CASE: $1"; pass=$((pass+1)); }
notok() { echo "NOT OK - $CASE: $1"; fail=$((fail+1)); }

export GIT_TERMINAL_PROMPT=0
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t

# The named step's `run: |` body, dedented out of the workflow. Same idiom as
# version-bumped.test.sh; a renamed step makes this empty and the first case red.
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

# repo_with <version> <where-the-tag-points: none|head|other|annotated|branch>
repo_with() {
  local ver="$1" where="$2" d="$(mktemp -d "$TMP/r-XXXXXX")"
  mkdir -p "$d" && cd "$d" || return 1
  git init -q -b main .
  echo one > f; git add f; git commit -qm first
  local first; first="$(git rev-parse HEAD)"
  echo two > f; git commit -qam second
  case "$where" in
    none)      : ;;
    head)      git tag "$ver" ;;
    other)     git tag "$ver" "$first" ;;
    annotated) git tag -a "$ver" -m "annotated" ;;
    branch)    git branch "$ver" "$first" ;;   # a BRANCH named like the version
  esac
  echo "$d"
}

run_step() { # dir version script
  ( cd "$1" && VERSION="$2" GITHUB_OUTPUT="$1/gh_out" bash "$3" 2>&1 )
}
outputs() { cat "$1/gh_out" 2>/dev/null | tr '\n' ' '; }

for WF_NAME in $WORKFLOWS; do
  WF="$HERE/../.github/workflows/$WF_NAME"
  SCRIPT="$TMP/step-$WF_NAME.sh"

  CASE="[$WF_NAME] the step is extractable"
  extract "$WF" "$STEP_NAME" > "$SCRIPT"
  # `${{ ... }}` is GitHub templating, not shell. Substitute it the way Actions would,
  # exactly as version-bumped.test.sh does for `github.base_ref`. Without this a step
  # that interpolates the version directly dies on "bad substitution" and every case
  # fails for a reason that has nothing to do with what is being tested -- which looks
  # like detection and is not.
  sed -i 's/\${{ steps\.version\.outputs\.version }}/\$VERSION/g' "$SCRIPT"
  if [ -s "$SCRIPT" ]; then ok "$WF_NAME carries a '$STEP_NAME' step with a body"
  else notok "$WF_NAME has no '$STEP_NAME' step -- renamed or removed"; continue; fi

  CASE="[$WF_NAME] no such tag"
  d=$(repo_with 1.2.3 none)
  if out=$(run_step "$d" 1.2.3 "$SCRIPT"); then
    case "$(outputs "$d")" in *exists=false*) ok "reports exists=false so the tag gets created" ;;
      *) notok "wrong output: $(outputs "$d")" ;; esac
  else notok "failed on a fresh version: $out"; fi

  CASE="[$WF_NAME] the tag already points at THIS commit"
  d=$(repo_with 1.2.3 head)
  if out=$(run_step "$d" 1.2.3 "$SCRIPT"); then
    case "$(outputs "$d")" in *exists=true*) ok "benign re-run skips instead of failing a release" ;;
      *) notok "wrong output: $(outputs "$d")" ;; esac
  else notok "a re-run on an already-correct tag FAILED -- this would block releases: $out"; fi

  CASE="[$WF_NAME] the tag points at a DIFFERENT commit"
  d=$(repo_with 1.2.3 other)
  if out=$(run_step "$d" 1.2.3 "$SCRIPT"); then
    notok "THE BUG: a version tagged on another commit was accepted silently"
  else
    case "$out" in
      *"VERSION COLLISION"*) ok "fails loudly -- this is the whole point of the change" ;;
      *) notok "failed, but not with the collision message: $out" ;;
    esac
    case "$out" in
      *"Do NOT move the existing tag"*) ok "names the remedy AND the anti-remedy" ;;
      *) notok "no guidance on what to do: $out" ;;
    esac
  fi

  CASE="[$WF_NAME] an ANNOTATED tag on this commit"
  # `git rev-parse <tag>` yields the TAG OBJECT for an annotated tag, which never equals
  # HEAD -- so a rev-parse comparison would call every annotated re-run a collision.
  d=$(repo_with 1.2.3 annotated)
  if out=$(run_step "$d" 1.2.3 "$SCRIPT"); then
    case "$(outputs "$d")" in *exists=true*) ok "dereferenced to its commit, not treated as a collision" ;;
      *) notok "wrong output: $(outputs "$d")" ;; esac
  else notok "an annotated tag on HEAD was reported as a collision: $out"; fi

  CASE="[$WF_NAME] a BRANCH named like the version"
  # A bare `git rev-parse 1.2.3` happily resolves a branch. Then a repo with a release
  # branch per version would look permanently collided.
  d=$(repo_with 1.2.3 branch)
  if out=$(run_step "$d" 1.2.3 "$SCRIPT"); then
    case "$(outputs "$d")" in *exists=false*) ok "only refs/tags/ counts, so a like-named branch is not a tag" ;;
      *) notok "a branch satisfied the tag lookup: $(outputs "$d")" ;; esac
  else notok "a like-named branch was reported as a collision: $out"; fi
done

echo
echo "passed: $pass   failed: $fail"
[ "$fail" -eq 0 ]
