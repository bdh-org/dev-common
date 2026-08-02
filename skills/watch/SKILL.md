---
name: watch
description: Cheap, exit-early polling for /loop ticks. Runs ONE probe against a named target — a repo's CI, a deploy, a PR's checks, the open-PR queue — and stops in a single line when nothing has changed; it only gathers detail when the probe went red or moved. Use for "is CI green?", "did the deploy land?", "any new PRs to review?". Not for fixing what it finds.
model: haiku
# A loop tick runs unattended: a question would end the turn and stall the loop
# until a human returns, silently. Removing the tool makes that impossible.
disallowed-tools: AskUserQuestion
---

# watch — one probe per tick, then stop

A `/loop` tick that surveys state from scratch pays for a full session's
thinking to answer a question a single `gh` call already answered. This skill
is the polling half of a loop, and nothing else: probe once, compare against
the previous tick, and end the tick immediately if the answer is "same as
before".

## Usage

```
/loop 5m /watch <target>
```

**Start the loop from a freshly cleared session.** Two cost levers are
separate and both matter:

| lever | fixed by |
| --- | --- |
| the **model** each tick runs on | this skill's `model:` frontmatter — already pinned to a small model |
| the **context** each tick replays | you: run `/clear` *before* starting the loop |

The frontmatter cannot fix the second one. A loop started at the end of a long
working session replays that whole session on every tick, and that context
usually costs more than the model does. Clear first, then start the loop.

In dynamic mode (`/loop /watch <target>`, no interval) pick the next wakeup
from how fast the watched thing actually moves — a CI run that takes ~8
minutes gets one ~480s check, not eight 60s ones.

## Targets

The target is an argument, never hard-coded. Resolve it to exactly one probe
command:

| target | probe |
| --- | --- |
| `<org>/<repo> ci` | last workflow run on `main` |
| `<org>/<repo> deploy` | last `ci-build` run on `main` — merge to main *is* the deploy (P10), so its conclusion is whether the deploy landed |
| `<org>/<repo> pr <n>` | `gh pr checks <n> --repo <org>/<repo>` |
| `<org>/<repo> prs` | `gh pr list --repo <org>/<repo> --json number,title,updatedAt` |
| anything else | derive the single probe from the target string. If it genuinely cannot be resolved, say so in one line and end the tick -- never ask |

`gh` has no ambient auth here — pass the org-scoped token inline (see
`CLAUDE.md`): `bdh-org` → `gh-bdh-org.token`, `finzeug` → `gh-finzeug.token`.
Never run `gh auth login`.

```bash
GH_TOKEN="$(cat ~/.config/ai/claude/credentials/gh-bdh-org.token)" \
  gh run list --repo bdh-org/home-site --branch main --limit 1 \
  --json databaseId,workflowName,status,conclusion,headSha,displayTitle,url
```

## The state line

Every tick ends with exactly one line, as the last line of the reply:

```
WATCH <target> | <fingerprint> | green|red|pending
```

The fingerprint is the identity of what was observed — enough to tell "moved"
from "same": e.g. `run=4821 status=completed conclusion=success`, or
`open=3 latest=#57 updated=2026-08-02T09:14:00Z`.

That line is the memory. Compare this tick's fingerprint to the most recent
`WATCH` line for the same target earlier in the conversation. No prior line
(first tick, or a cleared session) means there is no baseline: record it,
report it in one line, and stop — unless it is already red.

## Rules

1. **One tool call.** The probe is the whole tick. No file reads, no
   `git status`, no `gh run view` "just to be sure", no re-reading this skill's
   target list against the repo. If the probe itself fails to run (auth,
   network, unknown repo), say so in one line and stop — do not debug it.
2. **Unchanged → one line, stop.** `nothing changed` plus the state line. Do
   not restate what the target is, what the last failure was, or what you did
   on previous ticks.
3. **Changed and green → one line.** Name what moved, then the state line.
4. **Red, or green→red, or a new item in the queue → escalate**, below.

## Escalation

Only on red or a genuinely new item, and still bounded: at most two further
calls to name the failing thing (the failed run's job/step, or the log tail),
then summarise for a human:

```
RED — bdh-org/home-site ci-build #4821 failed on main (a1b2c3d "feat: add ...")
  job: build → step: Push image
  error: denied: requested access to the resource is denied
  https://github.com/bdh-org/home-site/actions/runs/4821
  needs a capable-model session to fix — /clear, then investigate.
WATCH bdh-org/home-site ci | run=4821 status=completed conclusion=failure | red
```

The summary must name the failing thing specifically — repo, workflow, run
number, job or step, and the URL. "CI is failing" is not an actionable
summary.

**Do not attempt the fix.** This skill runs on a small model by design; the
repair belongs to a session running a capable model, started fresh against the
summary above. Editing code, retrying runs, or pushing from a watch tick is
out of scope — flag it and stop.

## Availability

Lives in `dev-common/skills/watch/` and is exposed in every stack repo as a
project-level skill by `setup-claude.sh` (P14:
`<repo>/.claude/skills/watch -> ../../common/skills/watch`). Consuming repos
pick up changes with `make common-update` — the submodule bump — with no
per-repo copy and no devcontainer rebuild.
