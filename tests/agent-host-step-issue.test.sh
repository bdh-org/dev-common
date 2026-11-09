#!/usr/bin/env bash
# agent-host-step-issue.test.sh -- a host step the agent writes becomes its own BRIAN:
# issue, assigned to Brian, blocking the trigger issue, and pointed at from the PR body
# (bdh-org/dev-common#373).
#
# finzeug/refdims#429 put Brian's `make prod-migrate` at the top of a PR body and assigned
# the PR to him, because nothing but the prompt asked for a BRIAN: issue. The workflow now
# files it. This drives the REAL python lifted out of the "File the host step" step against
# a stub GitHub API (GITHUB_API_URL), so the test cannot pass while the workflow diverges,
# and pins that the agent step and the filing step name the same file.
#
# Usage:  bash tests/agent-host-step-issue.test.sh      (or: make test)

set -uo pipefail   # deliberately NOT -e: every case runs, then we report

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WF="$REPO_ROOT/.github/workflows/agent-issue-to-pr.yml"

pass=0
fail=0
CASE="(none)"
ok()    { pass=$((pass + 1)); printf 'ok     - %s: %s\n' "$CASE" "$1"; }
notok() { fail=$((fail + 1)); printf 'NOT OK - %s: %s\n' "$CASE" "$1"; }

TMP="$(mktemp -d)"
STUB_PID=""
trap '[ -n "$STUB_PID" ] && kill "$STUB_PID" 2>/dev/null; rm -rf "$TMP"' EXIT

# ---- wiring: both steps name the same file, and the prompt tells the agent about it
CASE="wiring"
agent_val="$(awk '/^      - uses: anthropics\/claude-code-action/{a=1} a && /^          AGENT_HOST_STEP_FILE:/{sub(/^ *AGENT_HOST_STEP_FILE: */,""); print; exit}' "$WF")"
file_val="$(awk '/^      - name: File the host step/{a=1} a && /^          AGENT_HOST_STEP_FILE:/{sub(/^ *AGENT_HOST_STEP_FILE: */,""); print; exit}' "$WF")"
[ -n "$agent_val" ] && ok "the agent step names AGENT_HOST_STEP_FILE" || notok "the agent step names AGENT_HOST_STEP_FILE"
[ -n "$agent_val" ] && [ "$agent_val" = "$file_val" ] && ok "the filing step names the SAME file" \
  || notok "same file (agent='$agent_val' filing='$file_val')"
case "$agent_val" in *runner.temp*) ok "outside the checkout" ;; *) notok "outside the checkout ($agent_val)" ;; esac
grep -q "file named by the env var AGENT_HOST_STEP_FILE" "$WF" && ok "the prompt tells the agent to write it" \
  || notok "the prompt mentions AGENT_HOST_STEP_FILE"
grep -q "never assign" "$WF" && ok "the prompt forbids assigning the PR to him" || notok "never assign the PR"

# ---- lift the step's python
python3 - "$WF" "$TMP/file.py" <<'PY'
import sys, textwrap
lines = open(sys.argv[1]).read().splitlines()
i = next(i for i, l in enumerate(lines) if l.strip() == "- name: File the host step as a BRIAN issue")
start = next(j for j in range(i, len(lines)) if lines[j].strip() == "python3 - <<'PY'")
body = []
for l in lines[start + 1:]:
    if l.strip() == "PY":
        break
    body.append(l)
open(sys.argv[2], "w").write(textwrap.dedent("\n".join(body)) + "\n")
PY
[ -s "$TMP/file.py" ] || { echo "NOT OK - could not lift the step's python from $WF"; exit 1; }

# ---- a stub GitHub API that records every write
cat > "$TMP/stub.py" <<'PY'
import json, sys
from http.server import BaseHTTPRequestHandler, HTTPServer

state_path, port_path = sys.argv[1], sys.argv[2]

def load():
    return json.load(open(state_path))

def save(s):
    json.dump(s, open(state_path, "w"))

class H(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def reply(self, code, obj):
        data = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        s = load()
        p = self.path.split("/repos/o/r/", 1)[1]
        if p.startswith("issues?"):
            return self.reply(200, s["issues"] if "page=1" in p else [])
        if p.startswith("pulls?"):
            return self.reply(200, s["pulls"])
        self.reply(404, {})

    def body(self):
        return json.loads(self.rfile.read(int(self.headers["Content-Length"])))

    def do_POST(self):
        s = load()
        p = self.path.split("/repos/o/r/", 1)[1]
        payload = self.body()
        s["writes"].append(["POST", p, payload])
        if p == "issues":
            n = 900 + len(s["issues"])
            issue = {"number": n, "id": 9000 + n, "title": payload["title"],
                     "html_url": f"https://github.com/o/r/issues/{n}"}
            s["issues"].append(issue)
            save(s)
            return self.reply(201, issue)
        if p.endswith("/dependencies/blocked_by"):
            if payload["issue_id"] in s["links"]:
                save(s)
                return self.reply(422, {"message": "already exists"})
            s["links"].append(payload["issue_id"])
            save(s)
            return self.reply(201, {})
        save(s)
        self.reply(404, {})

    def do_PATCH(self):
        s = load()
        p = self.path.split("/repos/o/r/", 1)[1]
        payload = self.body()
        s["writes"].append(["PATCH", p, payload])
        for pr in s["pulls"]:
            if p == f"pulls/{pr['number']}":
                pr["body"] = payload["body"]
        save(s)
        self.reply(200, {})

srv = HTTPServer(("127.0.0.1", 0), H)
open(port_path, "w").write(str(srv.server_port))
srv.serve_forever()
PY

reset_state() {
  cat > "$TMP/state.json" <<'JSON'
{"issues": [{"number": 5, "id": 9005, "title": "unrelated", "html_url": "https://github.com/o/r/issues/5"}],
 "pulls": [{"number": 7, "body": "Does the thing.\n\nCloses #42"}],
 "links": [], "writes": []}
JSON
}
reset_state
python3 "$TMP/stub.py" "$TMP/state.json" "$TMP/port" & STUB_PID=$!
for _ in $(seq 50); do [ -s "$TMP/port" ] && break; sleep 0.1; done
PORT="$(cat "$TMP/port")"

run_step() {
  GH_TOKEN=x REPO=o/r OWNER=o BRANCH=agent/issue-42 ISSUE=42 RUN_URL=https://run \
    GITHUB_API_URL="http://127.0.0.1:$PORT" AGENT_HOST_STEP_FILE="$TMP/host-step.md" \
    GITHUB_STEP_SUMMARY="$TMP/summary.md" python3 "$TMP/file.py" > "$TMP/out" 2>&1
}
q() { python3 -c "import json,sys; s=json.load(open('$TMP/state.json')); print($1)"; }

# ---- no file: nothing is written
CASE="no host step"
rm -f "$TMP/host-step.md"
run_step && ok "exits 0" || notok "exits 0 ($(cat "$TMP/out"))"
[ "$(q 'len(s["writes"])')" = 0 ] && ok "writes nothing" || notok "writes nothing ($(q 's["writes"]'))"

# ---- a host step: filed, assigned, linked, pointed at
CASE="host step"
printf '# BRIAN: run the migration (1 command, RUN ON TWIX)\n\nOn twix, as brian:\n\n    make prod-migrate\n' > "$TMP/host-step.md"
run_step && ok "exits 0" || notok "exits 0 ($(cat "$TMP/out"))"
[ "$(q '[w[2]["title"] for w in s["writes"] if w[1]=="issues"]')" = "['BRIAN: run the migration (1 command, RUN ON TWIX)']" ] \
  && ok "files one issue under the agent's title" || notok "title ($(q 's["writes"]'))"
[ "$(q '[w[2]["assignees"] for w in s["writes"] if w[1]=="issues"]')" = "[['brianholland']]" ] \
  && ok "assigned to brianholland" || notok "assignee"
q '[w[2]["body"] for w in s["writes"] if w[1]=="issues"][0]' | grep -q "make prod-migrate" \
  && ok "the body carries the command" || notok "body"
[ "$(q '[w for w in s["writes"] if w[1]=="issues/42/dependencies/blocked_by"][0][2]')" = "{'issue_id': 9901}" ] \
  && ok "linked as blocked_by on the trigger issue, by database id" || notok "link ($(q 's["writes"]'))"
pr_body="$(q 's["pulls"][0]["body"]')"
case "$pr_body" in *"Closes #42"*"https://github.com/o/r/issues/901"*) ok "the PR body points at it and keeps its closing line" ;;
  *) notok "PR body ($pr_body)" ;; esac

# ---- re-run: idempotent
CASE="re-run"
before="$(q 'len(s["writes"])')"
run_step && ok "exits 0" || notok "exits 0 ($(cat "$TMP/out"))"
[ "$(q 'len([i for i in s["issues"] if i["title"].startswith("BRIAN:")])')" = 1 ] && ok "files no second issue" || notok "second issue"
[ "$(q 'len([w for w in s["writes"] if w[0]=="PATCH"])')" = 1 ] && ok "does not append the pointer twice" || notok "pointer twice"
[ "$(q "len(s['writes']) - $before")" = 1 ] && ok "only re-asserts the link (422 tolerated)" || notok "re-run writes ($(q 's["writes"]'))"

# ---- a title without the prefix gets it
CASE="bare title"
reset_state
printf 'restart the timer\n\nOn forge, as root: systemctl restart x\n' > "$TMP/host-step.md"
run_step && ok "exits 0" || notok "exits 0 ($(cat "$TMP/out"))"
[ "$(q '[w[2]["title"] for w in s["writes"] if w[1]=="issues"]')" = "['BRIAN: restart the timer']" ] \
  && ok "prefixed BRIAN:" || notok "prefix ($(q 's["writes"]'))"

echo
echo "agent-host-step-issue: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
