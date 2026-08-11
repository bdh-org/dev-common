#!/usr/bin/env bash
# submodule-bump.test.sh — behavioural tests for scripts/bump-submodule-pins.sh
# (home-infra#362; moved here with the engine in home-infra#368).
#
#   RUNS: anywhere with the repo checked out. No network, no GitHub credentials.
#   Wired into .github/workflows/shell-tests.yml, and picked up by `make test`
#   along with every other tests/*.test.sh.
#
# The script is driven END TO END against two seams:
#
#   GH_API   -> a stub GitHub API (python3 http.server on localhost) that also JOURNALS
#               every mutating request, so "it never merges" is checked by looking at what
#               it actually sent rather than at what the code appears to do.
#   GIT_BASE -> a directory of real BARE repositories, so the clone, the pointer move, the
#               `make bump-patch` commit and the force-push all really happen. The
#               assertions then read the remote: did bump/common move, did main NOT.
#
# WHY THESE CASES
#
# This script's whole safety story is a set of things it must never do, and every one of
# them is invisible in a happy-path test:
#
#   - it must never merge                 -> assert the journal contains no merge call, and
#                                            that the source contains no merge/squash verb
#   - it must never push to main          -> assert the consumer remote's main sha is
#                                            byte-identical before and after EVERY case,
#                                            including the failure cases
#   - it must never sed a version         -> assert the version moved AND that make
#                                            bump-patch is what moved it (the commit it
#                                            writes is on the branch)
#   - one PR, refreshed in place          -> assert a second sweep PATCHes and does not POST
#   - a pin that is already current       -> assert the open PR is CLOSED, not left to rot
#   - a consumer it cannot process        -> assert exit 1 and the name in the output; a
#                                            sweep covering 8 of 10 must not read as green
#                                            (home-infra#343)
#   - a dry run                           -> assert the remote is untouched, not merely
#                                            that the output says "would"
#   - a PR nobody can find                -> assert the assignee and the label go out on the
#                                            wire, and that a PR that could not get either
#                                            fails the sweep by name; "a PR exists" is not
#                                            the deliverable, "a PR Brian will see" is
#
# The PR body is checked too, because the body is what makes the merge safe: it has to say
# in the PR that merging deploys.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="${HERE}/../scripts/bump-submodule-pins.sh"
[ -x "$SCRIPT" ] || { echo "not executable: $SCRIPT" >&2; exit 2; }
command -v jq      >/dev/null 2>&1 || { echo "jq is required" >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "python3 is required" >&2; exit 2; }
command -v git     >/dev/null 2>&1 || { echo "git is required" >&2; exit 2; }

WORK="$(mktemp -d)"
STUB_PID=""
cleanup() { [ -n "$STUB_PID" ] && kill "$STUB_PID" 2>/dev/null; rm -rf "$WORK"; }
trap cleanup EXIT

PASS=0; FAIL=0; NA=0
ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/         /'; }
# Not a pass and not a failure: a case this environment cannot assess. Printed, counted,
# and repeated in the summary, because a case that quietly vanishes reads as a green one.
na()  { NA=$((NA+1));   printf '  n/a  %s\n         %s\n' "$1" "$2"; }

export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.com
export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.com

# ------------------------------------------------------------------- the fixture's bump-patch
#
# The fixture consumer's `make bump-patch` has to be the REAL target: "it never seds a
# version" is only meaningful if the tested path is the one the fleet runs. That target is
# `make/version.mk`, and in this repo it is simply on disk -- which is one of the smaller
# wins of moving the engine here (home-infra#368).
#
# In home-infra it reached the test only through the `common/` submodule, which ci.yml does
# not hydrate, so the fixture had to carry a vendored copy of version.mk plus a byte-identity
# case to catch that copy going stale. Both are now deleted rather than moved: a copy of a
# file that lives four directories away, in the same repo, is a second source of truth with
# none of the excuses.
#
# Never a stub. An earlier fixture fell back to `printf 'bump-patch:\n\t@true\n'`, so on the
# runner the consumer got a bump-patch that exits 0 and does nothing: two cases failed there
# and passed in the devcontainer. With no version.mk this suite cannot assess what it exists
# to assess, and says so with exit 2 rather than passing 32 of 34.
VERSION_MK="${HERE}/../make/version.mk"
[ -f "$VERSION_MK" ] || {
  echo "no version.mk to build the fixture from: ${VERSION_MK} does not exist" >&2
  echo "This suite tests that the sweep bumps versions with the REAL make target, so a stub would test nothing." >&2
  exit 2
}
printf 'fixture bump-patch comes from: %s\n\n' "$VERSION_MK"

# ---------------------------------------------------------------------------- the stub

cat >"${WORK}/stub.py" <<'PY'
"""Stub GitHub API for bump-submodule-pins.sh.

Fleet comes from $FIXTURE (JSON); every mutating request is appended to $JOURNAL as
"<METHOD> <path> <body>". Only the endpoints the script calls are served, and unknown
repos 404 exactly as GitHub does for "no access" -- the ambiguity the script has to
disambiguate by probing.

PR state is held in memory for the life of the process, so two sweeps against one stub
see each other's PRs. That is what makes the "refreshed in place, not duplicated" case a
real test rather than a mock.
"""
import json, os, base64
from datetime import datetime, timedelta, timezone
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import urlparse, parse_qs

JOURNAL = os.environ["JOURNAL"]

def fixture():
    # Re-read per request: a test needs to say "someone bumped that pin by hand" between
    # two sweeps while the PR the first sweep opened is still open in PULLS.
    return json.load(open(os.environ["FIXTURE"]))
PULLS = {}          # (repo) -> list of pull dicts
LABELS = {}         # (repo) -> set of label names that EXIST in that repo
NEXT = [900]

def journal(method, path, body):
    with open(JOURNAL, "a") as fh:
        fh.write("%s %s %s\n" % (method, path, (body or "").replace("\n", "\\n")))

class H(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def send(self, code, obj):
        raw = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def repo(self, o, r):
        return fixture().get("%s/%s" % (o, r))

    def do_GET(self):
        u = urlparse(self.path)
        p = [x for x in u.path.split("/") if x]
        q = parse_qs(u.query)
        # /repos/<o>/<r>...
        if len(p) < 3 or p[0] != "repos":
            return self.send(404, {"message": "no"})
        o, r = p[1], p[2]
        repo = self.repo(o, r)
        if repo is None or not repo.get("access", True):
            return self.send(404, {"message": "Not Found"})
        rest = p[3:]

        if not rest:
            return self.send(200, {"default_branch": repo.get("default_branch", "main")})

        if rest[0] == "commits" and len(rest) == 2:
            return self.send(200, {"sha": repo["head"]})

        if rest[0] == "contents":
            path = "/".join(rest[1:])
            if path == ".gitmodules":
                gm = repo.get("gitmodules")
                if gm is None:
                    return self.send(404, {"message": "Not Found"})
                return self.send(200, {"content": base64.b64encode(gm.encode()).decode()})
            c = (repo.get("contents") or {}).get(path)
            if c is None:
                return self.send(404, {"message": "Not Found"})
            return self.send(200, c)

        if rest[0] == "compare" and len(rest) == 2:
            base = rest[1].split("...")[0]
            cmp_ = (fixture().get("_compare") or {}).get(base) or {"ahead_by": 1, "days_ago": 1,
                                                           "subjects": ["something"], "files": []}
            when = (datetime.now(timezone.utc) - timedelta(days=cmp_["days_ago"])).strftime("%Y-%m-%dT%H:%M:%SZ")
            commits = [{"commit": {"message": s, "committer": {"date": when}}} for s in cmp_["subjects"]]
            return self.send(200, {"ahead_by": cmp_["ahead_by"], "behind_by": 0,
                                   "commits": commits,
                                   "files": [{"filename": f} for f in cmp_.get("files", [])]})

        if rest[0] == "labels" and len(rest) == 2:
            if rest[1] in LABELS.get("%s/%s" % (o, r), set()):
                return self.send(200, {"name": rest[1]})
            return self.send(404, {"message": "Not Found"})

        if rest[0] == "pulls" and len(rest) == 1:
            head = (q.get("head") or [""])[0]
            state = (q.get("state") or ["open"])[0]
            out = [pr for pr in PULLS.get("%s/%s" % (o, r), [])
                   if pr["state"] == state and ("%s:%s" % (o, pr["head"])) == head]
            return self.send(200, out)

        return self.send(404, {"message": "Not Found"})

    def body(self):
        n = int(self.headers.get("Content-Length") or 0)
        return self.rfile.read(n).decode() if n else ""

    def do_POST(self):
        b = self.body()
        journal("POST", urlparse(self.path).path, b)
        p = [x for x in urlparse(self.path).path.split("/") if x]
        if len(p) == 4 and p[0] == "repos" and p[3] == "pulls":
            d = json.loads(b or "{}")
            NEXT[0] += 1
            pr = {"number": NEXT[0], "state": "open", "head": d.get("head", ""),
                  "title": d.get("title", ""), "body": d.get("body", ""),
                  "assignees": [], "labels": []}
            PULLS.setdefault("%s/%s" % (p[1], p[2]), []).append(pr)
            return self.send(201, pr)

        # Create a repo label. `label_write: false` in the fixture is a token without
        # issues:write in that org -- the per-org permissions gap the script has to report
        # rather than degrade around.
        if len(p) == 4 and p[0] == "repos" and p[3] == "labels":
            repo = self.repo(p[1], p[2]) or {}
            if not repo.get("label_write", True):
                return self.send(403, {"message": "Resource not accessible by integration"})
            d = json.loads(b or "{}")
            LABELS.setdefault("%s/%s" % (p[1], p[2]), set()).add(d.get("name", ""))
            return self.send(201, {"name": d.get("name", "")})

        if len(p) == 6 and p[0] == "repos" and p[3] == "issues" and p[5] == "assignees":
            d = json.loads(b or "{}")
            repo = self.repo(p[1], p[2]) or {}
            # GitHub answers 201 and SILENTLY DROPS an assignee it will not honour (a user
            # with no push access to the repo is not assignable). `assignable: false`
            # models exactly that, because a stub that 4xx'd instead would test the easy
            # half and leave the half that actually goes wrong untested.
            keep = list(d.get("assignees", [])) if repo.get("assignable", True) else []
            for pr in PULLS.get("%s/%s" % (p[1], p[2]), []):
                if str(pr["number"]) == p[4]:
                    pr["assignees"] = keep
            return self.send(201, {"number": int(p[4]),
                                   "assignees": [{"login": a} for a in keep]})

        if len(p) == 6 and p[0] == "repos" and p[3] == "issues" and p[5] == "labels":
            d = json.loads(b or "{}")
            key = "%s/%s" % (p[1], p[2])
            names = [n for n in d.get("labels", []) if n in LABELS.get(key, set())]
            for pr in PULLS.get(key, []):
                if str(pr["number"]) == p[4]:
                    pr["labels"] = names
            return self.send(200, [{"name": n} for n in names])

        return self.send(404, {"message": "Not Found"})

    def do_PATCH(self):
        b = self.body()
        journal("PATCH", urlparse(self.path).path, b)
        p = [x for x in urlparse(self.path).path.split("/") if x]
        if len(p) == 5 and p[3] == "pulls":
            d = json.loads(b or "{}")
            for pr in PULLS.get("%s/%s" % (p[1], p[2]), []):
                if str(pr["number"]) == p[4]:
                    pr.update({k: v for k, v in d.items() if k in ("state", "title", "body")})
                    return self.send(200, pr)
            return self.send(404, {"message": "Not Found"})
        return self.send(404, {"message": "Not Found"})

    def do_DELETE(self):
        journal("DELETE", urlparse(self.path).path, "")
        self.send(204, {})

    def do_PUT(self):
        journal("PUT", urlparse(self.path).path, self.body())
        self.send(404, {"message": "Not Found"})

HTTPServer(("127.0.0.1", int(os.environ["PORT"])), H).serve_forever()
PY

# ---------------------------------------------------------------------------- fixtures
#
# Real bare repos. `mk_source` builds the submodule source; `mk_consumer` builds a repo
# that pins it at an OLD commit, exactly the state the sweep exists to fix.

REMOTES="${WORK}/remotes"
mkdir -p "${REMOTES}/bdh-org" "${REMOTES}/finzeug"

git_q() { git -c init.defaultBranch=main -c advice.detachedHead=false "$@"; }

# mk_source <slug> <n-commits> [file-to-touch] -> prints "<old-sha> <head-sha>"
mk_source() {
  local slug="$1" n="$2" extra="${3:-}"
  local bare="${REMOTES}/${slug}.git" wd="${WORK}/src-$(basename "$slug")"
  git_q init --quiet --bare "$bare"
  git_q init --quiet "$wd"
  mkdir -p "${wd}/make"
  # The REAL version.mk (resolved above), never a stand-in.
  cp "$VERSION_MK" "${wd}/make/version.mk"
  printf 'seed\n' > "${wd}/README.md"
  git_q -C "$wd" add -A >/dev/null; git_q -C "$wd" commit --quiet -m "seed"
  local old; old="$(git_q -C "$wd" rev-parse HEAD)"
  local i
  for i in $(seq 1 "$n"); do
    printf 'change %s\n' "$i" >> "${wd}/README.md"
    [ -n "$extra" ] && printf 'line %s\n' "$i" >> "${wd}/${extra}"
    git_q -C "$wd" add -A >/dev/null
    git_q -C "$wd" commit --quiet -m "feat: source change ${i}"
  done
  git_q -C "$wd" push --quiet "$bare" main >/dev/null 2>&1
  git_q -C "$bare" symbolic-ref HEAD refs/heads/main
  printf '%s %s' "$old" "$(git_q -C "$wd" rev-parse HEAD)"
}

# mk_consumer <slug> <sub-path> <source-slug> <pin-sha> <makefile-version|"">
mk_consumer() {
  local slug="$1" path="$2" src="$3" pin="$4" ver="$5"
  local bare="${REMOTES}/${slug}.git" wd="${WORK}/con-$(basename "$slug")"
  git_q init --quiet --bare "$bare"
  git_q init --quiet "$wd"
  if [ -n "$ver" ]; then
    { printf 'VERSION=%s\n\n-include %s/make/version.mk\n' "$ver" "$path"
      printf '\n.PHONY: noop\nnoop:\n\t@true\n'; } > "${wd}/Makefile"
  else
    printf '.PHONY: noop\nnoop:\n\t@true\n' > "${wd}/Makefile"
  fi
  printf 'consumer\n' > "${wd}/README.md"
  git_q -C "$wd" add -A >/dev/null; git_q -C "$wd" commit --quiet -m "seed"
  # Add the submodule from the local bare repo, then rewrite the URL to the github.com one
  # the fleet really declares -- the script resolves the source by SLUG, and rewrites
  # github.com back to GIT_BASE when it hydrates. Both halves are under test.
  git_q -C "$wd" -c protocol.file.allow=always submodule add --quiet "${REMOTES}/${src}.git" "$path" >/dev/null 2>&1
  git_q -C "$wd" -C "$path" checkout --quiet --detach "$pin"
  git_q -C "$wd" config -f .gitmodules "submodule.${path}.url" "https://github.com/${src}.git"
  git_q -C "$wd" add -A >/dev/null
  git_q -C "$wd" commit --quiet -m "add ${path}"
  git_q -C "$wd" push --quiet "$bare" main >/dev/null 2>&1
  git_q -C "$bare" symbolic-ref HEAD refs/heads/main
}

pin_of()  { git_q -C "${REMOTES}/${1}.git" ls-tree main "$2" | awk '{print $3}'; }
mainsha() { git_q -C "${REMOTES}/${1}.git" rev-parse main; }
refsha()  { git_q -C "${REMOTES}/${1}.git" rev-parse --verify --quiet "refs/heads/$2" 2>/dev/null; }

# ---------------------------------------------------------------------------- runner

PORT=0
start_stub() {  # start_stub <fixture-file>
  [ -n "$STUB_PID" ] && { kill "$STUB_PID" 2>/dev/null; wait "$STUB_PID" 2>/dev/null; STUB_PID=""; }
  PORT="$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()')"
  : > "${WORK}/journal.txt"
  FIXTURE="$1" JOURNAL="${WORK}/journal.txt" PORT="$PORT" python3 "${WORK}/stub.py" &
  STUB_PID=$!
  local i
  for i in $(seq 1 50); do
    curl -sS -o /dev/null "http://127.0.0.1:${PORT}/repos/x/y" 2>/dev/null && return 0
    sleep 0.1
  done
  echo "stub did not come up" >&2; exit 2
}

run_bump() {  # run_bump <args...> -> sets OUT / RC
  OUT="$(env -u BUMP_BRANCH_PREFIX GH_API="http://127.0.0.1:${PORT}" GIT_BASE="${REMOTES}/" \
             GH_TOKEN="t" CRED_DIR="${WORK}/nocreds" \
             GIT_ALLOW_PROTOCOL=file:https GIT_CONFIG_COUNT=1 \
             GIT_CONFIG_KEY_0=protocol.file.allow GIT_CONFIG_VALUE_0=always \
             "$SCRIPT" "$@" 2>&1)"
  RC=$?
}

has()  { printf '%s' "$OUT" | grep -qF "$1"; }
jhas() { grep -qF "$1" "${WORK}/journal.txt"; }

# ============================================================================ case 1
# A behind pin: PR opened, branch pushed, version bumped, main untouched.

read -r OLD HEAD <<<"$(mk_source bdh-org/dev-common 3 CLAUDE.md)"
mk_consumer bdh-org/home-site common bdh-org/dev-common "$OLD" "1.2.176"
mk_consumer bdh-org/home-infra common bdh-org/dev-common "$OLD" ""

cat >"${WORK}/fx.json" <<EOF
{
  "bdh-org/dev-common": {"default_branch": "main", "head": "${HEAD}"},
  "bdh-org/home-site": {"default_branch": "main", "head": "$(mainsha bdh-org/home-site)",
    "gitmodules": "[submodule \\"common\\"]\\n\\tpath = common\\n\\turl = https://github.com/bdh-org/dev-common.git\\n",
    "contents": {"common": {"type": "submodule", "sha": "$(pin_of bdh-org/home-site common)"},
                 ".github/workflows/ci-build.yml": {"type": "file", "sha": "deadbeef"}}},
  "bdh-org/home-infra": {"default_branch": "main", "head": "$(mainsha bdh-org/home-infra)",
    "gitmodules": "[submodule \\"common\\"]\\n\\tpath = common\\n\\turl = https://github.com/bdh-org/dev-common.git\\n",
    "contents": {"common": {"type": "submodule", "sha": "$(pin_of bdh-org/home-infra common)"}}},
  "_compare": {"${OLD}": {"ahead_by": 3, "days_ago": 9,
                          "subjects": ["feat: source change 1", "feat: source change 3"],
                          "files": ["CLAUDE.md"]}}
}
EOF

REGISTRY="${WORK}/reg.txt"
cat > "$REGISTRY" <<'EOF'
bdh-org/home-site  | - | - | P1 primary
bdh-org/home-infra | - | - | architect workspace, deliberately versionless
EOF

SITE_MAIN_BEFORE="$(mainsha bdh-org/home-site)"
INFRA_MAIN_BEFORE="$(mainsha bdh-org/home-infra)"

start_stub "${WORK}/fx.json"
run_bump --source bdh-org/dev-common --registry "$REGISTRY"

{ [ "$RC" = 0 ] && has "opened PR #" && has "2 bumped"; } \
  && ok "a behind pin gets a PR opened and the sweep exits 0" \
  || bad "a behind pin gets a PR opened and the sweep exits 0" "rc=$RC
$OUT"

{ [ -n "$(refsha bdh-org/home-site bump/common)" ] \
  && [ "$(git_q -C "${REMOTES}/bdh-org/home-site.git" ls-tree bump/common common | awk '{print $3}')" = "$HEAD" ]; } \
  && ok "the bump branch on the consumer remote carries the NEW pin" \
  || bad "the bump branch on the consumer remote carries the NEW pin"

{ [ "$(mainsha bdh-org/home-site)" = "$SITE_MAIN_BEFORE" ] \
  && [ "$(mainsha bdh-org/home-infra)" = "$INFRA_MAIN_BEFORE" ]; } \
  && ok "the consumer's main is byte-identical afterwards — nothing was pushed to it" \
  || bad "the consumer's main is byte-identical afterwards — nothing was pushed to it"

v="$(git_q -C "${REMOTES}/bdh-org/home-site.git" show bump/common:Makefile | grep -m1 '^VERSION=')"
mv="$(git_q -C "${REMOTES}/bdh-org/home-site.git" show main:Makefile | grep -m1 '^VERSION=')"
{ [ "$v" = "VERSION=1.2.177" ] && [ "$mv" = "VERSION=1.2.176" ]; } \
  && ok "make bump-patch moved the version on the branch and only there" \
  || bad "make bump-patch moved the version on the branch and only there" "branch=$v main=$mv"

# Read the subjects ONCE into a variable and match with a here-string, rather than piping
# `git log` into `grep -q`. This suite runs under `set -o pipefail`, and `grep -q` exits the
# instant it matches -- if git has not finished writing by then it takes SIGPIPE (141), which
# pipefail promotes to the pipeline's status and the case fails with the very lines it was
# looking for printed underneath it. That is a race against the scheduler: it passed on the
# forge runner and failed on ubuntu-latest, first run (home-infra#368).
SUBJECTS="$(git_q -C "${REMOTES}/bdh-org/home-site.git" log --format=%s bump/common)"
{ grep -q '^chore: bump version to 1.2.177$' <<<"$SUBJECTS" \
  && grep -q '^chore: bump common to ' <<<"$SUBJECTS"; } \
  && ok "the branch carries the pointer commit AND bump-patch's own commit" \
  || bad "the branch carries the pointer commit AND bump-patch's own commit" \
         "$(printf '%s\n' "$SUBJECTS" | head -3)"

has "does not pin" && bad "a consumer that pins the source is not reported as unrelated" \
  || ok "both registry entries were recognised as consumers of the source"

# --- the PR body is the safety story, so it is asserted, not assumed ----------
BODY="$(grep -m1 '^POST /repos/bdh-org/home-site/pulls ' "${WORK}/journal.txt" | cut -d' ' -f3-)"
b_has() { printf '%s' "$BODY" | grep -qF "$1"; }
{ b_has "Merging this is a deploy" && b_has "restarts **home-site**" \
  && b_has "3 commits, oldest one missed 9 days ago"; } \
  && ok "a consumer WITH ci-build is told merging deploys, and which service restarts" \
  || bad "a consumer WITH ci-build is told merging deploys, and which service restarts" "$BODY"

b_has "compare/${OLD}...${HEAD}" \
  && ok "the PR body carries the source commit range" \
  || bad "the PR body carries the source commit range" "$BODY"

b_has "make bump-patch" \
  && ok "the PR body says the version moved and how" \
  || bad "the PR body says the version moved and how"

BODY_INFRA="$(grep -m1 '^POST /repos/bdh-org/home-infra/pulls ' "${WORK}/journal.txt" | cut -d' ' -f3-)"
printf '%s' "$BODY_INFRA" | grep -qF 'No `VERSION=` in this Makefile' \
  && ok "a versionless consumer is bumped anyway, and the PR says why there is no version bump" \
  || bad "a versionless consumer is bumped anyway, and the PR says why there is no version bump" "$BODY_INFRA"

{ printf '%s' "$BODY_INFRA" | grep -qF 'Merging this deploys nothing directly' \
  && ! printf '%s' "$BODY_INFRA" | grep -qF 'Merging this is a deploy'; } \
  && ok "a consumer with NO ci-build is not told a deploy it does not have" \
  || bad "a consumer with NO ci-build is not told a deploy it does not have" "$BODY_INFRA"

# --- findable, or it may as well not exist ------------------------------------
#
# Brian reviews these by searching, once a morning, across fourteen repos:
#   is:pr is:open assignee:brianholland label:submodule-bump
# Both halves of that query are asserted on the wire, per consumer.

{ jhas 'POST /repos/bdh-org/home-site/issues/901/assignees {"assignees":["brianholland"]}' \
  && jhas 'POST /repos/bdh-org/home-infra/issues/902/assignees {"assignees":["brianholland"]}'; } \
  && ok "every PR is assigned to brianholland — not to bdh-ai, which both sessions already are" \
  || bad "every PR is assigned to brianholland — not to bdh-ai, which both sessions already are" \
         "$(grep assignees "${WORK}/journal.txt")"

{ grep -qE '^POST /repos/bdh-org/home-site/labels \{"name":"submodule-bump"' "${WORK}/journal.txt" \
  && grep -qE '^POST /repos/bdh-org/home-infra/labels \{"name":"submodule-bump"' "${WORK}/journal.txt"; } \
  && ok "the submodule-bump label is created in a consumer that does not have it" \
  || bad "the submodule-bump label is created in a consumer that does not have it" \
         "$(grep labels "${WORK}/journal.txt")"

{ jhas 'POST /repos/bdh-org/home-site/issues/901/labels {"labels":["submodule-bump"]}' \
  && jhas 'POST /repos/bdh-org/home-infra/issues/902/labels {"labels":["submodule-bump"]}'; } \
  && ok "every PR carries the submodule-bump label" \
  || bad "every PR carries the submodule-bump label" "$(grep labels "${WORK}/journal.txt")"

# --- the negative space -------------------------------------------------------
#
# Not `awk ... | grep -qiE`: under pipefail an early-exiting `grep -q` can SIGPIPE the awk
# feeding it, and here that lands on the WRONG side -- a 141 reads as "no merge found" and
# this case goes green over a journal that holds one. The verbs are read into a variable and
# matched with a here-string, so the only thing being asked about is the journal.
VERBS="$(awk '{print $1, $2}' "${WORK}/journal.txt")"
grep -qiE 'merge' <<<"$VERBS" \
  && bad "the sweep sent no merge request" "$(cat "${WORK}/journal.txt")" \
  || ok "the sweep sent no merge request of any kind"

# ============================================================================ case 2
# Re-run against the same stub: refreshed in place, not duplicated.

BR1="$(refsha bdh-org/home-site bump/common)"
: > "${WORK}/journal.txt"
run_bump --source bdh-org/dev-common --registry "$REGISTRY"
{ [ "$RC" = 0 ] && has "refreshed PR #" && ! jhas "POST /repos/bdh-org/home-site/pulls"; } \
  && ok "a second sweep refreshes the open PR instead of opening a second one" \
  || bad "a second sweep refreshes the open PR instead of opening a second one" "rc=$RC
$OUT"

{ [ -n "$(refsha bdh-org/home-site bump/common)" ] && [ "$(refsha bdh-org/home-site bump/common)" != "$BR1" ]; } \
  && ok "the stable branch is force-pushed (rewritten), not appended to" \
  || bad "the stable branch is force-pushed (rewritten), not appended to"

[ "$(mainsha bdh-org/home-site)" = "$SITE_MAIN_BEFORE" ] \
  && ok "main is still untouched after the second sweep" \
  || bad "main is still untouched after the second sweep"

# Re-applied on the refresh path (a PR somebody unassigned by hand is as invisible as one
# that never had an assignee), but the label is CREATED only when it is absent.
{ jhas 'POST /repos/bdh-org/home-site/issues/901/assignees {"assignees":["brianholland"]}' \
  && jhas 'POST /repos/bdh-org/home-site/issues/901/labels {"labels":["submodule-bump"]}' \
  && ! grep -qE '^POST /repos/bdh-org/home-site/labels ' "${WORK}/journal.txt"; } \
  && ok "a refreshed PR is re-assigned and re-labelled, and the existing label is not re-created" \
  || bad "a refreshed PR is re-assigned and re-labelled, and the existing label is not re-created" \
         "$(cat "${WORK}/journal.txt")"

# ============================================================================ case 3
# The pin is already current: the open PR is CLOSED and its branch deleted, so an open
# bump PR always means real drift. Same stub process, so the PR opened in case 1 is still
# open; only the fixture changes, standing in for "somebody bumped it by hand".

cp "${WORK}/fx.json" "${WORK}/fx-behind.json"
python3 -c 'import json,sys; fx=json.load(open(sys.argv[1])); fx["bdh-org/home-site"]["contents"]["common"]["sha"]=sys.argv[2]; json.dump(fx, open(sys.argv[1],"w"))' \
  "${WORK}/fx.json" "$HEAD"

: > "${WORK}/journal.txt"
run_bump --source bdh-org/dev-common --registry "$REGISTRY" --only bdh-org/home-site
{ [ "$RC" = 0 ] && has "closed stale PR #"; } \
  && ok "a pin someone bumped by hand closes the open PR instead of leaving it to rot" \
  || bad "a pin someone bumped by hand closes the open PR instead of leaving it to rot" "rc=$RC
$OUT"

{ grep -qE '^PATCH /repos/bdh-org/home-site/pulls/[0-9]+ .*"state":"closed"' "${WORK}/journal.txt" \
  && jhas "DELETE /repos/bdh-org/home-site/git/refs/heads/bump/common"; } \
  && ok "closing goes through PATCH state=closed and the branch ref is deleted" \
  || bad "closing goes through PATCH state=closed and the branch ref is deleted" "$(cat "${WORK}/journal.txt")"

{ ! jhas "POST" && [ "$(mainsha bdh-org/home-site)" = "$SITE_MAIN_BEFORE" ]; } \
  && ok "a current pin opens nothing and still does not touch main" \
  || bad "a current pin opens nothing and still does not touch main"

cp "${WORK}/fx-behind.json" "${WORK}/fx.json"

# ============================================================================ case 4
# Dry run: the remote must be provably untouched.

git_q -C "${REMOTES}/bdh-org/home-site.git" update-ref -d refs/heads/bump/common
start_stub "${WORK}/fx.json"
run_bump --source bdh-org/dev-common --registry "$REGISTRY" --only bdh-org/home-site --dry-run
{ [ "$RC" = 0 ] && has "DRY RUN" && has "would open/refresh bump/common"; } \
  && ok "a dry run reports what it would do and exits 0" \
  || bad "a dry run reports what it would do and exits 0" "rc=$RC
$OUT"

{ [ -z "$(refsha bdh-org/home-site bump/common)" ] && [ ! -s "${WORK}/journal.txt" ] \
  && [ "$(mainsha bdh-org/home-site)" = "$SITE_MAIN_BEFORE" ]; } \
  && ok "a dry run pushes no branch and sends no mutating request — checked on the remote" \
  || bad "a dry run pushes no branch and sends no mutating request — checked on the remote" \
         "ref=$(refsha bdh-org/home-site bump/common) journal=$(cat "${WORK}/journal.txt")"

# ============================================================================ case 5
# A `make bump-patch` that fails is a FAILURE, and nothing gets pushed.

mk_consumer finzeug/hog common bdh-org/dev-common "$OLD" "0.4.2"
# break bump-patch the way a real breakage looks: VERSION present, target unusable
HOGWD="${WORK}/hogfix"
git_q clone --quiet "${REMOTES}/finzeug/hog.git" "$HOGWD"
printf 'VERSION=0.4.2\n\n.PHONY: bump-patch\nbump-patch:\n\t@echo "boom: version file missing" >&2; exit 1\n' > "${HOGWD}/Makefile"
git_q -C "$HOGWD" commit --quiet -am "break bump-patch"
git_q -C "$HOGWD" push --quiet origin main
HOG_MAIN_BEFORE="$(mainsha finzeug/hog)"

cat >"${WORK}/fx-hog.json" <<EOF
{
  "bdh-org/dev-common": {"default_branch": "main", "head": "${HEAD}"},
  "finzeug/hog": {"default_branch": "main", "head": "${HOG_MAIN_BEFORE}",
    "gitmodules": "[submodule \\"common\\"]\\n\\tpath = common\\n\\turl = https://github.com/bdh-org/dev-common.git\\n",
    "contents": {"common": {"type": "submodule", "sha": "$(pin_of finzeug/hog common)"}}},
  "_compare": {"${OLD}": {"ahead_by": 3, "days_ago": 9, "subjects": ["feat: x"], "files": []}}
}
EOF
printf 'finzeug/hog | - | - | P2a service\n' > "${WORK}/reg-hog.txt"

start_stub "${WORK}/fx-hog.json"
run_bump --source bdh-org/dev-common --registry "${WORK}/reg-hog.txt"
{ [ "$RC" = 1 ] && has "make bump-patch failed" && has "could not process:" && has "finzeug/hog"; } \
  && ok "a bump-patch that errors fails the sweep and names the repo" \
  || bad "a bump-patch that errors fails the sweep and names the repo" "rc=$RC
$OUT"

{ [ -z "$(refsha finzeug/hog bump/common)" ] && [ "$(mainsha finzeug/hog)" = "$HOG_MAIN_BEFORE" ] \
  && ! jhas "POST /repos/finzeug/hog/pulls"; } \
  && ok "a failed consumer leaves NO branch and NO PR behind" \
  || bad "a failed consumer leaves NO branch and NO PR behind"

# ============================================================================ case 6
# Absence cases: no credential, no consumer for this source, empty registry.

OUT="$(env -u GH_TOKEN GH_API="http://127.0.0.1:${PORT}" GIT_BASE="${REMOTES}/" CRED_DIR="${WORK}/nocreds" \
        "$SCRIPT" --source bdh-org/dev-common --registry "${WORK}/reg-hog.txt" 2>&1)"; RC=$?
{ [ "$RC" = 2 ] && printf '%s' "$OUT" | grep -q "no credential for bdh-org"; } \
  && ok "no credential for the source org exits 2, never 0" \
  || bad "no credential for the source org exits 2, never 0" "rc=$RC
$OUT"

printf 'finzeug/ledger-io | - | - | pinned-only library\n' > "${WORK}/reg-none.txt"
cat >"${WORK}/fx-none.json" <<EOF
{
  "bdh-org/dev-common": {"default_branch": "main", "head": "${HEAD}"},
  "finzeug/ledger-io": {"default_branch": "main", "head": "x",
    "gitmodules": "[submodule \\"vendor\\"]\\n\\tpath = vendor\\n\\turl = https://github.com/finzeug/ratecraft.git\\n",
    "contents": {}}
}
EOF
start_stub "${WORK}/fx-none.json"
run_bump --source bdh-org/dev-common --registry "${WORK}/reg-none.txt"
{ [ "$RC" = 2 ] && has "no consumer in the registry pins bdh-org/dev-common" && has "does not pin"; } \
  && ok "a sweep that matched nothing exits 2 and says so — 0 of 0 is not a pass" \
  || bad "a sweep that matched nothing exits 2 and says so — 0 of 0 is not a pass" "rc=$RC
$OUT"

: > "${WORK}/reg-empty.txt"
run_bump --source bdh-org/dev-common --registry "${WORK}/reg-empty.txt"
[ "$RC" = 2 ] \
  && ok "an empty registry exits 2" \
  || bad "an empty registry exits 2" "rc=$RC
$OUT"

run_bump --source bdh-org/dev-common --registry "${WORK}/no-such-file.txt"
{ [ "$RC" = 2 ] && has "no consumer registry at"; } \
  && ok "a missing registry file is named, not silently treated as no consumers" \
  || bad "a missing registry file is named, not silently treated as no consumers" "rc=$RC
$OUT"

# ============================================================================ case 7
# A repo the token cannot read must FAIL, not be mistaken for "no submodules".

cat >"${WORK}/fx-noacc.json" <<EOF
{
  "bdh-org/dev-common": {"default_branch": "main", "head": "${HEAD}"},
  "finzeug/hog": {"access": false, "default_branch": "main", "head": "x"}
}
EOF
start_stub "${WORK}/fx-noacc.json"
run_bump --source bdh-org/dev-common --registry "${WORK}/reg-hog.txt"
{ [ "$RC" = 2 ] && has "not readable with the finzeug credential"; } \
  && ok "an unreadable consumer is a failure that names access, not a clean bill of health" \
  || bad "an unreadable consumer is a failure that names access, not a clean bill of health" "rc=$RC
$OUT"

# ============================================================================ case 8
# Static guarantees: the code cannot merge, and every push is the guarded one.

{ ! grep -nE 'pulls/[^ ]*/merge|--squash|gh pr merge|"merge_method"|/merges' "$SCRIPT" >/dev/null; } \
  && ok "the source contains no merge call of any kind (API or gh)" \
  || bad "the source contains no merge call of any kind (API or gh)" "$(grep -nE 'merge' "$SCRIPT")"

[ "$(grep -cE '^[^#]*git .*push' "$SCRIPT")" = "1" ] \
  && ok "there is exactly ONE git push in the script, inside the guarded push_branch" \
  || bad "there is exactly ONE git push in the script, inside the guarded push_branch" \
         "$(grep -nE '^[^#]*git .*push' "$SCRIPT")"

grep -qF 'HEAD:refs/heads/${branch}' "$SCRIPT" \
  && ok "that push uses an explicit refspec, so no local ref name can redirect it" \
  || bad "that push uses an explicit refspec, so no local ref name can redirect it"

# The guard itself, exercised: a prefix-less branch and the default branch are both refused.
OUT="$(bash -c '
  set -uo pipefail
  BRANCH_PREFIX="bump/"
  note() { printf "%s\n" "$*" >&2; }
  '"$(sed -n '/^push_branch() {/,/^}/p' "$SCRIPT")"'
  push_branch /tmp main main file:///nope; echo "rc-main=$?"
  push_branch /tmp hotfix main file:///nope; echo "rc-prefix=$?"
' 2>&1)"
{ printf '%s' "$OUT" | grep -q "rc-main=1" && printf '%s' "$OUT" | grep -q "rc-prefix=1" \
  && printf '%s' "$OUT" | grep -q "REFUSING to push 'main'"; } \
  && ok "push_branch refuses the default branch and any ref outside bump/" \
  || bad "push_branch refuses the default branch and any ref outside bump/" "$OUT"

# ============================================================================ case 9
# stack-common carries CLAUDE.md, and the PR has to say what CI cannot test.

read -r SOLD SHEAD <<<"$(mk_source bdh-org/home-stack-common 4 CLAUDE.md)"
mk_consumer finzeug/canary stack-common bdh-org/home-stack-common "$SOLD" "0.9.0"
cat >"${WORK}/fx-sc.json" <<EOF
{
  "bdh-org/home-stack-common": {"default_branch": "main", "head": "${SHEAD}"},
  "finzeug/canary": {"default_branch": "main", "head": "$(mainsha finzeug/canary)",
    "gitmodules": "[submodule \\"stack-common\\"]\\n\\tpath = stack-common\\n\\turl = https://github.com/bdh-org/home-stack-common.git\\n",
    "contents": {"stack-common": {"type": "submodule", "sha": "$(pin_of finzeug/canary stack-common)"}}},
  "_compare": {"${SOLD}": {"ahead_by": 15, "days_ago": 30, "subjects": ["docs: fix twix mount"],
                           "files": ["CLAUDE.md"]}}
}
EOF
printf 'finzeug/canary | - | - | P2a service\n' > "${WORK}/reg-canary.txt"
CANARY_MAIN_BEFORE="$(mainsha finzeug/canary)"
start_stub "${WORK}/fx-sc.json"
run_bump --source bdh-org/home-stack-common --registry "${WORK}/reg-canary.txt"

SBODY="$(grep -m1 '^POST /repos/finzeug/canary/pulls ' "${WORK}/journal.txt" | cut -d' ' -f3-)"
{ [ "$RC" = 0 ] && printf '%s' "$SBODY" | grep -qF 'This range changes `CLAUDE.md`' \
  && printf '%s' "$SBODY" | grep -qF 'No test covers an instruction change'; } \
  && ok "a stack-common bump touching CLAUDE.md says so, and says nothing tests it" \
  || bad "a stack-common bump touching CLAUDE.md says so, and says nothing tests it" "rc=$RC
$SBODY"

{ [ "$(mainsha finzeug/canary)" = "$CANARY_MAIN_BEFORE" ] \
  && [ "$(git_q -C "${REMOTES}/finzeug/canary.git" ls-tree bump/stack-common stack-common | awk '{print $3}')" = "$SHEAD" ]; } \
  && ok "the stack-common branch is bump/stack-common and main is untouched" \
  || bad "the stack-common branch is bump/stack-common and main is untouched"

# The nested dev-common inside stack-common must NOT be rewritten from a consumer
# (home-infra#362 §4: the layering is deliberate).
grep -qF 'NOT --recursive' "$SCRIPT" \
  && ok "hydration is deliberately non-recursive, so a nested pin is never rewritten here" \
  || bad "hydration is deliberately non-recursive, so a nested pin is never rewritten here"

# ============================================================================ case 10
# A `make bump-patch` that exits 0 and moves NOTHING is a failure too.
#
# Case 5 covers the loud version (bump-patch errors). This is the quiet one, and it is the
# one that actually happens: a consumer whose `-include common/make/version.mk` did not
# resolve, or any stub target, gives `make bump-patch` an exit status of 0 and no version
# change. What that would push is a bump PR carrying no version bump -- byte-for-byte the
# silent version collision of 2026-08-11 (finzeug/ledger-io#42: rebased clean, no conflict,
# no warning, and would have shipped under an already-published version). The sweep has to
# read the version back out of the COMMIT and fail naming the consumer (home-infra#343).
#
# This fixture is also exactly the shape the old test fixture had on the forge runner, so
# this case fails loudly if that papering-over ever comes back.

mk_consumer finzeug/panoptikon common bdh-org/dev-common "$OLD" "2.1.0"
NOOPWD="${WORK}/panofix"
git_q clone --quiet "${REMOTES}/finzeug/panoptikon.git" "$NOOPWD"
printf 'VERSION=2.1.0\n\n.PHONY: bump-patch\nbump-patch:\n\t@echo "nothing to bump"\n' > "${NOOPWD}/Makefile"
git_q -C "$NOOPWD" commit --quiet -am "make bump-patch a silent no-op"
git_q -C "$NOOPWD" push --quiet origin main
PANO_MAIN_BEFORE="$(mainsha finzeug/panoptikon)"

cat >"${WORK}/fx-pano.json" <<EOF
{
  "bdh-org/dev-common": {"default_branch": "main", "head": "${HEAD}"},
  "finzeug/panoptikon": {"default_branch": "main", "head": "${PANO_MAIN_BEFORE}",
    "gitmodules": "[submodule \\"common\\"]\\n\\tpath = common\\n\\turl = https://github.com/bdh-org/dev-common.git\\n",
    "contents": {"common": {"type": "submodule", "sha": "$(pin_of finzeug/panoptikon common)"}}},
  "_compare": {"${OLD}": {"ahead_by": 3, "days_ago": 9, "subjects": ["feat: x"], "files": []}}
}
EOF
printf 'finzeug/panoptikon | - | - | P2a service\n' > "${WORK}/reg-pano.txt"

start_stub "${WORK}/fx-pano.json"
run_bump --source bdh-org/dev-common --registry "${WORK}/reg-pano.txt"
{ [ "$RC" = 1 ] && has "committed no version change" && has "could not process:" && has "finzeug/panoptikon"; } \
  && ok "a bump-patch that exits 0 and moves no version FAILS the sweep and names the consumer" \
  || bad "a bump-patch that exits 0 and moves no version FAILS the sweep and names the consumer" "rc=$RC
$OUT"

has "VERSION=2.1.0 before and after" \
  && ok "the no-op failure names the version it read, not just that something went wrong" \
  || bad "the no-op failure names the version it read, not just that something went wrong" "$OUT"

{ [ -z "$(refsha finzeug/panoptikon bump/common)" ] && [ "$(mainsha finzeug/panoptikon)" = "$PANO_MAIN_BEFORE" ] \
  && ! jhas "POST /repos/finzeug/panoptikon/pulls"; } \
  && ok "the no-op consumer gets NO branch and NO PR — a versionless bump is never pushed" \
  || bad "the no-op consumer gets NO branch and NO PR — a versionless bump is never pushed"

# ============================================================================ case 11
# A PR that cannot be made FINDABLE is a failure, even though the PR is correct.
#
# Two shapes, one sweep, because they fail differently and both have to be named:
#
#   finzeug/oleo    the assignee is silently dropped. GitHub answers 201 with the login
#                   simply missing from .assignees when the user has no push access, so a
#                   sweep that trusted the status would report green over a PR assigned to
#                   nobody -- the silent no-op of home-infra#343, one layer up.
#   finzeug/ferret  the token has no issues:write in that org, so creating the label 403s.
#                   That is the per-org permissions gap of home-infra#350, and the sweep
#                   has to say so plainly rather than quietly ship unlabelled PRs.
#
# In both, the branch and the PR must still be there: the deliverable was produced, it just
# cannot be found, and deleting it would make a bad morning worse.

mk_consumer finzeug/oleo   common bdh-org/dev-common "$OLD" "3.0.0"
mk_consumer finzeug/ferret common bdh-org/dev-common "$OLD" "1.0.0"
OLEO_MAIN_BEFORE="$(mainsha finzeug/oleo)"
FERRET_MAIN_BEFORE="$(mainsha finzeug/ferret)"

cat >"${WORK}/fx-dark.json" <<EOF
{
  "bdh-org/dev-common": {"default_branch": "main", "head": "${HEAD}"},
  "finzeug/oleo": {"default_branch": "main", "head": "${OLEO_MAIN_BEFORE}", "assignable": false,
    "gitmodules": "[submodule \\"common\\"]\\n\\tpath = common\\n\\turl = https://github.com/bdh-org/dev-common.git\\n",
    "contents": {"common": {"type": "submodule", "sha": "$(pin_of finzeug/oleo common)"}}},
  "finzeug/ferret": {"default_branch": "main", "head": "${FERRET_MAIN_BEFORE}", "label_write": false,
    "gitmodules": "[submodule \\"common\\"]\\n\\tpath = common\\n\\turl = https://github.com/bdh-org/dev-common.git\\n",
    "contents": {"common": {"type": "submodule", "sha": "$(pin_of finzeug/ferret common)"}}},
  "_compare": {"${OLD}": {"ahead_by": 3, "days_ago": 9, "subjects": ["feat: x"], "files": []}}
}
EOF
printf 'finzeug/oleo   | - | - | P2b static site\nfinzeug/ferret | - | - | library consumer\n' \
  > "${WORK}/reg-dark.txt"

start_stub "${WORK}/fx-dark.json"
run_bump --source bdh-org/dev-common --registry "${WORK}/reg-dark.txt"

{ [ "$RC" = 1 ] && has "2 opened but not findable"; } \
  && ok "a PR nobody is assigned to fails the sweep — 'a PR exists' is not the deliverable" \
  || bad "a PR nobody is assigned to fails the sweep — 'a PR exists' is not the deliverable" "rc=$RC
$OUT"

{ has "finzeug/oleo" && has "not assignable" && has "dropped the assignee"; } \
  && ok "the dropped assignee is named per occurrence, with the repo and the reason" \
  || bad "the dropped assignee is named per occurrence, with the repo and the reason" "$OUT"

{ has "finzeug/ferret" && has "cannot create label 'submodule-bump'" && has "403"; } \
  && ok "a token without issues:write in an org is reported as that, not degraded around" \
  || bad "a token without issues:write in an org is reported as that, not degraded around" "$OUT"

# As a URL, not a bare number: the point of the failure is that somebody has to open that
# PR and fix it by hand, and a number costs them a lookup per repo.
{ has "open but not findable:" && has "https://github.com/finzeug/oleo/pull/" \
  && has "https://github.com/finzeug/ferret/pull/"; } \
  && ok "the unfindable PRs are listed in the summary, by URL, the way the other failure modes are" \
  || bad "the unfindable PRs are listed in the summary, by URL, the way the other failure modes are" "$OUT"

{ [ -n "$(refsha finzeug/oleo bump/common)" ] && [ -n "$(refsha finzeug/ferret bump/common)" ] \
  && jhas "POST /repos/finzeug/oleo/pulls" && jhas "POST /repos/finzeug/ferret/pulls" \
  && [ "$(mainsha finzeug/oleo)" = "$OLEO_MAIN_BEFORE" ] \
  && [ "$(mainsha finzeug/ferret)" = "$FERRET_MAIN_BEFORE" ]; } \
  && ok "an unfindable PR is still opened and still counted — the work is not thrown away" \
  || bad "an unfindable PR is still opened and still counted — the work is not thrown away" "$OUT"

# The 403 must not swallow the assignment: ferret IS assignable, and only the label failed.
jhas 'POST /repos/finzeug/ferret/issues/' \
  && ok "a label failure does not skip the assignment — both halves are attempted" \
  || bad "a label failure does not skip the assignment — both halves are attempted" \
         "$(cat "${WORK}/journal.txt")"

# ============================================================================

echo
[ "$NA" -gt 0 ] && echo "NOT ASSESSED HERE: ${NA} case(s) — see the n/a lines above"
if [ "$FAIL" -gt 0 ]; then echo "FAIL: ${FAIL} failed, ${PASS} passed"; exit 1; fi
echo "PASS: ${PASS} cases"
