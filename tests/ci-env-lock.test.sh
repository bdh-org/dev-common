#!/usr/bin/env bash
# ci-env-lock.test.sh -- the "Set up conda env (cached on disk)" step of
# .github/workflows/self-hosted-ci.yml, over the two defects of
# bdh-org/dev-common#386.
#
# WHAT WENT WRONG
#
# One conda env per repo is shared by every run of that repo, and forge runs
# several runner units at once. On 2026-11-19 finzeug/hog's conda-packages.txt
# changed, so hog-ci rebuilt twice over:
#
#   main's run (key K-new) rebuilt it -- conda took fastapi 0.164 + starlette
#   1.10, pip overlaid the prod pins 0.129 + 0.52.1 -- tests passed, .envhash =
#   K-new. Concurrently a PR run still on the OLD conda-packages.txt (key K-old)
#   was rebuilding the SAME env and was cancelled by a force-push mid-install,
#   leaving fastapi 0.164's files beside starlette 0.52.1. Nothing touched
#   .envhash, so it still said K-new and every later run got a CACHE HIT on the
#   wreckage: 21 test modules failed to collect on `cannot import name
#   'body_limit' from 'starlette.middleware'`, identically on re-run
#   (finzeug/hog#1338, #1340).
#
# So there are two independent defects, and a test for either one alone passes
# while the incident still reproduces:
#
#   1. the build was not exclusive -- two runs mutated one env together;
#   2. a marker written by a SUCCESSFUL build outlived the env it described,
#      because the next rebuild invalidated the env without clearing it. The
#      two runs involved in that half never even overlap, so a lock cannot
#      see it.
#
# WHY THIS RUNS THE REAL STEP BODY
#
# Same reason template-initialised.test.sh and tag-version-collision.test.sh do:
# a re-implementation passes while the workflow ships something else. The body is
# extracted from the YAML and run for real against a throwaway CONDA_ROOT whose
# `conda` is a shell stub -- which also lets a run be killed in the middle of an
# install, the one thing the incident turns on and the one thing a real conda
# build cannot be asked to do on cue.
#
# Usage:  bash tests/ci-env-lock.test.sh      (or: make test)

set -uo pipefail   # deliberately NOT -e: every case runs, then we report

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WF="$HERE/../.github/workflows/self-hosted-ci.yml"
STEP_NAME="Set up conda env (cached on disk)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass=0; fail=0
CASE="(none)"
ok()    { echo "ok     - $CASE: $1"; pass=$((pass+1)); }
notok() { echo "NOT OK - $CASE: $1"; fail=$((fail+1)); }

# The named step's `run: |` body, dedented out of the workflow. Verbatim from
# template-initialised.test.sh; a renamed step makes this empty and the first
# case red rather than quietly dropping the step out of coverage.
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

# --- the step under test ---------------------------------------------------

SCRIPT="$TMP/step.sh"
CASE="the step is extractable"
extract "$WF" "$STEP_NAME" > "$SCRIPT"
if [ -s "$SCRIPT" ]; then
  ok "self-hosted-ci.yml carries a '$STEP_NAME' step with a body"
else
  notok "no '$STEP_NAME' step in self-hosted-ci.yml -- renamed or removed"
  echo "1..$((pass+fail))"; exit 1
fi

# `${{ ... }}` is GitHub templating, not shell -- substitute it the way Actions
# would, as tag-version-collision.test.sh does. Without this the body dies on
# "bad substitution" and every case below fails for a reason that has nothing to
# do with what is being tested, which looks like detection and is not.
sed -i 's/\${{ inputs\.full-env }}/\$FULL_ENV/g; s/\${{ inputs\.ci-env-file }}/\$CI_ENV_FILE/g' "$SCRIPT"

CASE="no untranslated templating is left in the body"
if leftover="$(grep -n '{{' "$SCRIPT")"; then
  notok "an expression this suite does not substitute reaches the shell: $leftover"
else
  ok "every \${{ }} in the step is one this suite knows how to stand in for"
fi

# --- the fake conda root ---------------------------------------------------

# A CONDA_ROOT whose conda.sh defines `conda` as a stub. It logs every call with
# the caller's tag (so interleaving is visible), creates/removes the env
# directory the way the real one does, and on its FIRST call records whether a
# marker was still present and then sleeps $BUILD_SLEEP -- which is how a run is
# caught in the middle of an install.
fresh_root() { # -> path
  local root; root="$(mktemp -d "$TMP/condaroot-XXXXXX")"
  mkdir -p "$root/etc/profile.d" "$root/envs"
  cat > "$root/etc/profile.d/conda.sh" <<'SH'
_conda_calls=0
conda() {
  local envdir="$CONDA_ROOT/envs/$CI_ENV"
  _conda_calls=$((_conda_calls + 1))
  printf '%s %s\n' "${BUILD_TAG:-run}" "$1" >> "$BUILD_LOG"
  if [ "$_conda_calls" = 1 ]; then
    if [ -e "$envdir/.envhash" ]; then
      echo present > "$MARKER_AT_BUILD_START"
    else
      echo absent > "$MARKER_AT_BUILD_START"
    fi
    sleep "${BUILD_SLEEP:-0}"
  fi
  case "$1" in
    create) mkdir -p "$envdir" ;;
    env)
      case "${2:-}" in
        update) mkdir -p "$envdir" ;;
        remove) rm -rf "$envdir" ;;
      esac
      ;;
  esac
  return 0
}
SH
  printf '%s\n' "$root"
}

# A repo whose conda-packages.txt decides the cache key.
make_repo() { # packages-content -> path
  local d; d="$(mktemp -d "$TMP/repo-XXXXXX")"
  printf '%s\n' "$1" > "$d/conda-packages.txt"
  printf '%s\n' "$d"
}

# Actions runs a `run:` block as `bash -e`, so the suite must too: the step
# relies on it to abort before the marker is written when a build fails.
run_step() { # repodir -> step output, step exit status
  ( cd "$1" && FULL_ENV=true CI_ENV_FILE=unused bash -e "$SCRIPT" 2>&1 )
}

# Backgrounded in its OWN SESSION, so the whole build -- the stub's `sleep`
# included, which inherits the lock fd exactly as conda would -- can be killed
# the way a cancelled job is. `exec setsid` keeps the pid: without job control a
# backgrounded subshell is not a process group leader, so setsid() does not have
# to fork, and $! is therefore the pgid to signal (verified before relying on it).
#
# The pid comes back in a GLOBAL rather than on stdout. Started inside a command
# substitution the job is a child of that subshell, not of this one, so `wait`
# refuses it and returns at once -- which read the call log while the first build
# was still sleeping and made the interleaving case pass against the unfixed
# workflow. The test that cannot fail is the whole thing this suite is for.
STEP_PID=""
start_step() { # repodir -- sets STEP_PID
  ( cd "$1" && exec setsid bash -e "$SCRIPT" >>"$OUTLOG" 2>&1 ) &
  STEP_PID=$!
}
kill_session() { # pid
  kill -9 -- "-$1" 2>/dev/null || kill -9 "$1" 2>/dev/null
  wait "$1" 2>/dev/null
  return 0
}

wait_for_tag() { # tag [tries of 0.1s]
  local i=0
  while [ "$i" -lt "${2:-100}" ]; do
    grep -q "^$1 " "$BUILD_LOG" 2>/dev/null && return 0
    sleep 0.1; i=$((i+1))
  done
  return 1
}

calls()  { wc -l < "$BUILD_LOG" | tr -d ' '; }
# Consecutive duplicates collapsed: "A B" means every A call preceded every B
# call, "A B A" means the two builds interleaved.
tag_order() { awk '{print $1}' "$BUILD_LOG" | uniq | tr '\n' ' ' | sed 's/ *$//'; }

export CI_ENV=test-ci
export FULL_ENV=true CI_ENV_FILE=unused
export ENV_LOCK_WAIT_SECONDS=30

# --- the cache itself still works -----------------------------------------

CONDA_ROOT="$(fresh_root)"; export CONDA_ROOT
export BUILD_LOG="$TMP/build.log"; : > "$BUILD_LOG"
export MARKER_AT_BUILD_START="$TMP/marker-state"; : > "$MARKER_AT_BUILD_START"
export BUILD_SLEEP=0
repo="$(make_repo "pandas numpy")"

CASE="a fresh env"
out="$(run_step "$repo")"; rc=$?
if [ "$rc" -eq 0 ] && [ "$(calls)" -gt 0 ]; then
  ok "is built ($(calls) conda calls)"
else
  notok "was not built: rc=$rc, $(calls) conda calls -- $out"
fi
if [ -s "$CONDA_ROOT/envs/$CI_ENV/.envhash" ]; then
  ok "and the marker is written once it is complete"
else
  notok "no .envhash after a successful build, so nothing will ever cache-hit"
fi

CASE="an unchanged key"
: > "$BUILD_LOG"
out="$(run_step "$repo")"; rc=$?
if [ "$rc" -eq 0 ] && [ "$(calls)" -eq 0 ]; then
  ok "is a cache hit -- no conda call at all"
else
  notok "rebuilt on an unchanged key ($(calls) conda calls, rc=$rc): $out"
fi

# --- defect 2: the marker must not outlive the env it describes ------------

CASE="entering a rebuild"
: > "$BUILD_LOG"; : > "$MARKER_AT_BUILD_START"
printf 'pandas numpy fastapi\n' > "$repo/conda-packages.txt"
out="$(run_step "$repo")"; rc=$?
state="$(cat "$MARKER_AT_BUILD_START" 2>/dev/null)"
if [ "$state" = absent ]; then
  ok "clears .envhash BEFORE the first install, so a build in flight cannot be cache-hit"
else
  notok "THE BUG: the marker was still '$state' while the env was being rebuilt"
fi
if [ "$rc" -eq 0 ] && [ -s "$CONDA_ROOT/envs/$CI_ENV/.envhash" ]; then
  ok "and writes it again when the build returns"
else
  notok "no marker after the rebuild: rc=$rc -- $out"
fi

CASE="a rebuild killed mid-install (the cancelled run)"
CONDA_ROOT="$(fresh_root)"; export CONDA_ROOT
: > "$BUILD_LOG"; : > "$MARKER_AT_BUILD_START"
OUTLOG="$TMP/killed.out"; : > "$OUTLOG"
repo="$(make_repo "K-old")"
export BUILD_SLEEP=0 BUILD_TAG=first
run_step "$repo" >/dev/null
k_old="$(cat "$CONDA_ROOT/envs/$CI_ENV/.envhash" 2>/dev/null)"
# Now the other run: a DIFFERENT key, cancelled partway through its install.
printf 'K-new\n' > "$repo/conda-packages.txt"
: > "$BUILD_LOG"
export BUILD_SLEEP=30 BUILD_TAG=killed
start_step "$repo"; pid="$STEP_PID"
if wait_for_tag killed; then
  kill_session "$pid"
  if [ -e "$CONDA_ROOT/envs/$CI_ENV/.envhash" ]; then
    notok "THE BUG: .envhash survived a cancelled rebuild, still reading $(cat "$CONDA_ROOT/envs/$CI_ENV/.envhash")"
  else
    ok "leaves no marker at all"
  fi
  # The incident exactly: the next run carries the key the dead marker held, so
  # a surviving marker would match it and the corrupt env would be reused.
  export BUILD_SLEEP=0 BUILD_TAG=next
  printf 'K-old\n' > "$repo/conda-packages.txt"
  : > "$BUILD_LOG"
  export ENV_LOCK_WAIT_SECONDS=15
  out="$(run_step "$repo")"; rc=$?
  if [ "$rc" -ne 0 ]; then
    notok "the next run failed instead of rebuilding: $out"
  elif [ "$(calls)" -gt 0 ]; then
    ok "and the next run on that same key REBUILDS rather than cache-hitting the wreckage"
  else
    notok "THE BUG: the next run cache-hit an env a cancelled build had half-rewritten (key $k_old): $out"
  fi
else
  notok "the killed run never reached an install -- the stub or the extraction is wrong"
  kill_session "$pid"
fi

# --- defect 1: two rebuilds must not interleave ----------------------------

CASE="two runs rebuilding the same env on different keys"
CONDA_ROOT="$(fresh_root)"; export CONDA_ROOT
: > "$BUILD_LOG"; : > "$MARKER_AT_BUILD_START"
OUTLOG="$TMP/concurrent.out"; : > "$OUTLOG"
repo_a="$(make_repo "key-A")"
repo_b="$(make_repo "key-B")"
# A sleeps through its first install; B starts inside that sleep and would run
# to completion within it if nothing held it back. So an interleave here is
# deterministic rather than a race the suite hopes to catch.
export BUILD_TAG=A BUILD_SLEEP=3
start_step "$repo_a"; pid_a="$STEP_PID"
if wait_for_tag A; then
  export BUILD_TAG=B BUILD_SLEEP=0 ENV_LOCK_WAIT_SECONDS=30
  run_step "$repo_b" >>"$OUTLOG" 2>&1
  rc=$?
  # A's REMAINING calls must land before the order is judged: read the log while
  # A is still sleeping and an interleave looks like clean serialization.
  wait "$pid_a" 2>/dev/null
  order="$(tag_order)"
  if [ "$order" = "A B" ]; then
    ok "are serialized -- every A call precedes every B call"
  else
    notok "THE BUG: the two builds interleaved into one env (call order: $order)"
  fi
  if [ "$rc" -eq 0 ]; then
    ok "and the second run still rebuilds for its own key once the first is done"
  else
    notok "the second run failed rather than waiting: $(cat "$OUTLOG")"
  fi
else
  notok "the first run never reached an install -- the stub or the extraction is wrong"
  kill_session "$pid_a"
fi

CASE="another repo's env"
CONDA_ROOT="$(fresh_root)"; export CONDA_ROOT
: > "$BUILD_LOG"; : > "$MARKER_AT_BUILD_START"
OUTLOG="$TMP/perenv.out"; : > "$OUTLOG"
repo="$(make_repo "whatever")"
export CI_ENV=env-one BUILD_TAG=one BUILD_SLEEP=3
start_step "$repo"; pid="$STEP_PID"
if wait_for_tag one; then
  # A wait far shorter than the holder's remaining build: this can only pass if
  # the lock is per env. One global lock would queue the whole fleet behind
  # whichever repo is solving.
  export CI_ENV=env-two BUILD_TAG=two BUILD_SLEEP=0 ENV_LOCK_WAIT_SECONDS=1
  run_step "$repo" >>"$OUTLOG" 2>&1
  rc=$?
  if [ "$rc" -eq 0 ]; then
    ok "is not queued behind this one -- the lock is per env, not global"
  else
    notok "a second env waited on the first repo's lock: $(cat "$OUTLOG")"
  fi
  kill_session "$pid"
else
  notok "the holder never reached an install -- the stub or the extraction is wrong"
  kill_session "$pid"
fi

CASE="giving up on the lock"
CONDA_ROOT="$(fresh_root)"; export CONDA_ROOT
: > "$BUILD_LOG"; : > "$MARKER_AT_BUILD_START"
OUTLOG="$TMP/timeout.out"; : > "$OUTLOG"
repo="$(make_repo "whatever")"
export CI_ENV=test-ci BUILD_TAG=holder BUILD_SLEEP=20
start_step "$repo"; pid="$STEP_PID"
if wait_for_tag holder; then
  export BUILD_TAG=waiter BUILD_SLEEP=0 ENV_LOCK_WAIT_SECONDS=1
  out="$(run_step "$repo")"; rc=$?
  if [ "$rc" -ne 0 ]; then
    ok "fails the job rather than mutating an env another run is building"
  else
    notok "THE BUG: a run that could not take the lock built anyway: $out"
  fi
  case "$out" in
    *"::error::"*"conda env lock"*) ok "and says which env it waited for, as an annotation" ;;
    *) notok "the message does not name the lock: $out" ;;
  esac
  if ! grep -q '^waiter ' "$BUILD_LOG"; then
    ok "and touched nothing on its way out"
  else
    notok "the waiter ran conda calls despite not holding the lock"
  fi
  kill_session "$pid"
else
  notok "the holder never reached an install -- the stub or the extraction is wrong"
  kill_session "$pid"
fi

echo
echo "1..$((pass+fail))   # $pass passed, $fail failed"
[ "$fail" -eq 0 ]
