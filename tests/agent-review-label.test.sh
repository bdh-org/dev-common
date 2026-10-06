#!/usr/bin/env bash
# agent-review-label.test.sh -- the agent's PR is put in front of the automated reviewer
# (bdh-org/home-infra#1188), and that step can never fail the run.
#
# Lifts the REAL python out of agent-issue-to-pr.yml's "Request the automated review" step
# and drives it against a local stub of the GitHub API (via GITHUB_API_URL).
#
# Usage:  bash tests/agent-review-label.test.sh      (or: make test)

set -uo pipefail   # deliberately NOT -e: every case runs, then we report

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WF="$REPO_ROOT/.github/workflows/agent-issue-to-pr.yml"

pass=0
fail=0
CASE="(none)"
ok()    { pass=$((pass + 1)); printf 'ok     - %s: %s\n' "$CASE" "$1"; }
notok() { fail=$((fail + 1)); printf 'NOT OK - %s: %s\n' "$CASE" "$1"; }

TMP="$(mktemp -d)"
PID=""
trap '[ -n "$PID" ] && kill "$PID" 2>/dev/null; rm -rf "$TMP"' EXIT

# The python heredoc of the step named "Request the automated review ...".
python3 - "$WF" "$TMP/step.py" <<'PY'
import sys, textwrap
lines = open(sys.argv[1]).read().splitlines()
i = next(i for i, l in enumerate(lines) if "name: Request the automated review" in l)
j = next(k for k in range(i, len(lines)) if lines[k].strip().startswith("python3 - <<'PY'"))
body = []
for l in lines[j + 1:]:
    if l.strip() == "PY":
        break
    body.append(l)
open(sys.argv[2], "w").write(textwrap.dedent("\n".join(body)) + "\n")
PY
[ -s "$TMP/step.py" ] || { echo "NOT OK - could not lift the step from $WF"; exit 1; }

cat > "$TMP/stub.py" <<'PY'
"""GET pulls -> $PULLS (json); POST labels -> journalled, answered $LABEL_CODE."""
import json, os
from http.server import BaseHTTPRequestHandler, HTTPServer

class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def _send(self, code, obj):
        b = json.dumps(obj).encode()
        self.send_response(code); self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(b))); self.end_headers(); self.wfile.write(b)
    def do_GET(self):
        if "/pulls?" in self.path:
            return self._send(int(os.environ.get("PULLS_CODE", "200")),
                              json.loads(open(os.environ["PULLS"]).read()))
        return self._send(404, {})
    def do_POST(self):
        n = int(self.headers.get("Content-Length", 0))
        with open(os.environ["JOURNAL"], "a") as fh:
            fh.write(self.path + " " + self.rfile.read(n).decode() + "\n")
        code = int(os.environ.get("LABEL_CODE", "200"))
        return self._send(code, [{"name": "agent-review"}] if code == 200 else {"message": "no"})

srv = HTTPServer(("127.0.0.1", 0), H)
open(os.environ["PORTFILE"], "w").write(str(srv.server_address[1]))
srv.serve_forever()
PY

start() {  # <pulls-json> [label http code] [pulls http code]
  [ -n "$PID" ] && { kill "$PID" 2>/dev/null; wait "$PID" 2>/dev/null; }
  printf '%s' "$1" > "$TMP/pulls.json"; : > "$TMP/journal"; rm -f "$TMP/port"
  PULLS="$TMP/pulls.json" JOURNAL="$TMP/journal" PORTFILE="$TMP/port" \
    LABEL_CODE="${2:-200}" PULLS_CODE="${3:-200}" python3 "$TMP/stub.py" & PID=$!
  for _ in $(seq 1 100); do [ -s "$TMP/port" ] && break; sleep 0.05; done
}
run() {
  OUT="$(GITHUB_API_URL="http://127.0.0.1:$(cat "$TMP/port")" GH_TOKEN=stub \
         REPO=o/r OWNER=o BRANCH=agent/issue-7 python3 "$TMP/step.py" 2>&1)"; RC=$?
}

CASE="an open, ready agent PR"
start '[{"number":12,"draft":false,"labels":[]}]'; run
grep -q '/repos/o/r/issues/12/labels {"labels": \["agent-review"\]}' "$TMP/journal" \
  && ok "is labelled agent-review" || notok "labelled (journal: $(cat "$TMP/journal"))"
[ "$RC" = 0 ] && ok "exit 0" || notok "exit 0 (rc=$RC)"

CASE="a draft PR"
start '[{"number":13,"draft":true,"labels":[]}]'; run
[ ! -s "$TMP/journal" ] && ok "is not labelled (the agent says it is still red)" || notok "draft not labelled"

CASE="already labelled"
start '[{"number":14,"draft":false,"labels":[{"name":"agent-review"}]}]'; run
[ ! -s "$TMP/journal" ] && ok "is left alone (no duplicate review)" || notok "no relabel"

CASE="no PR"
start '[]'; run
[ ! -s "$TMP/journal" ] && [ "$RC" = 0 ] && ok "labels nothing and exits 0" || notok "no PR (rc=$RC)"

CASE="the label call fails"
start '[{"number":15,"draft":false,"labels":[]}]' 403; run
[ "$RC" = 0 ] && ok "never fails the run" || notok "never fails (rc=$RC)"
case "$OUT" in *"::warning::could not label PR #15"*) ok "and warns, naming the PR" ;; *) notok "warns ($OUT)" ;; esac

CASE="the PR lookup fails"
start '[]' 200 502; run
[ "$RC" = 0 ] && ok "never fails the run" || notok "lookup failure exit 0 (rc=$RC)"
case "$OUT" in *"::warning::could not look up the PR"*) ok "and warns" ;; *) notok "warns ($OUT)" ;; esac

echo
echo "agent-review-label: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
