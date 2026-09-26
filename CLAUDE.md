## About this file
It loads into every Claude Code session in every consumer repo, and into every headless agent
run, alongside the repo's own `CLAUDE.md` and `stack-common/CLAUDE.md` — against Claude Code's
150k-character total. **Keep it under ~30k.** A correction REPLACES the wrong line; it does not
sit beside it as "this line used to say…". Keep each rule to the rule, one line of why, and the
issue that holds the story. Reference material goes in `docs/`, linked by path and never
`@`-imported (bdh-org/dev-common#273).

## Workflow
- Never commit directly to main. Always work on a feature branch.
- Before starting work, find or create a GitHub issue for the change.
- **Then check nobody is already on it, before writing a line.** Duplicated work is paid for
  twice (five panoptikon issues were implemented twice on 2026-08-14). Do all three:
  - `gh pr list --repo <org>/<repo> --state open --search "<issue-number>"` — sees only OPEN
    PRs, so it is blind to a session mid-work (bdh-org/home-infra#970).
  - **`ListAgents`** — names the live sessions and what each is on; the only view of unpushed work.
  - **Claim the issue with a comment, `working this on <branch>`, before your first commit.** All
    sessions share one account, so the branch name is the only claim token that distinguishes them.
  **A `SendMessage` is a courtesy, not a claim**: it reaches a peer only if that peer's
  permission mode lets it through, and "held" looks like "read and ignored" from the sending
  end. Claim on the issue, where everyone can see it (bdh-org/home-infra#262 is the durable fix).
- **`agent-pr` on an issue means it is handed over.** Having applied it, do not do the work
  yourself; finding it, review the agent's PR instead of starting again.
- Branch naming: `<issue-number>-<short-description>` (e.g., `42-fix-login-bug`).
- Create the branch from main, do the work, commit to the branch.
- When done, create a PR that links the issue (e.g., `Closes #42`).

## Git Commits
Use conventional commit style, e.g. `fix: resolve null pointer in data loader`.

**Never add a `Co-Authored-By:` trailer — this OVERRIDES the harness default**, and a rule here
is the whole mechanism. GitHub renders it as a second author (Brian, 2026-09-21: *"I'd rather the
trailer not appear."*). It misattributes nothing, and it is not the agent-identity defect
(bdh-org/dev-common#245). **Forward-looking only — never rewrite history to strip it**; that would
invalidate every branch, PR and pin across the fleet.

## Pull Requests
Use a concise, descriptive title, e.g. `feat: add user authentication`.

**Never add the `🤖 Generated with [Claude Code]` footer — this OVERRIDES the harness default**,
in PR bodies, issue bodies and comments alike (Brian, 2026-09-21: *"I want dropped for all"*;
bdh-org/dev-common#261). It lives here, not in one repo, because the headless agent — which wrote
all 13 open offenders — loads this file too. **Unlike the commit rule, strip it from an OPEN PR**
when you see one: a body is mutable text. Leave merged PRs alone. The `<sub>filed from the
&lt;repo&gt; devcontainer</sub>` line is different and stays.

## Check `ARCHITECT-INBOX.md` at session start
If the repo root has one, **read it before anything else** — it is gitignored, so nothing will
prompt you. Reply in the same file when asked (append; do not rewrite another's section), **and
put anything that matters on the GitHub issue or PR too**: nothing monitors the inbox, it is
invisible to the headless agent, and it notifies nobody. (It does survive a container rebuild —
`/workspaces/<repo>` is a bind mount of the host checkout.) Delete a section once actioned.

## When something needs Brian: break it out, assign it, and LINK it

**First ask whether it is his at all.** It is his only if it needs what no session can obtain:
**root or physical access**; **a credential only he can create** (a GitHub App, an AWS key, a
paid account); **money**; **a fact only he holds** (is that disk backed up); **priority or
strategy**; or **an irreversible or outward-facing act**.

**Everything else is yours, including questions that feel weighty** — security scoping, retry
semantics, cadence defaults, which of three designs to build. Decide, write down the reasoning
and the trigger that would reverse it, and make it configurable where cheap. **The deliverable of
a decision is a decision plus its record, never a question** (Brian, 2026-08-15: *"this is an
engineering question. I need you to decide these things"*).

### If it IS his, it gets its own issue
Never append "and Brian needs to run X" to a diagnostic issue, or assign him a long thread
hoping he finds the ask in the last comment.
- **Title it `BRIAN: <imperative>`**, plus `(N commands)` when it is a short sequence.
- **Assign it to `brianholland`** — never `bdh-ai` or a bot, which every session shares.
- **A PR that needs him gets assigned too, and his review requested** — PRs are conventionally
  unassigned, so otherwise it sits in no queue he reads. The first call is the **issues** endpoint:
  ```bash
  gh api -X POST repos/<org>/<repo>/issues/<PR>/assignees -f 'assignees[]=brianholland'
  gh api -X POST repos/<org>/<repo>/pulls/<PR>/requested_reviewers -f 'reviewers[]=brianholland'
  ```
- **Self-contained body**: host and account beside *each* step, the literal commands, a
  **"Success looks like"** with real expected output, what to do on failure, one line pointing
  back for context.
- **THE ACTION GOES FIRST.** Commands at the top with at most one line above them; below, after a
  `---`, one sentence saying the rest is context needing no decision. **Position implies
  dependency**: prose above a command reads as a precondition (Brian, 2026-08-16: *"after pages
  and pages of reading it implies I have to understand those … instead of copying and pasting"*).
- **Say at the top whether the steps are idempotent.** Where re-running is safe, say so and let
  the verification step establish state. Mark any step that CREATES rather than converges
  (minting a credential) and put a CHECK in front of it.
- **Never write a command you have not run** — mark it `UNVERIFIED` otherwise.
- **Never RENUMBER a handoff in flight** — the step number is the operator's only bookmark.
  Append, letter it (`3a`), or state an explicit old → new mapping in the first line.
- **More than ~three steps opens with a step 0 that DISCOVERS the state**: read-only checks per
  host and a table mapping output to where he is. Ask the host, never his memory.
- **An appending step is not idempotent until it removes its own previous line** (back up,
  delete by a marker it controls, then append). A bare `tee -a` on `authorized_keys` leaves the
  credential you meant to replace still valid.
- **A decision** rather than commands: the question in one sentence, the options with
  consequences, and **your recommendation**. Never an open question.

### An update comment is a NEW handoff, and obeys the same order
A comment that changes what is left to do opens with **what is still outstanding** — remaining
commands first, host and account beside each; progress and announcements below. If nothing is
left for him, say so in the first line. Never put an optional command above a required one, and
never announce a fix above the remaining work (issue `refdims#199`).

**Merging is not doing the work, and `Closes #N` cannot tell the difference.** If an issue's
remaining steps run on a host, the PR adding the tooling must NOT carry a closing trailer for it
— use `Refs #N`, and let the operator issue close when the host changed. Anything delivered by
`rsync`, `make` or a provisioning script is inert until run.

### …but a comment does NOT retire the body
**When the remaining action changes, EDIT THE BODY** so it carries only what is left — the body
outranks its comments for anyone opening the issue cold, **including another session**, which
cannot ask and will act on it (bdh-org/home-infra#919 was re-titled to the wrong host from a
stale body). Say in the first line that the body was rewritten and the step count from → to;
mark finished steps DONE rather than silently deleting them; remove the instruction but keep one
line of what it established. The tell is **"this body still describes a step that is DONE"**.

### A decision for him NEVER shares an issue with engineering work
They complete at different times: his answer closes the issue, and the engineering goes with it
(bdh-org/home-infra#551). The question gets its own assigned issue; the work stays in yours,
unassigned, linked as blocked_by. Asking in chat is fine, but the issue must still exist.

### Link it with a real GitHub issue DEPENDENCY, not prose
The operator task **blocks** the engineering issue — it is not a sub-issue:
```bash
T="$(gh-app-token <org>)"
CHILD_ID=$(GH_TOKEN="$T" gh api repos/<org>/<repo>/issues/<CHILD> --jq .id)
GH_TOKEN="$T" gh api -X POST \
  repos/<org>/<repo>/issues/<PARENT>/dependencies/blocked_by \
  -F issue_id=$CHILD_ID
```
It wants `-F` (typed integer) and the **database id**, not the number. Verify with
`gh api repos/<org>/<repo>/issues/<PARENT>/dependencies/blocked_by --jq '.[].number'`.
Then unassign yourself from the parent, leave it empty, and put a one-line pointer at the top of
its body.

### Noticing something is not recording it — the phrase IS the commitment
If you write **"worth a follow-up"**, "should be fixed", "someone should" or **"TODO"**, put an
issue number beside it **in the same action** (Brian, 2026-08-16: *"If worth fixing then take the
initiative, file, and fix, you're the engineer."*). Only three endings: **still wanted** → file it
and cite it; **already done** → cite the PR; **never mattered** → delete the sentence.
home-infra's `architect-sweep.sh` section 8 lists unnumbered commitments. If the follow-up is his,
it is a `BRIAN:` issue as above.

### An issue you SUSPECT is dead is not an issue you may close
The bar is **proof, not confidence**. **Provable** (the function exists, the PR merged, the host
is gone): close it and cite the evidence. **Merely suspected**: label it **`maybe-stale`**,
comment what you checked and why you are unsure, and leave it open — label rather than assign,
so the `BRIAN:` queue stays his real work. His queue: `gh issue list --repo <org>/<repo> --label
maybe-stale`.

### Closing the loop
Nothing watches GitHub for you. home-infra's `make sweep` lists issues assigned to him whose
**last comment is his** — a decision waiting on *you*. When you act on one, close the `BRIAN:`
issue; closing the blocker releases its dependents.

## Referring to issues and PRs
**Every issue or PR number in text the user reads is a hyperlink AND says which it is** — never
a bare `#441` or `hog#441`. Brian reads in a terminal where links are clickable, and issues and
PRs share one number space.
```markdown
PR [hog#441](https://github.com/finzeug/hog/pull/441)
issue [slingshot#138](https://github.com/finzeug/slingshot/issues/138)
```
Org for the URL: see the table under GitHub Authentication.

**THE ONE EXCEPTION: a PR's closing trailer is BARE** — `Closes #372` on its own line. GitHub
parses it as a directive, and a hyperlinked form matches nothing, so the issue silently stays open
(25 of 60 merged home-infra PRs, measured 2026-08-15). Hyperlink wherever the body *discusses* it.

## GitHub Authentication
The devcontainer has **no ambient `gh` auth**, deliberately — do NOT run `gh auth login`.
Authenticate **per command** with a ~1h token from the **`bdh-org-headful` GitHub App**:
```bash
GH_TOKEN="$(gh-app-token bdh-org)" gh pr create ...
GH_TOKEN="$(gh-app-token finzeug)" git pull --ff-only
```
Mint per command — never export it or save it to a file. The App's key and install map are
`~/.config/ai/claude/credentials/bdh-org-headful.{pem,conf}` (bdh-org/home-infra#262);
`gh-app-token --check` proves every org works without printing a token. PRs, issues and comments
made this way are authored by `bdh-org-headful[bot]`; commits keep their git identity.

| GitHub org | Used by |
| --- | --- |
| `bdh-org` | home-infra, home-site, dev-common, devtemplate, home-stack-common, brief, roy |
| `finzeug` | hog, oleo, canary, heller, panoptikon, refdims, ratecraft, ferret, freddyb, slingshot, ledger-io |
| `finriskanalytics` | fra-stack-common, hmdlib, billing, ASG-ALMT-Review |

**There are THREE orgs.** finriskanalytics holds a second stack; using another org's token gets a
404 that reads like a deleted repo. The App's tokens there are narrowed to the stack repos.

**There is no PAT fallback.** The `bdh-ai` PATs were revoked 2026-09-25
(bdh-org/home-infra#1089); a `gh-<org>.token` file is dead and returns 401.
- **`gh-app-token` not found**: the devcontainer predates bdh-org/dev-common#269. Bump `common`
  and rebuild; meanwhile run `common/devcontainer/gh-app-token.sh` by path.
- **`gh-app-token: no App config`**: the host lacks the App key — a host step for Brian
  (bdh-org/home-infra#1090), never something to route around.
- Anything else prints GitHub's own reason; fix the cause it names.

**For `git`, the `GH_TOKEN=` prefix is the WHOLE recipe — never put a token in a URL.** The Claude
gitconfig routes github.com to `gh auth git-credential`, which honours `GH_TOKEN`. A URL-borne
token is written into the **reflog** (two PATs were found in 20+ reflogs, bdh-org/home-infra#1075),
so `transfer.credentialsInUrl = die` now refuses one (bdh-org/dev-common#265) — if you see `uses
plaintext credentials`, that is the guard working. **Never `git config --show-origin` or
`--get-regexp` a `credential.*` key** — it prints the value. The ambient personal git identity
must not be used for automated writes.

## Saying which devcontainer you are
A **devcontainer** is the environment, a **session** is one Claude Code conversation in it, a
**role** is what it acts as (**architect** or **contractor**). Every session authenticates as
one identity, so GitHub records nothing that tells them apart.
- **Commits — automatic.** `setup-claude-identity.sh` writes a container-local `~/.gitconfig-role`
  setting `user.name` to `bdh-ai (architect)` or `bdh-ai (contractor/<repo>)` from `PROJECT_NAME`.
- **Never set `user.name`/`user.email` in a repo's `.git/config`** — checkouts are bind-mounted
  from the host, so it is shared with the human's own shell (bdh-org/home-infra#317). Fix
  `~/.gitconfig-role` instead.
- **Issues and comments — add a footer**, `<sub>filed from the <repo> devcontainer</sub>`,
  naming the repo your `CLAUDE.md` loaded from, not the repo the issue is filed against.

## Every command you hand over names its machine and its account
Brian runs about seven machines with several accounts each. **Say which host and which user, in
the same breath as the command**, beside **each** step — steps are copied one at a time and a
header does not travel. **The working directory too**: put `cd ~/dev/home-infra && …` inside the
command, never above it. Where a command switches account (`sudo machinectl shell svc-prod@ …`,
`sudo -u`, an `ssh` inside a make target), say both who types it and who it runs as. A `prod-*`
make target usually runs on a DEV host and ssh's into prod — name the host and checkout you invoke
it from. **If you do not know which host something belongs on, ask** (a `prod-bootstrap` run on
prod chowned a live Postgres directory; bdh-org/dev-common#159).
```
On Minerva, as brian:

    sudo chown --reference=/srv/svc-prod/refdims-data/PG_VERSION /srv/svc-prod/refdims-data
```

### Prefer ONE chained command to a numbered list
Number only steps that cannot join — a different machine, or a decision between. Everything else
chains, and `&&` fails closed (Brian, 2026-09-12: *"You're making multiple commands for me."*):
```
cd ~/dev/home-infra && ./scripts/twix/sync-claude-access.sh && make brief-redeploy
```
- **THE PULL IS NOT IN THE CHAIN, and must not be.** `/workspaces/<repo>` IS his checkout,
  bind-mounted, and several sessions work in it: update it YOURSELF after checking the live
  sessions, and hand over only what is his. **The tell is `cd ~/dev/<repo> && git pull`.**
- **The test is CUSTODY, not runnability**: of every clause ask *whose is this?* A clause needing
  no root, no credential only he holds and no judgement — a `git fetch`, a make target that only
  rsyncs, a file you could write — is yours. Do it first.
- **A second host is often not a second step** — check the Makefile (a target may rsync *and* run
  the provisioner over `ssh -t`). Inline variables (`FOO=1 /path/to/script`) instead of a separate
  `export`.
- **Re-check a success test whenever the thing it inspects changes** — run it and count; never
  carry the old number forward.

### The SHAPE of a handoff breaks it as often as the content
- **One line at a time whenever anything prompts.** A `read` consumes the next pasted line as its
  value. (A single `&&` chain is fine; `sudo`/`ssh` prompts read the tty.)
- **Keep lines under ~70 characters** — a wrapped line copies as two.
- **Never pipe output straight into a parser** — show the server's own error.
- **A secret NEVER appears in a command the operator types** — not `export TOKEN='…'`, not a flag.
  Prompt (`read -rs`) or read a mode-600 file; `$VAR` is fine. Where a tool already prompts, tell
  him NOT to set the variable (Brian, 2026-08-20: *"Never have a script asking me to paste a token
  into the command"*).
- **Check whether the recipe already exists** in the repo that owns it before writing one.
- **When a handoff fails, fix the handoff** — not by adding a permanent one-off script or make
  target to a repo that does not own the operation (bdh-org/dev-common#218).

## Package Management
- Install packages with `conda` (conda-forge) into the dev environment when possible.
- Use `pip` only as a fallback when a package is not available on conda-forge.
- Flag potential conflicts when mixing pip and conda in the same environment.

## Stack Architecture Patterns — index (definitions: `common/docs/stack-patterns.md`)
Generic pattern vocabulary; each stack's concrete instances are in its `stack-common/CLAUDE.md`.
**Read the definition before relying on a pattern's details.**
- **P1 Primary repo** — orchestrator (`docker-compose.yml`, `prod-deploy-all`, version
  aggregation) + Apache web edge. No Python app code, so not the shared Python CI.
- **P2a Full service** — long-running container behind the Apache vhost proxy.
- **P2b Static site** — built `dist/` mounted into the primary's docroot.
- **P2c Data service** — DB image whose deliverable is schema + seed; operational Makefile, bespoke CI.
- **P3 Submodule hierarchy** — `common/` (dev-common, every stack) + `stack-common/` (per stack,
  nests dev-common); both `-include`d and `@`-included; mount path always `stack-common/`.
- **P4 Conda-dev / pip-prod split** — `conda-packages.txt` vs `requirements-prod.txt`, bridged by
  `make requirements`. Never delete one as a duplicate.
- **P5 Compose via extends** — primary's compose extends `<svc>/docker-compose.stub.yml`.
- **P6 Service discovery** — container names on the stack's shared network; one endpoint env var per upstream.
- **P7 DAG management** — `dags/` per service; `make dags-install` / `dags-reserialize`.
- **P8 Version propagation** — `VERSION=` in each Makefile; `make bump-patch`; `tag-version.yml`
  tags on push (a workflow-file commit beside a bump breaks the tag push — see the doc).
- **P9 Devcontainer setup chain** — `init-host.sh` → `setup-base.sh` → `setup-python-dev.sh` →
  `setup-claude.sh`; P1/P2c skip the Python step.
- **P10 Runner-on-merge deploy** — **merging to main IS the production deploy**; `make
  prod-deploy` is a force-redeploy escape hatch.
- **P11 Scaffolding** — new repos come from `devtemplate` (`make init`).
- **P12 Dev tier** — `dev-deploy-all` on a parallel host, no Airflow.
- **P13 Scoped Claude identities** — `claude-prod` / `claude-dev` verb-allowlisted SSH wrappers;
  source lives in the stack's infra repo at `claude-access/`.
- **P14 Shared skills** — `dev-common/skills/<name>/SKILL.md`, exposed per repo by relative symlink
  from `setup-claude.sh`; they update through the `common` bump.
