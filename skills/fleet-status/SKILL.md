---
name: fleet-status
description: Report what is open across the stack and WHO must act on each item — open PRs with CI and mergeability, issues that need a human, and the order to merge in. Produces linked tables, never a raw dump. Use for "where are we", "what's left", "review issue and PR status", "what are my to-do items". Read-only: it reports, it does not fix.
# Reporting is a read. A status pass that starts merging, closing or pushing has
# stopped being a status pass, and the human asked for a picture, not an edit.
disallowed-tools: Edit, Write, NotebookEdit
---

# fleet-status — what is open, and whose move it is

The deliverable is a table a human can act on: every row links, says whether it
is an issue or a PR, and names **who must do it**. A list of numbers is not a
status report; neither is a wall of 188 open issues.

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

## Ordering

Give an explicit order when one exists, and say why:

- **Hard dependencies first** — a reusable-workflow change before the caller that
  uses its new input; a library fix before the consumers that pin it.
- **Group by what the merges jointly accomplish.** Three separate `lib/ledger-io`
  bumps are one unit: the writer and both readers must agree on the revision, and
  merging one of three leaves the disagreement in place.
- **Warn about the version collision.** Within one repo, several bump PRs each
  set the same `VERSION`; merging one stales the rest. Say so, rather than letting
  a human discover it on the second merge.

## Issues

Do not dump them. A fleet has hundreds open and the list is not the report.

```bash
GH_TOKEN=$T gh api "repos/$spec/issues?state=open&per_page=100" \
  --jq '[.[]|select(.pull_request==null)]|length'                       # count per repo
GH_TOKEN=$T gh api "repos/$spec/issues?state=open&per_page=100" \
  --jq '.[]|select(.pull_request==null)|select(.assignees|length>0)|"#\(.number) \(.assignees[0].login)"'
```

Report: a **count table** by repo, then only the issues that need a human, with
`updated_at`. Age is the filter that matters — an issue assigned to Brian and
untouched since last year is backlog, not queue, and listing it as a to-do
buries the two that are real.

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

Shape:

```markdown
## Ready to merge — Brian

| Order | PR | What | CI | Note |
|---|---|---|---|---|
| 1 | [heller#421](...) | lib/ledger-io, 11 behind | green | writer — merge first, the readers depend on this revision |

## Needs its author — panoptikon devcontainer

| PR | State | Action |
|---|---|---|
| [panoptikon#724](...) | conflicts | **close it** — issue #719 closed, PR #730 shipped the same change |

## Open issues

| Repo | Open | Repo | Open |
|---|---|---|---|

## Needs you specifically
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
