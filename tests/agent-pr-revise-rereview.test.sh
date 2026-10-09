#!/usr/bin/env bash
# agent-pr-revise-rereview.test.sh -- a revision the automated reviewer asked for is put
# back in front of it (bdh-org/home-infra#1256), and that step can never fail the run.
#
# Lifts the REAL python out of agent-pr-revise.yml's "Ask for the re-review" step and
# drives it against a local stub of the GitHub API (via GITHUB_API_URL). The label is
# removed and re-added, because a label already present fires no `labeled` event.
#
# Usage:  bash tests/agent-pr-revise-rereview.test.sh      (or: make test)
set -uo pipefail   # deliberately NOT -e: every case runs, then we report

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WF="$REPO_ROOT/.github/workflows/agent-pr-revise.yml"

pass=0
fail=0
CASE="(none)"
ok()    { pass=$((pass + 1)); printf 'ok     - %s: %s\n' "$CASE" "$1"; }
notok() { fail=$((fail + 1)); printf 'NOT OK - %s: %s\n' "$CASE" "$1"; }

TMP="$(mktemp -d)"
PID=""
trap '[ -n "$PID" ] && kill "$PID" 2>/dev/null; rm -rf "$TMP"' EXIT

# The python heredoc of the step named "Ask for the re-review ...".
python3 - "$WF" "$TMP/step.py" <<'PY'
import sys, textwrap
lines = open(sys.argv[1]).read().splitlines()
i = next(i for i, l in enumerate(lines) if "name: Ask for the re-review" in l)
j = next(k for k in range(i, len(lines)) if lines[k].strip().startswith("python3 - <<'PY'"))
body = []
for l in lines[j + 1:]:
    if l.strip() == "PY":
        break
    body.append(l)
open(sys.argv[2], "w").write(textwrap.dedent("\n".join(body)) + "\n")
PY
[ -s "$TMP/step.py" ] || { echo "NOT OK - could not lift the step from $WF"; exit 1; }

CASE="the step only runs for the reviewer's own hand-back"
grep -q "github.event.comment.user.id == inputs.reviewer_user_id" "$WF" \
  && ok "gated on the /revise author being the reviewer" || notok "gate on the comment author"
grep -q "steps.verify.outcome == 'success'" "$WF" \
  && ok "and on the revision having pushed" || notok "gate on the push"
grep -q "name: Verify the revision pushed" "$WF" && grep -q "^        id: verify$" "$WF" \
  && ok "the verify step carries the id the gate reads" || notok "verify step id"

cat > "$TMP/stub.py" <<'PY'
"""DELETE/POST on labels -> journalled; answered $DELETE_CODE / $POST_CODE."""
import json, os
from http.server import BaseHTTPRequestHandler, HTTPServer

class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def _send(self, code, obj):
        b = json.dumps(obj).encode()
        self.send_response(code); self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(b))); self.end_headers(); self.wfile.write(b)
    def _journal(self):
        n = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(n).decode() if n else ""
        with open(os.environ["JOURNAL"], "a") as fh:
            fh.write(self.command + " " + self.path + " " + body + "\n")
    def do_DELETE(self):
        self._journal()
        code = int(os.environ.get("DELETE_CODE", "200"))
        return self._send(code, [] if code == 200 else {"message": "no"})
    def do_POST(self):
        self._journal()
        code = int(os.environ.get("POST_CODE", "200"))
        return self._send(code, [{"name": "agent-review"}] if code == 200 else {"message": "no"})

srv = HTTPServer(("127.0.0.1", 0), H)
open(os.environ["PORTFILE"], "w").write(str(srv.server_address[1]))
srv.serve_forever()
PY

start() {  # [delete http code] [post http code]
  [ -n "$PID" ] && { kill "$PID" 2>/dev/null; wait "$PID" 2>/dev/null; }
  : > "$TMP/journal"; rm -f "$TMP/port"
  JOURNAL="$TMP/journal" PORTFILE="$TMP/port" DELETE_CODE="${1:-200}" POST_CODE="${2:-200}" \
    python3 "$TMP/stub.py" & PID=$!
  for _ in $(seq 1 100); do [ -s "$TMP/port" ] && break; sleep 0.05; done
}
run() {
  OUT="$(GITHUB_API_URL="http://127.0.0.1:$(cat "$TMP/port")" GH_TOKEN=stub \
         REPO=o/r PR=7 python3 "$TMP/step.py" 2>&1)"; RC=$?
}

CASE="the label is present: removed, then re-added"
start; run
[ "$RC" = 0 ] && ok "exit 0" || notok "exit 0 (rc=$RC: $OUT)"
grep -q '^DELETE /repos/o/r/issues/7/labels/agent-review' "$TMP/journal" && ok "removed first" || notok "DELETE (journal: $(cat "$TMP/journal"))"
grep -q '^POST /repos/o/r/issues/7/labels {"labels": \["agent-review"\]}' "$TMP/journal" && ok "then added" || notok "POST (journal: $(cat "$TMP/journal"))"
[ "$(sed -n 1p "$TMP/journal" | cut -d' ' -f1)" = DELETE ] && ok "in that order" || notok "order"
case "$OUT" in *"asked for the re-review of PR #7"*) ok "says so" ;; *) notok "notice (got: $OUT)" ;; esac

CASE="the label was already gone (DELETE 404)"
start 404; run
[ "$RC" = 0 ] && ok "exit 0" || notok "exit 0 (rc=$RC)"
grep -q '^POST ' "$TMP/journal" && ok "still added" || notok "POST after 404"
case "$OUT" in *"could not remove"*) notok "a 404 is not worth a warning" ;; *) ok "no warning for the normal case" ;; esac

CASE="removing fails for another reason (DELETE 500)"
start 500; run
[ "$RC" = 0 ] && ok "exit 0" || notok "exit 0 (rc=$RC)"
grep -q '^POST ' "$TMP/journal" && ok "still tries to add" || notok "POST after 500"
case "$OUT" in *"could not remove agent-review"*"HTTP 500"*) ok "warns, naming the code" ;; *) notok "warning (got: $OUT)" ;; esac

CASE="adding fails (POST 403)"
start 200 403; run
[ "$RC" = 0 ] && ok "never fails the run" || notok "exit 0 (rc=$RC)"
case "$OUT" in *"could not re-label PR #7"*"HTTP 403"*"no re-review"*) ok "warns that there will be no re-review" ;; *) notok "warning (got: $OUT)" ;; esac

echo
echo "agent-pr-revise-rereview: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
