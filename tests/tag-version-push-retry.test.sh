#!/usr/bin/env bash
# tag-version-push-retry.test.sh -- the "Create and push tag" step in EVERY copy of the
# tagging workflow retries a push GitHub answered with a transient error, and nothing
# else (bdh-org/dev-common#375).
#
# Two tags went missing for five days because GitHub answered the push with
# `remote: Internal Server Error` once and nothing re-runs the job. The cases run the
# REAL step body, extracted from each workflow (same idiom as
# tag-version-collision.test.sh), against a stub `git` whose push fails a scripted
# number of times. `sleep` is stubbed, so the backoff costs nothing here.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
WORKFLOWS=".github/workflows/tag-version.yml .github/workflows/tag-version-self-hosted.yml github/workflows/tag-version.yml"
STEP_NAME="Create and push tag"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass=0; fail=0
ok()    { echo "ok   - $CASE: $1"; pass=$((pass+1)); }
notok() { echo "NOT OK - $CASE: $1"; fail=$((fail+1)); }

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

# Stub bin: `git push` fails the first $FAILS times with $MSG, then succeeds;
# every other git subcommand succeeds. Each push appends a line to $PUSHES.
mkdir -p "$TMP/bin"
cat >"$TMP/bin/git" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  rev-parse) echo 0123456789abcdef ;;
  push)
    echo push >>"$PUSHES"
    n=$(wc -l <"$PUSHES")
    if [ "$n" -le "$FAILS" ]; then echo "$MSG" >&2; exit 1; fi
    echo "To github.com:o/r.git"; echo " * [new tag]  1.2.3 -> 1.2.3" ;;
esac
exit 0
EOF
printf '#!/usr/bin/env bash\necho "$1" >>"$SLEEPS"\n' >"$TMP/bin/sleep"
chmod +x "$TMP/bin/git" "$TMP/bin/sleep"

# run_case <workflow> <fails> <message>; sets RC, NPUSH, SLEPT
run_case() {
  local body d
  body="$(extract "$ROOT/$1" "$STEP_NAME")"
  d="$(mktemp -d "$TMP/c-XXXXXX")"; : >"$d/sleeps"
  ( cd "$d" && PATH="$TMP/bin:$PATH" VERSION=1.2.3 FAILS="$2" MSG="$3" \
      PUSHES="$d/pushes" SLEEPS="$d/sleeps" GITHUB_STEP_SUMMARY="$d/summary" \
      GITHUB_REPOSITORY=o/r GITHUB_REPOSITORY_OWNER=o \
      bash -e -c "$body" >"$d/out" 2>&1 )
  RC=$?
  NPUSH=$(cat "$d/pushes" 2>/dev/null | wc -l)
  SLEPT=$(tr '\n' ' ' <"$d/sleeps" 2>/dev/null | sed 's/ $//')
  OUT="$d/out"
}

ISE='remote: Internal Server Error
 ! [remote rejected] 1.2.3 -> 1.2.3 (Internal Server Error)'

for wf in $WORKFLOWS; do
  if [ -z "$(extract "$ROOT/$wf" "$STEP_NAME")" ]; then
    CASE="$wf"; notok "step '$STEP_NAME' not found"; continue
  fi

  CASE="$wf: clean push"
  run_case "$wf" 0 ""
  [ "$RC" = 0 ] && [ "$NPUSH" = 1 ] && [ -z "$SLEPT" ] \
    && ok "one push, no sleep" || notok "rc=$RC pushes=$NPUSH sleeps='$SLEPT'"

  CASE="$wf: one 500, then success"
  run_case "$wf" 1 "$ISE"
  [ "$RC" = 0 ] && [ "$NPUSH" = 2 ] && [ "$SLEPT" = 5 ] \
    && ok "retried once after 5s" || notok "rc=$RC pushes=$NPUSH sleeps='$SLEPT'"

  CASE="$wf: 502 then 503 then reset, then success"
  run_case "$wf" 3 "fatal: unable to access: The requested URL returned error: 502"
  [ "$RC" = 0 ] && [ "$NPUSH" = 4 ] && [ "$SLEPT" = "5 15 45" ] \
    && ok "three retries at 5/15/45s" || notok "rc=$RC pushes=$NPUSH sleeps='$SLEPT'"

  CASE="$wf: connection reset"
  run_case "$wf" 1 "error: RPC failed; curl 56 Recv failure: Connection reset by peer"
  [ "$RC" = 0 ] && [ "$NPUSH" = 2 ] \
    && ok "retried" || notok "rc=$RC pushes=$NPUSH sleeps='$SLEPT'"

  CASE="$wf: 500 that never clears"
  run_case "$wf" 99 "$ISE"
  [ "$RC" != 0 ] && [ "$NPUSH" = 4 ] && [ "$SLEPT" = "5 15 45" ] \
    && ok "gave up after 4 pushes, red" || notok "rc=$RC pushes=$NPUSH sleeps='$SLEPT'"

  CASE="$wf: workflow-file rule is not retried"
  run_case "$wf" 99 " ! [remote rejected] 1.2.3 -> 1.2.3 (refusing to allow a GitHub App to create or update workflow \`.github/workflows/x.yml\` without \`workflows\` permission)"
  if [ "$RC" != 0 ] && [ "$NPUSH" = 1 ] && [ -z "$SLEPT" ] \
     && grep -q 'gh-app-token' "$OUT" && ! grep -q 'PAT' "$OUT"; then
    ok "one push, red, App-token recipe"
  else
    notok "rc=$RC pushes=$NPUSH sleeps='$SLEPT'"
  fi

  CASE="$wf: an ordinary rejection is not retried"
  run_case "$wf" 99 " ! [rejected] 1.2.3 -> 1.2.3 (already exists)"
  [ "$RC" != 0 ] && [ "$NPUSH" = 1 ] && [ -z "$SLEPT" ] \
    && ok "one push, red" || notok "rc=$RC pushes=$NPUSH sleeps='$SLEPT'"
done

echo
echo "tag-version-push-retry: $pass passed, $fail failed"
[ "$fail" = 0 ]
