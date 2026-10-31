---
name: incorporate-stack-repo
description: Bring a new or existing repo into a stack, end to end -- "add <repo> to the stack", "incorporate this repo", "wire up the new service", "register it with the primary", "what is left before this deploys". Settles which pattern the repo is from its own files (asking only when they do not settle it), scaffolds it from devtemplate when it is new, adds common/ and stack-common/, wires the pattern's pieces using the stack facts in stack-common/CLAUDE.md, then proves it by running the stack's registration check until nothing is MISSING. Ends with the check green, plus at most one BRIAN: issue carrying only the steps a session cannot do.
---

# incorporate-stack-repo -- from a bare repo to a registered member

The deliverable is **the stack's registration check reporting nothing MISSING**,
plus — only where something genuinely needs the operator — **one** `BRIAN:`
issue holding exactly those steps. A scaffolded directory is not a deliverable;
neither is a merged PR, because merging is not registering, and the check is the
only thing that can tell the difference.

**This skill is stack-neutral.** Every concrete fact — the primary repo, the
shared network, the registry, the endpoint variable names, which repo owns the
registration check — is read at run time from the consumer's
`stack-common/CLAUDE.md`. Pattern *definitions* are not restated here either;
read them in `common/docs/stack-patterns.md`. If you find yourself about to type
a host name, a service list, or an endpoint URL from memory, that is the signal
you skipped step 0.

## 0. Read the two sources before deciding anything

1. `common/docs/stack-patterns.md` — the definitions of P1–P14. Read **P2a,
   P2b, P2c, P3, P5, P6, P7, P8, P10, P11** before relying on any of them; the
   one-line index in `common/CLAUDE.md` is a pointer, not the definition.
2. The consumer's `stack-common/CLAUDE.md` — this stack's instances: which repo
   is the primary (P1), the shared network name, the image registry, the
   endpoint environment variables (P6), where DAGs are installed (P7), and the
   name of the registration check. **A repo with no `stack-common/` is not a
   stack member yet** — step 2 adds it, and until it is there you do not know
   enough to wire anything.

Then state in one line, before touching a file: the repo, the stack, the
pattern you believe it is, and the file that settled it.

## 1. Which pattern is it? Settle from the files first

Ask the repo, not the human. Run the reads, then match:

```
ls -a                      # dags/ dist/ schema/ seed/ src/ package.json
cat Dockerfile 2>/dev/null # base image + the CMD/ENTRYPOINT
grep -nE '^(VERSION|PROJECT_NAME|DEVTEMPLATE_VERSION)=' Makefile 2>/dev/null
grep -nE '^(build|up|run|test|psql|reset)\b' -r Makefile 2>/dev/null
```

| Evidence in the repo | Pattern it settles |
| --- | --- |
| Dockerfile whose CMD is a **long-running** process (a server, a scheduler, a worker that does not exit) | **P2a** full service |
| `package.json` with a build that emits `dist/`, and **no** Dockerfile | **P2b** static site |
| A **DB base image** plus `schema/*.sql` / `seed/`, Makefile verbs that are operational (`psql`, `reset`, `backup`) rather than `run`/`test` | **P2c** data service |
| `dags/` and **no** Dockerfile and nothing else deployable | **Airflow-only** |
| An importable package, no Dockerfile, no `dags/`, consumed by other repos as a pin | **library** |

**Say which file settled it** — "P2c: `Dockerfile` is `postgres:16-alpine` and
`schema/` holds the DDL" — and go to step 2.

**Only when the files do not settle it, ask.** The genuinely ambiguous cases,
and the question each one actually is:

- Dockerfile **and** `dags/`: is the container the service (P2a that also ships
  DAGs), or only a runtime the DAG tasks call into (Airflow-only)? Ask whether
  anything serves traffic.
- `package.json` **and** a Dockerfile: does the stack serve this from the
  primary's docroot (P2b) or from its own container behind the vhost (P2a)?
- An importable package **and** a Dockerfile: is the deliverable the pin
  (library) or the running container (P2a)?
- An empty or brand-new repo: nothing to read; ask.

Ask it as one question with the options above, each labelled by pattern. If the
session is unattended and cannot ask, choose the pattern the evidence most
supports, **write down the choice, the evidence, and what would reverse it**, and
continue — a recorded decision is the deliverable, never a stalled queue.

## 2. Scaffold (new repo), or confirm the scaffold (existing repo)

New repo → **P11**: clone `devtemplate`, rename the directory, then
`make init`. Do not hand-edit `PROJECT_NAME`/`CONTAINER_NAME`/`VERSION` in its
place — the "Template initialised" CI gate exists precisely because `make init`
gets skipped, and `tests/template-initialised.test.sh` encodes what it catches.
P2c and P1 repos are not cleanly scaffolded by `devtemplate` today; read P11 for
the sibling templates and expect to carry some of it by hand.

Existing repo → confirm rather than re-run: `make init` on a repo that already
has tags resets `VERSION` **backwards past a tag**.

Then **P3**, both tiers, in this order — `stack-common` nests `dev-common`, so
adding it alone leaves `common/` unhydrated:

```bash
GH_TOKEN="$(gh-app-token <org>)" git submodule add -b main <stack-common-url> stack-common
GH_TOKEN="$(gh-app-token <org>)" git submodule update --init --recursive
```

The mount path is always `stack-common/`, whatever the repo is named. Check
afterwards that the Makefile `-include`s both tiers' `make/*.mk` and that
`CLAUDE.md` `@`-includes `common/CLAUDE.md` and `stack-common/CLAUDE.md` —
`-include` is deliberate (it tolerates an unhydrated clone), so a missing
include is silent, not a build error.

## 3. Wire the pattern's pieces

Only the rows for the pattern from step 1. Every value in the right-hand column
comes from `stack-common/CLAUDE.md`, never from memory:

| Piece | P2a | P2b | P2c | Airflow-only | library |
| --- | --- | --- | --- | --- | --- |
| **P5** compose stub + `extends` in the primary | yes | no (docroot mount instead) | yes | only if it runs a container | no |
| **P6** endpoint env var, one per upstream | yes | no | yes (consumers get its DSN) | as a consumer | no |
| **P7** `dags/` + `dags-install` | if it has DAGs | no | no | yes | no |
| **P8** `VERSION=` in the Makefile, aggregated by the primary | yes | yes | yes | yes | yes |
| **P10** `ci-build` → registry → deploy | yes | overridden: build + rsync `dist/` | yes | per the stack | no, it ships as a pin |

Three things that are easy to half-do:

- **P5 is two edits, in two repos.** The member adds
  `docker-compose.stub.yml`; the **primary** adds the service with
  `extends`, on the stack's shared network. The member's half alone changes
  nothing — `docker compose config` in the primary is the read that proves it.
- **P6 names are consumed, not declared.** Adding the variable to the new
  service is half; every upstream/downstream that must reach it needs its own
  variable set too. Grep the primary's compose for the existing naming
  convention and follow it rather than inventing a name.
- **P8's level is a choice** (see P8, and `common/make/version.mk` for the
  targets): a new member is new backward-compatible capability for the
  primary — `make bump-minor` there. Never hand-edit a version string.

## 4. Prove it: run the stack's registration check

Nothing above counts until the check says so. `stack-common/CLAUDE.md` names
the check and the repo that owns it; by convention it is:

```bash
make stack-repo-check REPO=<org>/<name>
```

run from the repo that owns the stack's registration (the primary or the
stack's infra repo — `stack-common/CLAUDE.md` says which). It prints one line
per requirement, and **each MISSING line names the file to edit**. Work the
list top to bottom, re-running after each fix; do not infer that a fix landed.

Re-run until either nothing is MISSING, or the only MISSING lines are the
operator's — which is step 5. **Quote the final output** in the PR body. If the
check does not exist for this stack yet, say so plainly rather than declaring
the repo registered on your own reading; the absence of a check is a thing to
file, not to route around.

## 5. Split what is yours from what is his — then one issue

Apply the "is it his" test in `common/CLAUDE.md` verbatim. It is his **only**
when it needs root or physical access, a credential only he can create, money, a
fact only he holds, priority or strategy, or an irreversible outward-facing act.

Typically **his** when incorporating a repo:

- installing the GitHub App on a brand-new repo (it grants access);
- a repo secret or deploy key, and anything minting a credential;
- creating a DNS name, a certificate, or a host directory that must exist
  before the first deploy.

Typically **yours**, however weighty it feels: the pattern choice, the endpoint
variable's name, the version level, whether the member deploys on merge, which
of two wirings to use. Decide, record the reasoning and the trigger that would
reverse it, and continue.

Then, following `common/CLAUDE.md`'s handoff rules exactly: **one**
`BRIAN: <imperative>` issue, assigned to `brianholland`, action first, each
command carrying its host and account, idempotency stated at the top, a
"Success looks like" with real output, and nothing in it you have not run (or
marked `UNVERIFIED`). Link it as a **dependency**, not prose — the operator
issue **blocks** the engineering issue — and use `Refs #N`, not `Closes #N`, in
any PR whose work only lands once he has run his step.

If nothing on the list is his, **file no issue** and say so in the PR body.

## Done means

- [ ] The pattern is stated, with the file that settled it (or the recorded
      decision and its evidence).
- [ ] `common/` and `stack-common/` are present, hydrated recursively, included
      by the Makefile and by `CLAUDE.md`.
- [ ] Every row of step 3 for that pattern is either done or explicitly N/A.
- [ ] The registration check's own output, quoted, with no MISSING line that is
      not the operator's.
- [ ] At most one `BRIAN:` issue, linked as a blocker, or an explicit "nothing
      here is his".
