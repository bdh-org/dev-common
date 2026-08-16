---
name: fleet-status
description: Report what is open across the stack and WHO must act on each item. Leads with ONE ordered queue of everything waiting on Brian (issues and PRs together, ranked by what each releases, each row carrying the comment that makes it actionable), then open PRs with CI and mergeability, and the order to merge in. Produces linked tables, never a raw dump. Use for "where are we", "what's left", "review issue and PR status", "what are my to-do items", "what should I do next", "what is assigned to me". Read-only: it reports, it does not fix.
# Reporting is a read. A status pass that starts merging, closing or pushing has
# stopped being a status pass, and the human asked for a picture, not an edit.
disallowed-tools: Edit, Write, NotebookEdit
---

# fleet-status — what is open, and whose move it is

The deliverable is a table a human can act on: every row links, says whether it
is an issue or a PR, and names **who must do it**. A list of numbers is not a
status report; neither is a wall of 188 open issues.

**Lead with Brian's queue** -- one ordered table of everything waiting on him,
issues and PRs together, each row carrying the comment that makes it actionable
without opening it. That section is below; the rest of the report is context for
it.

This skill is read-only on purpose. Fixing what it finds is a separate decision,
usually a separate turn, and often a different person's.

## The one rule that makes the report true

**Re-query immediately before you write, from the direct endpoints.** Not from
memory, not from a query you ran earlier in the session, and never from
`search/issues`.

GitHub's search index lags — minutes to hours. Measured on 2026-08-14: a
`search/issues?q=is:issue+is:open` sweep returned **5 of 39 issues wrong**, all
of them closed hours before, including one reported as "nobody has done this"
that was already done. The same query re-run later returned none of them.

```bash
#  WRONG — stale index, silently
gh api "search/issues?q=is:issue+is:open+org:$ORG"

#  RIGHT — authoritative
gh api "repos/$ORG/$REPO/issues?state=open&per_page=100"   # note: includes PRs
gh api "repos/$ORG/$REPO/pulls?state=open&per_page=50"
```

The issues endpoint returns PRs too. Filter them:
`--jq '.[]|select(.pull_request==null)'`.

**Reporting a merged PR as awaiting action is the characteristic failure of this
report.** It happened three times in one session. The gap between gathering and
writing is where it creeps in, so close the gap.

## Auth

No ambient `gh` auth. One token per org, chosen from the repo's `origin`:

```bash
TB="$(cat ~/.config/ai/claude/credentials/gh-bdh-org.token)"
TF="$(cat ~/.config/ai/claude/credentials/gh-finzeug.token)"
GH_TOKEN=$TB gh api repos/bdh-org/home-infra/pulls?state=open
```

## Gathering

### Open PRs, whole fleet

```bash
for spec in bdh-org/home-infra bdh-org/home-site bdh-org/dev-common bdh-org/brief \
            finzeug/hog finzeug/heller finzeug/panoptikon finzeug/slingshot ...; do
  o=${spec%%/*}; T=$([ "$o" = finzeug ] && echo "$TF" || echo "$TB")
  GH_TOKEN=$T gh api "repos/$spec/pulls?state=open&per_page=50" \
    --jq ".[]|\"${spec##*/}#\(.number)\t\(.user.login)\t\(.head.ref)\t\(.title[0:52])\""
done
```

### CI status — the Actions endpoint, not `gh pr checks`

The `bdh-ai` PATs lack **Checks:read**, so both of these fail:

```
$ gh pr checks 407 --repo bdh-org/home-infra
GraphQL: Resource not accessible by personal access token (...statusCheckRollup...)

$ gh api repos/$O/$R/commits/$SHA/check-runs
{"message":"Resource not accessible by personal access token","status":"403"}
```

They *can* read Actions. Use the run list for the PR's head branch:

```bash
b=$(printf '%s' "$HEAD_REF" | sed 's|/|%2F|g')     # bump/lib/ledger-io needs escaping
GH_TOKEN=$T gh api "repos/$O/$R/actions/runs?branch=$b&per_page=4" \
  --jq '[.workflow_runs[]|select(.event=="pull_request")]|first|"\(.status)/\(.conclusion // "-")"'
```

A public repo answers `check-runs` fine, so the 403 is about the token *and* the
repo's visibility — do not conclude the tooling is broken when one repo works.

### Mergeability

`gh api repos/$O/$R/pulls/$N --jq .mergeable_state`:

| value | means | in the report |
| --- | --- | --- |
| `clean` | ready | ready to merge |
| `dirty` | **conflicts** | needs a rebase — or is superseded, see below |
| `behind` | mergeable, but the base moved under it | needs an update-branch — **mine, not Brian's**; keep it out of his queue |
| `unstable` | mergeable, a check failed or is still running | say which check |
| `unknown` | GitHub has not computed it yet | **re-query after ~30s**; never report `unknown` |

## Classifying a PR — the part that is actually judgement

Three PRs can all read `dirty` and need three different things. Ask, in order:

1. **Is it superseded?** If the linked issue is **closed** and a merged PR
   carries the same change, the PR should be **closed, not merged**. Check:

   ```bash
   GH_TOKEN=$T gh api repos/$O/$R/issues/$LINKED --jq .state
   GH_TOKEN=$T gh api "repos/$O/$R/pulls?state=closed&per_page=8" \
     --jq '.[]|select(.merged_at!=null)|"#\(.number) \(.title)"'
   ```

   Five panoptikon agent PRs sat "conflicted" for a day when the devcontainer had
   already shipped every one of them itself. Recommending a merge there wastes a
   human's time on work already done.

2. **Did its CI actually run?** `startup_failure` with **zero jobs and no logs**
   is not a test failure — the workflow never resolved. Usual causes: a caller
   passes an input the reusable does not declare yet, or a public repo cannot
   resolve a private repo's reusable. It reads like a flake and is not one.

   ```bash
   GH_TOKEN=$T gh api "repos/$O/$R/actions/runs/$RUN_ID/jobs" --jq '.total_count'   # 0 == never started
   ```

   This produces a **hard ordering constraint** worth its own row: the PR that
   adds the input must merge before the caller can run at all.

3. **Is it stale, or blocked?** A `dirty` bump PR usually just needs the sweep
   re-run; a `dirty` feature PR needs its author.

## Who must do it — the column that makes this useful

| owner | what belongs to them |
| --- | --- |
| **Brian** | merges (a bump merge **is** a deploy), anything needing sudo on minerva/control, a secret only he holds, a judgement call |
| **architect** | CI/deploy wiring, host provisioning, cross-repo conventions — even when the file lives in an app repo |
| **`<repo>` devcontainer** | that repo's application and domain logic; its own open PRs and branches |

Two failure modes, both real:

- **Do not park work on Brian to make the report tidy.** "Nothing unassigned" is
  not a goal. Assigning agent-doable work to him inverts the value of his queue —
  it stops being a list of what needs *him*. A daily audit issue defaulted to
  `--assignee brianholland` and every morning's engineering report landed in his
  queue; the fix was to assign nobody.
- **Do not claim a devcontainer's work.** If a repo has a live session, its open
  PRs and dirty branches are theirs. Report them; do not touch them.

## Brian's queue -- lead the report with this

**One ordered table, issues and PRs together.** Two lists is the failure mode: he
reads the first, acts on it, and never learns the second existed. Brian,
2026-08-16: *"show issues and prs assigned to me with comments, in order in which
should be addressed."*

Four columns -- `#` | `Item` | `Your move` | `Why here / last word` -- and the
fourth is the point. A row he has to open to understand costs him a click, so
carry the substance inline: the **recommendation** if it is a decision, the
**command count** if it is a task, **what it releases**, or the **last comment**.

### Gathering the candidates

```bash
for o in bdh-org finzeug; do
  T=$([ "$o" = finzeug ] && echo "$TF" || echo "$TB")
  for r in $(GH_TOKEN=$T gh repo list "$o" --limit 40 --json name -q '.[].name'); do
    GH_TOKEN=$T gh api "repos/$o/$r/issues?state=open&assignee=brianholland&per_page=100" \
      --jq ".[]|select(.pull_request==null)|\"$o/$r#\(.number)\t\(.updated_at[0:10])\tc=\(.comments)\t\([.labels[].name]|join(\",\"))\t\(.title[0:60])\"" 2>/dev/null
  done
done
```

Then three calls **per candidate only** -- it is two API round trips an issue, so
do not run it over the whole fleet:

```bash
# what it RELEASES -- dependents that become actionable when he closes it
GH_TOKEN=$T gh api "repos/$O/$R/issues/$N/dependencies/blocking" \
  --jq 'if length==0 then "-" else [.[]|select(.state=="open")|"#\(.number)"]|join(",") end'
# what still holds it DOWN -- an open blocker means it is not his move yet
GH_TOKEN=$T gh api "repos/$O/$R/issues/$N/dependencies/blocked_by" \
  --jq '[.[]|select(.state=="open")|"#\(.number)"]|join(",")'
# the last word -- WHO spoke and WHAT they said
GH_TOKEN=$T gh api "repos/$O/$R/issues/$N/comments?per_page=100" \
  --jq 'if length==0 then "(none)" else .[-1] as $c|"\($c.user.login) \($c.created_at[0:10]): \($c.body|gsub("\\s+";" ")|.[0:140])" end'
```

`dependencies/blocking` is the **real graph**, not a prose claim in a body.
Verified 2026-08-16: home-infra#464 -> #262, #433 -> #18, #456 -> #336,
#350 -> #394. Two traps. `blocked_by` cheerfully returns **closed** issues
(home-infra#48 lists closed #40), so filter `state=="open"` on both sides or you
will invent blockers that are already gone. And an empty array is a 200 -- `[]`
means "no dependencies", never "the call failed".

### The order, and why it is that order

Rank by **what the item releases**, cheapest first within a tier:

1. **Deadlined or expiring** -- rises regardless of what it blocks, because the
   cost only goes up. The `bdh-ai` PATs expire **2026-11-01**, so the App that
   replaces them is time-boxed even though it releases a single issue.
2. **Cheap and unblocking** -- a title saying `(N commands)` / `(N steps)` with a
   non-empty `blocking` list. Minutes of his time, and a dependent goes green
   when he closes it. This tier is why the graph call is worth making: it beats a
   long decision that releases nothing.
3. **A decision that already carries a recommendation** -- also cheap, usually a
   one-word reply. Say so in the row and put the recommendation in the last
   column, so he can answer without opening anything. Never file a bare open
   question here: a decision handed back is work handed back (`issues/481`).
4. **Costly but unblocking** -- long procedures that release something.
5. **Releases nothing** -- last, if at all.

Ties break on fewer commands. **Drop an item a tier** when its own `blocked_by`
still holds an open issue: closing it releases nothing today, so it is not yet
his move -- say what it waits on.

### What must NOT be in it -- this matters as much as the order

| Kept out | Test | Goes instead to |
| --- | --- | --- |
| **He answered last** | last comment author is `brianholland` | "Answered -- my move" |
| **Standby** | body says there is nothing to do until a trigger fires | "Standby", trigger named |
| **`maybe-stale`** | the label | one line: count + filter command |
| **Machine-assigned** | `.user.login` ends `[bot]` | named once, out of the order |
| **Ordinary engineering** | nothing in "Who must do it" makes it his | "Mis-assigned", offer to unassign |

**He answered last** is `architect-sweep.sh` section 6's test, and it is
deliberately convention-free -- he replies however he likes; the signal is that
he spoke last. Live on 2026-08-16: the last comment on home-infra#459 is his,
*"yes, 5 min"*. The decision is made, the work is mine, and listing it as his
to-do asks him to answer twice. **Never drop these** -- give them their own short
section, because an answer that reached nobody is the exact bug this closes.

**Standby.** home-infra#456 opens *"Nothing to do right now. This is a standby
runbook"* -- and it genuinely does block #336, so the dependency graph alone
would rank it high. Read the body. List it, name the trigger, keep it out of the
order.

**Machine-assigned.** home-infra#384 is opened, commented and closed by
`scripts/fleet-audit-report.sh`, which assigns `brianholland` by default -- so
every morning's engineering findings land in his queue. That is an inversion of
what the queue is for, not a to-do. Note it once, keep it out, and say the
assignment should go.

**Ordinary engineering.** Assigned to him because a repo defaulted that way years
ago -- 17 such issues on 2026-08-16, oldest finzeug/augur#1 (2022-03-27), most of
them in archived repos. Report as **mis-assigned**, one line with a count and an
offer to unassign; do not list them as work. The long tail goes the same way:
untouched for a year is backlog, not queue, and a row spent on it buries the two
that are real.

**The contradictory double-signal.** An issue carrying `maybe-stale` *and* an
assignment to him says two opposite things -- "glance at this sometime" and "you
must act". Report it as a **defect in the queue itself**, name the issue, and say
which signal you think is wrong. Zero on 2026-08-16 (14 `maybe-stale` fleet-wide,
none assigned), which is why it has to be checked rather than remembered:

```bash
GH_TOKEN=$T gh api "repos/$O/$R/issues?state=open&labels=maybe-stale&per_page=100" \
  --jq '.[]|select(.pull_request==null)|"#\(.number) [\([.assignees[].login]|join(","))]"'
```

### PRs belong in the same table

They are rarely assigned in this fleet -- they are simply open and waiting.
Include one when the remaining action is **his**: an editorial or content
judgement, a deploy-path merge, a change he asked to see. Exclude one whose next
step is mine -- `dirty` (rebase), `behind` (update the branch), a red or
never-started check, an unfinished agent PR.

**Merging to main IS the production deploy here.** A merge row must say what it
ships and where: "merge -> forge rebuilds -> `registry.home.arpa` -> minerva
restarts `<svc>`". "Ready to merge" on its own hides that he is being asked to
deploy.

### Worked example

Rows below are a verified 2026-08-16 snapshot, trimmed for length. They show the
shape; re-query before you write.

```markdown
## Waiting on you -- in order

Ordered by what each one releases, cheapest first; a deadline outranks that.

| # | Item | Your move | Why here / last word |
|---|---|---|---|
| 1 | issue [home-infra#464](https://github.com/bdh-org/home-infra/issues/464) | register a GitHub App, 4 steps | Releases issue [#262](https://github.com/bdh-org/home-infra/issues/262). **Time-boxed: the `bdh-ai` PATs expire 2026-11-01** and nothing else replaces them. Last comment (me, 08-15): step 1's permission list was corrected in the body -- re-read it before registering. |
| 2 | issue [home-infra#433](https://github.com/bdh-org/home-infra/issues/433) | run `set-ci-repo-vars --check`, 1 command | Releases issue [#18](https://github.com/bdh-org/home-infra/issues/18) (Vault renders the runtime env). No comments; `VAULT_ADDR` has never been provisioned from version control, so nobody knows which repos carry it. |
| 3 | PR [brief#134](https://github.com/bdh-org/brief/pull/134) | read, then merge | Editorial call, yours: ranks the newsletter digest by standing interest. `clean`, CI green. Merging is the deploy -- it takes effect on the next digest run. |
| 4 | issue [home-infra#350](https://github.com/bdh-org/home-infra/issues/350) | one word, yes or no | **Recommendation already written: accept the Actions-API fallback** (`scripts/pr-checks.sh`) and close. You established 08-15 that fine-grained PATs have no Checks category at all, so widening the PAT was never available. Closing releases issue [#394](https://github.com/bdh-org/home-infra/issues/394). |
| 5 | issue [home-infra#48](https://github.com/bdh-org/home-infra/issues/48) | Vault KMS auto-unseal on control | Releases nothing open, `priority: low`, and still blocked by open issue [#467](https://github.com/bdh-org/home-infra/issues/467) (no AWS pass-through). Do #467 first; this is here for completeness. |

## Answered -- my move, not yours

| Item | You said | What I owe you |
|---|---|---|
| issue [home-infra#459](https://github.com/bdh-org/home-infra/issues/459) | 08-15: "yes, 5 min" | Build the liveness poll at a 5-minute interval and close it. Releases issue [#348](https://github.com/bdh-org/home-infra/issues/348). |

## Standby -- nothing to do until it fires

- issue [home-infra#456](https://github.com/bdh-org/home-infra/issues/456) -- recover a cgroup-wedged svc-prod container. **Trigger:** a container actually wedges. Blocks issue [#336](https://github.com/bdh-org/home-infra/issues/336) by design, so ignore its high graph rank.

## Kept out of your queue

- **Machine-assigned:** issue [home-infra#384](https://github.com/bdh-org/home-infra/issues/384) -- opened and self-assigned to you by `fleet-audit-report.sh`. Engineering output, mine to act on. The assignment should be dropped.
- **Mis-assigned (ordinary work):** 17 issues, oldest issue [augur#1](https://github.com/finzeug/augur/issues/1) (2022-03-27); the only live ones are issue [freddyb#13](https://github.com/finzeug/freddyb/issues/13) and issue [panoptikon#40](https://github.com/finzeug/panoptikon/issues/40). Say the word and I unassign all 17.
- **`maybe-stale`:** 14 open, none assigned to you -- browse when convenient, no action implied.
- **Defects in this queue:** none today (no issue carries both `maybe-stale` and your name).
```

## Merge order -- ranking PRs against each other

Give an explicit order when one exists, and say why:

- **Hard dependencies first** — a reusable-workflow change before the caller that
  uses its new input; a library fix before the consumers that pin it.
- **Group by what the merges jointly accomplish.** Three separate `lib/ledger-io`
  bumps are one unit: the writer and both readers must agree on the revision, and
  merging one of three leaves the disagreement in place.
- **Warn about the version collision.** Within one repo, several bump PRs each
  set the same `VERSION`; merging one stales the rest. Say so, rather than letting
  a human discover it on the second merge.

## Issues — everything outside Brian's queue

Do not dump them. A fleet has hundreds open and the list is not the report. Once
the queue above is written, a **count table** by repo is enough, plus only those
issues that need a *named* human, with `updated_at`:

```bash
GH_TOKEN=$T gh api "repos/$spec/issues?state=open&per_page=100" \
  --jq '[.[]|select(.pull_request==null)]|length'                       # count per repo
GH_TOKEN=$T gh api "repos/$spec/issues?state=open&per_page=100" \
  --jq '.[]|select(.pull_request==null)|select(.assignees|length>0)|"#\(.number) \(.assignees[0].login)"'
```

## Writing it

**Every number is a hyperlink and says which it is.** Never a bare `#441`, never
a bare `hog#441`. Issues and PRs share one number space, and the rendered link
text cannot say which — so the word goes beside it, or the group is labelled
("PRs ready:", "Issues needing you:").

```markdown
PR [heller#421](https://github.com/finzeug/heller/pull/421)
issue [home-infra#384](https://github.com/bdh-org/home-infra/issues/384)
```

Org from `origin`: `bdh-org` (home-infra, home-site, dev-common, devtemplate,
brief, roy, home-stack-common), `finzeug` (hog, oleo, canary, heller, panoptikon,
refdims, ratecraft, ferret, freddyb, slingshot, ledger-io).

Shape — Brian's queue first, always, because it is the only section written for
him rather than about the fleet:

```markdown
## Waiting on you -- in order          <- the queue; see "Brian's queue" above
## Answered -- my move, not yours
## Standby -- nothing to do until it fires
## Kept out of your queue

## Ready to merge -- Brian

| Order | PR | What | CI | Note |
|---|---|---|---|---|
| 1 | [heller#421](...) | lib/ledger-io, 11 behind | green | writer -- merge first, the readers depend on this revision |

## Needs its author -- panoptikon devcontainer

| PR | State | Action |
|---|---|---|
| [panoptikon#724](...) | conflicts | **close it** -- issue #719 closed, PR #730 shipped the same change |

## Open issues

| Repo | Open | Repo | Open |
|---|---|---|---|
```

Include a **Comments** or **Note** column and use it for the thing a table cannot
carry: why this one is first, what it is blocked on, what will happen if it is
merged out of order.

## Closing the report

- State what you verified and when — "re-queried just now" is a claim, so make it
  true.
- If something is red, say what would clear it, concretely and in order.
- If a scheduled job is what closes an item (a nightly audit, a sweep), say that
  the job **must actually run** — fixing the underlying problem does not close it.
- Never report an empty result as success. Zero open PRs across 18 repos is
  either a genuinely clear board or a broken query; say which, and how you know.
