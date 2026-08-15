## Workflow
- Never commit directly to main. Always work on a feature branch.
- Before starting work, find or create a GitHub issue for the change.
- **Then check nobody is already on it**, in one command, before writing a line:

  ```bash
  gh pr list --repo <org>/<repo> --state open --search "<issue-number>"
  ```

  Work costs money whether or not it is merged. On 2026-08-14 five panoptikon
  issues were implemented twice — once by the headless agent at 14:18, once by
  the contractor session at 19:00 — because the second one never looked. Four of
  the duplicates were closed unmerged; the fifth turned out to be the better
  implementation and had to be ported back (panoptikon#732). Every token of that
  was spent twice and refunded never.
- **`agent-pr` on an issue means it is handed over.** A session that applies the
  label has delegated the work and must not then do it itself; a session that
  finds the label on an issue it is about to start should check for the agent's
  PR first and review that instead of starting again.
- Branch naming: `<issue-number>-<short-description>` (e.g., `42-fix-login-bug`).
- Create the branch from main, do the work, commit to the branch.
- When done, create a PR that links the issue (e.g., `Closes #42`).

## Git Commits
Use conventional commit style.

Example: `fix: resolve null pointer in data loader`

## Pull Requests
Use a concise, descriptive title.

Example: `feat: add user authentication`

## Check `ARCHITECT-INBOX.md` at session start

If the repo root has an `ARCHITECT-INBOX.md`, **read it before doing anything
else.** It is how the architect session passes context to this one: what
changed elsewhere that affects your work, what a review concluded, what not to
start because it is about to be superseded.

It is **gitignored**, so it will not appear in `git status` and nothing will
prompt you. That is why this line exists.

Two conventions:

- **Reply in the same file** when asked to. Append; do not rewrite someone
  else's section.
- **But do not expect the reply to be seen on its own.** NOTHING monitors this
  file, or GitHub, on the architect's behalf. There is no background process:
  an architect session exists only while Brian is running one, and it sees an
  answer only if it happens to look. If the reply matters, **also put it on the
  GitHub issue or PR** — that is the record, it survives every session, and it
  is where a sweep will find it.
- The inbox is a push channel between two **running** sessions. It is invisible
  to the headless agent and to claude.ai/code sessions, and it notifies nobody.

  It **does** survive a container rebuild, and this line used to say it did not.
  `/workspaces/<repo>` is a bind mount of the host checkout — on twix,
  `/dev/nvme0n1p2[/home/brian/dev/stack-home-site/<repo>]`, confirmed with
  `findmnt` on 2026-08-15. The file is the host's; the container is the
  disposable part. Believing otherwise, a session tells Brian his notes are
  about to be lost and hurries to mirror them somewhere — which is wrong twice,
  because the reason to put the important half on GitHub is that **nothing reads
  this file**, not that it is fragile.

  Same failure as the read-only claim in home-stack-common: a wrong line in a
  file that loads into every session in the stack travels, and the correction
  has to be written down rather than remembered.

Delete a section once actioned. A stale inbox is worse than none — it gets
skimmed, and then the next real message is skimmed too.

## Referring to issues and PRs

**Every issue or PR number in text the user reads is a hyperlink, and says which
it is.** Never a bare `#441`, and never a bare `hog#441`.

```markdown
PR [hog#441](https://github.com/finzeug/hog/pull/441)
issue [slingshot#138](https://github.com/finzeug/slingshot/issues/138)
```

Two separate requirements, and both are needed:

1. **A link.** Brian reads in a terminal, where markdown links are clickable. A
   bare number costs him a manual lookup every single time.
2. **The word "PR" or "issue" beside it.** Issues and PRs share one number
   space, so `hog#441` cannot say which it is, and the rendered link text hides
   the `/pull/` vs `/issues/` that would have told him. Grouping works too
   ("PRs merged: ...", "Issues: ...").

Org for the URL, from the repo's `origin`: `bdh-org` (home-infra, home-site,
dev-common, devtemplate, brief, roy), `finzeug` (hog, oleo, canary, heller,
panoptikon, refdims, ratecraft, ferret, freddyb, slingshot, ledger-io).

This is here rather than in a memory note because it kept regressing when it was
only a note. Brian has asked for it repeatedly.

## GitHub Authentication
The devcontainer has **no ambient `gh` auth** — this is deliberate, not a
misconfiguration. `GITHUB_TOKEN` is intentionally empty and `gh`'s
`config.yml` carries no auth state, so a bare `gh ...` or `gh auth status`
fails. Do NOT run `gh auth login` to "fix" this.

Instead, authenticate **per command** with the org-scoped fine-grained PAT
that matches the repo's GitHub org. Tokens live at
`~/.config/ai/claude/credentials/`:

| Token file | GitHub org | Used by |
| --- | --- | --- |
| `gh-bdh-org.token` | `bdh-org` | home-site, dev-common, devtemplate, actions-runner, brief, roy |
| `gh-finzeug.token` | `finzeug` | hog, oleo, canary, heller, panoptikon, refdims, ratecraft, ferret, freddyb |

Pick the token from the repo's origin org
(`git remote get-url origin`), then prefix the command:

```bash
GH_TOKEN="$(cat ~/.config/ai/claude/credentials/gh-bdh-org.token)" gh pr create ...
```

The same applies to `git push` over HTTPS and any other `gh`/API call that
writes. These PATs authenticate as the `bdh-ai` service account; the
ambient git identity (a personal token) must not be used for automated
writes.

## Saying which devcontainer you are

Vocabulary, because these get conflated: a **devcontainer** is the environment
(one per repo); a **session** is one running Claude Code conversation inside
one; a **role** is what that session acts as -- **architect** or
**contractor**. The role follows the devcontainer, so naming the devcontainer
names the role.

Every session authenticates as the same `bdh-ai` account, so nothing GitHub
records distinguishes them: an issue filed from any devcontainer reads
`login: bdh-ai`, `type: User`, `performed_via_github_app: null`. Two
mechanisms close that gap, one automatic and one yours to remember.

**Commits and PRs — automatic, nothing to do.** `setup-claude-identity.sh`
writes a container-local `~/.gitconfig-role` setting `user.name` to
`bdh-ai (architect)` or `bdh-ai (contractor/<repo>)`, derived from
`PROJECT_NAME`. Only the display name varies; `user.email` stays `bdh-ai`
everywhere.

**Never set `user.name` or `user.email` in a repo's `.git/config`.** Repo
checkouts are bind-mounted from the host, so a repo-local override is
shared with the human's own shell -- which is how two repos ended up
attributing container commits to a person (bdh-org/home-infra#317). If a
role name looks wrong, fix `~/.gitconfig-role`, never the repo.

**Issues and issue comments — add a footer**, since these never touch git:

```markdown
<sub>filed from the <repo> devcontainer</sub>
```

Use the repo whose devcontainer you are running in, which is the directory
your `CLAUDE.md` was loaded from -- not the repo the issue is filed against.
They differ often: cross-repo work is normal from the architect workspace.

## Every command you hand over names its machine and its account

Brian runs about seven machines, with several accounts on each. A command
without a location is not actionable, so **say which host and which user id, in
the same breath as the command** — never leave it to be inferred from what was
being discussed.

```
On Minerva, as brian:

    sudo chown --reference=/srv/svc-prod/refdims-data/PG_VERSION /srv/svc-prod/refdims-data
```

For a multi-step sequence, put host and account beside **each** step rather than
once at the top: steps get copied one at a time, and the header does not travel
with them. Where a command internally switches account — `sudo machinectl shell
svc-prod@ ...`, `sudo -u ...`, an `ssh` inside a make target — say both which
account the human types it as and which one it ends up running as.

The rule extends to make targets, which are the easiest thing to get wrong: a
`prod-*` target usually runs on a DEV host and ssh's *into* prod, so "run `make
prod-bootstrap`" is ambiguous exactly where it matters. Name the host you invoke
it from and the checkout you invoke it in.

**When you do not know which host something belongs on, ask.** The assumption
has been wrong more often than right, and the failures are not cheap: a
`prod-bootstrap` recommended without saying it runs from a dev host was run on
prod, where it chowned what the Makefile still believed was the live Postgres
data directory (bdh-org/dev-common#159, finzeug/refdims#177).

## Package Management
- Install packages with `conda` (conda-forge) into the dev environment when possible.
- Use `pip` only as a fallback when a package is not available on conda-forge.
- Flag potential conflicts when mixing pip and conda in the same environment.

## Stack Architecture Patterns

These are generic pattern *definitions* — the shared vocabulary for how a stack
built on this tooling is wired. Each stack's concrete instances (primary repo,
service names, shared network, hosts) live in that stack's
`stack-common/CLAUDE.md`, included alongside this file.

### P1: Primary repo
Primary/edge repo for a stack. Two hats:
- **Orchestrator**: owns `docker-compose.yml`, is the entry point for
  `prod-deploy-all`, and aggregates service versions at build time (P8).
- **Web edge**: ships an Apache container (its own `Dockerfile`) that
  serves static HTML, mounts P2b static sites into its docroot, and
  reverse-proxies P2a services via vhost config.

Has no Python application code of its own, so it does NOT use the shared
Python CI workflow (`common/.github/workflows/ci.yml`) — ruff + pytest
don't apply. A P1-shaped CI (compose config validation, vhost syntax
checks, hadolint) is optional and bespoke. See stack-common for this
stack's primary repo.

### P2a: Full service
Long-running container (API, dashboard) with its own Dockerfile, served via
Apache vhost proxy. See stack-common for this stack's services.

### P2b: Static site
Built frontend assets (no container of its own). The primary repo's
Apache container mounts the build output into its docroot via
`docker-compose.yml` (e.g. `../<site>/dist:/usr/local/apache2/<site>:ro`).
See stack-common for this stack's static sites.

### P2c: Data service
Postgres (or similar DB) container whose primary deliverable is
**schema + seed data**, not application code. Shape:
- Base image is a DB image (e.g. `postgres:16-alpine`), not Python.
- `schema/*.sql` and `seed/` copied into `docker-entrypoint-initdb.d/`.
- Makefile targets are operational (`build/up/down/reset/psql/logs/
  backup/restore`), not `run/test`.
- CI is bespoke: build the image, wait for seed, run shell tests
  against the running container — the shared Python CI workflow
  doesn't apply.
- No `conda-packages.txt`, `ruff.toml`, `requirements-prod.txt`, or
  `src/` tree. Devcontainer uses a non-Python base image with
  `docker-outside-of-docker` so the dev can build and run the service.

P2c repos are not currently scaffolded from `devtemplate` cleanly — see
`brianholland/devtemplate#15` for the `devtemplate-db` sibling template
that will. Until that exists, P2c repos don't track
`DEVTEMPLATE_VERSION`. See stack-common for this stack's data services.

### P3: Submodule hierarchy
Two-tier shared infrastructure via git submodules:
- `common/` (dev-common) — dev tooling used by all projects across every
  stack: version.mk, python.mk, utils.mk, devcontainer.mk, devcontainer
  setup scripts (incl. generic `claude-prod` / `claude-dev` shims that read
  host config from env), and shared Claude Code skills (P14).
- `stack-common/` — stack-specific: deploy.mk, airflow.mk,
  `devcontainer/setup-stack-hosts.sh` (writes a `/etc/profile.d` entry setting
  CLAUDE_PROD_HOST / CLAUDE_DEV_HOST and any other stack-specific env), and the
  stack's `CLAUDE.md`. Has dev-common as a nested submodule.

All repos include both with `-include` (tolerates missing submodules on fresh
clone). A repo's `CLAUDE.md` likewise includes `@common/CLAUDE.md` and, when
present, `@stack-common/CLAUDE.md`. By convention the stack-common repo is
named `<stack>-stack-common` (e.g. `fra-stack-common`); the mount path is
always `stack-common/`, so member wiring never depends on the repo name.

### P4: Conda-dev / pip-prod dependency split
Development and production use different package managers:
- **Dev**: `conda-packages.txt` installed via conda in the devcontainer.
- **Prod**: `requirements-prod.txt` installed via pip in the Dockerfile.
- **Bridge**: `make requirements` (python.mk) generates `requirements-prod.txt`
  by scanning imports and pinning to versions from the active conda environment.

Never delete one thinking it duplicates the other — they serve different purposes.

### P5: Service composition via extends
The primary repo's `docker-compose.yml` uses `extends` to pull service
definitions from stub files in each service's directory
(e.g. `./<svc>/docker-compose.stub.yml`). All services join the stack's
shared bridge network (named in stack-common).

### P6: Service discovery
Services find each other by container name on the stack's shared Docker
network. Environment variables pass these URLs to services that need them
(one endpoint var per upstream). See stack-common for the network name and
concrete service endpoints.

### P7: DAG management
DAGs live in each service's `dags/` directory. `make dags-install` (airflow.mk)
copies them to the central Airflow DAGs directory. `make dags-reserialize`
triggers Airflow to reload. `prod-deploy-all` runs both for every service that
has a `dags/` directory. Services with DAGs typically also have a Dockerfile
for the container that DAG tasks call into.

### P8: Version propagation
Each repo has `VERSION=x.y.z` in its Makefile. The primary repo extracts
service versions at build time and exports them as environment variables for
docker-compose image tagging. `make bump-patch` increments and auto-commits.
The `tag-version.yml` workflow (reusable from dev-common) creates git tags
on push to main.

One known failure: if a commit touching `.github/workflows/` lands on main
next to a bump merge, the tag push is rejected ("without `workflows`
permission") because GitHub checks a new ref's workflow files against the
default branch. `GITHUB_TOKEN` can never hold `workflows`, so re-running does
not help — push the tag by hand with a PAT pointing at the bump commit. The
tag step prints this remediation itself; see dev-common's README
(bdh-org/dev-common#122).

### P9: Devcontainer setup chain
Four sequential steps initialize the development environment:
1. `init-host.sh` — runs on HOST: creates credential dirs, extracts macOS
   Keychain tokens.
2. `setup-base.sh` — installs Miniforge, tmux, shell config, git aliases.
3. `setup-python-dev.sh` — conda dev tools (ruff, pytest, jupyter) + project
   packages from `conda-packages.txt`.
4. `setup-claude.sh` — Claude Code CLI + shared skills (P14).
5. `setup-waterbrother.sh` — waterbrother CLI (optional; projects that
   don't need it simply don't source this script).

Repos without a Python environment skip step 3:
- P1 — orchestrator + Apache, no Python app code.
- P2c — DB service, no Python env in the container.

### P10: Production deployment (runner-on-merge)
Merging to main IS the production deploy. The repo's `ci-build` workflow
(self-hosted runner) builds a SHA-tagged image, pushes it to the stack's
registry, and triggers the deploy wrapper on the prod host
(`ssh deploy@<host> "<svc> <sha>"`), which runs the stack's deploy script
as the scoped prod service user: pull the image, restart the container,
deliver the image-baked `dags/` (P7).

`make prod-deploy` (stack deploy.mk) is a thin force-redeploy escape
hatch — it re-triggers `ci-build` via `gh workflow run`, normally
unnecessary. The primary repo's `prod-deploy-all` loops it over every
service (fleet bring-up / DR); P2b static sites override `prod-deploy`
to host-build and rsync their `dist/` instead of riding the runner.

`dev-deploy-all` is the manually driven parallel for the dev tier; see
P12. Its git operations use `git_retry` (make define/call macro) — 5
attempts with 10s backoff to handle transient DNS failures (Tailscale
MagicDNS).

### P11: Project scaffolding (devtemplate)
New repos are created by cloning `devtemplate`, which embeds the standard
patterns: dev-common submodule, conda-packages.txt, ruff.toml, devcontainer
setup chain, Makefile includes. Run `make init` after renaming the directory
to finalize the scaffold.

For Postgres-backed data services (P2c), use the future `devtemplate-db`
sibling template instead — see `brianholland/devtemplate#15`. Future
`devtemplate-primary` (P1) and `devtemplate-stack-common` siblings are
tracked at `brianholland/devtemplate#24` and `#25`.

### P12: Dev tier on a parallel host
A pre-prod environment that mirrors prod's service set on a separate
host (typically the host that runs the developer's devcontainer).
Validates cross-service wiring before promoting to prod.

Shape, parallel to P10:
- `dev-deploy-all` SSHes to `$(DEV_SERVER)` (default set by the stack, overridable),
  runs `dev-bootstrap && dev-up` on that host.
- `dev-bootstrap` is idempotent: copies missing per-service `.env` from
  `.env.example`, seeds host-local data files (e.g. hog's tensor.duckdb)
  for things that can't ride the live NFS mount because of file locks.
- `dev-up` runs `docker compose up -d --build` *without* `--profile airflow`,
  so airflow services are skipped at parse time. (Prod's `up` passes
  `--profile airflow` to bring them up.)
- DAG installation is omitted on dev (no Airflow). Cross-service writes
  driven by DAGs propagate from prod into dev "for free" through the
  shared NFS mount of prod data.

Apache vhost on the dev host accepts both prod and dev ServerAlias entries —
same image runs on both hosts; only the hostname differs. See stack-common
for the concrete host names and DNS suffixes.

### P13: Scoped Claude Code identities
Each tier has a constrained `claude` SSH user — `claude-prod` on prod,
`claude-dev` on dev — with:
- Verb-allowlisted SSH wrapper (`/usr/local/bin/claude-prod` /
  `claude-dev`), forced via `command="..."` in `authorized_keys`.
- POSIX ACL grant for read-only access to a data path (or, on NFS clients
  reading server-side ACLs, group membership with the matching numeric GID).
- Sudoers entry for a specific docker-helper script that runs as root and
  re-validates inputs.

Devcontainer shims at `/usr/local/bin/claude-{prod,dev}` (installed by
`setup-claude.sh`) are host-portable: they SSH to whatever host the env
vars `CLAUDE_PROD_HOST` / `CLAUDE_DEV_HOST` name. stack-common's
`setup-stack-hosts.sh` writes those env vars at `/etc/profile.d` so they
survive devcontainer rebuilds.

Source for the wrappers + install docs lives in the stack's **infra/architect**
repo at `claude-access/` — not the primary repo. These are host-provisioning
scripts: they install to `/usr/local/bin` and `/etc` on the prod host as root,
and a primary repo neither builds nor ships them, so carrying them there puts
undeployed root-installed code inside a deployable service. The infra repo is
also where the rest of the host provisioning lives, including the ACL grant for
the reader these wrappers authenticate.

One consequence to plan for: the infra repo is typically NOT synced to the prod
host (being non-operational, it is not one of the deployed siblings), so the
install cannot read from a checkout there. Deliver by push-rsync from the dev
host instead — stage unprivileged, install as root, remove the staging dir.

### P14: Shared Claude Code skills
Reusable Claude Code skills live in `dev-common/skills/<name>/SKILL.md`
(version-controlled, one source of truth). `setup-claude.sh` exposes each as a
**project-level** skill via a per-repo *relative* symlink
(`<repo>/.claude/skills/<name>` -> `../../common/skills/<name>`), so they are
available in every repo's Claude Code session, live-update through
`update-common` (the submodule bump — no copy, no rebuild), and never collide
across containers that share one host `~/.claude`. (They are deliberately NOT
symlinked into `~/.claude/skills/`: that dir is bind-mounted from the host into
every container, so workspace-absolute links there are last-writer-wins and
dangle in all but the most-recently-set-up container.) Current skills: `ship` (end-to-end
issue -> PR -> squash-merge -> cleanup), `update-common` (bump the dev-common
submodule across repos), `incorporate-devtemplate` (diff repos against
devtemplate, file issues), `verification-discipline` (write checks and tests
that ask the data what it holds rather than asserting what it ought to),
`watch` (cheap exit-early polling for `/loop` ticks — pinned to a small model
via `model:` frontmatter, one probe per tick, escalates to a summary only when
the watched thing goes red). `make incorporate-devtemplate` is a signpost that
points at the skill — the work needs human judgment, so there is no
fully-automated target.
