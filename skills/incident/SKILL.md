---
name: incident
description: Work a production incident in the home stack end to end -- a red or ABSENT signal, a service that is down, a page or DAG that stopped updating, a fleet-audit or liveness issue that opened, "something is broken", "X is not working", "why is Y stale". Walks the loop the stack keeps repeating -- notice, find the TRUE cause, tell "never ran" from "ran and failed" from "ran and did nothing", fix, then verify against the real system, never the artefact -- using the read verbs that exist (make prod-liveness, make dag-freshness, claude-prod / claude-dev) and the runbooks. Ends with a fix that is verified live, or one BRIAN: issue for the single host step only he can run.
---

# incident -- from a red (or missing) signal to a verified fix

The deliverable is **a fix verified against the live system**, or, when the fix
needs root on a host, **one** `BRIAN:` issue carrying exactly that step. A theory
is not a deliverable; neither is a merged PR (merging is not deploying), nor a
green artefact (HTTP 200, exit 0, an empty result).

Most incidents here are not outages. They are *silent* failures: a DAG the
scheduler stopped creating, a host copy that never updated, a check that passes
because it looked at nothing. So the first job is to establish **which kind of
"broken" this is** before touching anything.

## 0. Ground rules (each one cost a real outage)

- **Read the BODY of a tracking issue, not its last comment.** Fleet-audit and
  liveness issues rewrite their body on every run; comments are only transitions.
- **HTTP 200 is not working.** The Apache vhost, `tailscale serve` and a default
  page all answer 200 (or 502) for a dead backend. Gate on real content.
- **An empty result is not success.** "0 rows", "no findings", "nothing to do"
  must be told apart from "could not look". Find the precondition that proves
  the reader saw the thing.
- **Check the DAG's paused state first.** A paused or `schedule=None` DAG makes
  every downstream symptom look like a code bug.
- **Merged is not deployed.** In home-infra, code reaches a host only by a second
  act (`sync-minerva-scripts.sh`, `make *-redeploy`, `copy-scripts.sh`). In app
  repos, merge IS the deploy -- check the ci-build run, not the PR.
- **Never run a destructive command to "see what happens".** In particular
  `airflow dags delete` is the trap: it erases run history and serialized DAGs
  (see `scripts/minerva/airflow-serialized-dag-runbook.md`). Count rows first.

## 1. Notice -- what exactly is red, and since when?

Name the signal and its source in one line before investigating:

| Signal | Where it lives | First read |
| --- | --- | --- |
| prod service not answering | `make prod-liveness` (timer on forge) | the liveness issue BODY |
| DAG not doing its work | `make dag-freshness` (hourly on forge) | home-infra#928-style issue BODY |
| fleet audit red | `fleet-audits.yml` nightly | the "Fleet audit" issue BODY |
| container `Exited (128)` | `claude-prod docker-ps` | `scripts/minerva/cgroup-wedge-runbook.md` |
| a page / number is stale | the page, then its upstream DAG | the DAG's last run |
| an agent run went red | the run's job summary | `agent-report-outcome.sh` output |

Write down: **first seen, last known good, what changed in between** (merges,
`claude-prod stamps` install times, a host reboot, a Sunday-night job).

## 2. Find the TRUE cause -- read, do not guess

Run reads from the **architect devcontainer**: `claude-prod` (minerva) and
`claude-dev` (twix) exist only there, not on any host.

**Prod (minerva) -- `claude-prod`, read-only verbs:**
```
claude-prod docker-ps                      # full names: home-site-svcprod-<svc>-1
claude-prod docker-logs home-site-svcprod-hog-1 --tail 2000   # cap 5000; default 200
claude-prod airflow-db dag-last-run        # paused? stale? timetable? last run
claude-prod airflow-db dag-recent-runs     # last 20 runs per DAG, with states
claude-prod airflow-db running-now         # anything wedged 'running'
claude-prod airflow task-states <dag> '<run_id>'
claude-prod stamps                         # which script version is INSTALLED, from which sha
claude-prod wedge-log                      # watchdog recreations
claude-prod wedge-daemon [container-id]    # why the rootless dockerd stopped
claude-prod keeper-status                  # Vault token keepers
```
Use `airflow-db`, not `airflow list`: the CLI list hangs for minutes.

**Dev tier / GPU tier (twix) -- `claude-dev`** has the same shape
(`docker-ps`, `docker-logs`, `stamps`, `keeper-status`, ...).

**Hosts, said right:** **minerva** is prod (never "min"); **twix** is the dev and
deploy host and the only one with checkouts (`~/dev/...`); **forge** runs CI,
the timers and roy/brief; **control** runs Vault and the registry. minerva,
forge and control have **no** `~/dev` and no git credentials: `cd ~/dev/...`
there is unrunnable. twix mounts prod data **read-only**; anything that writes
prod data runs as svc-prod **on minerva**.

Keep asking "why" until the answer is a **mechanism**, not a symptom:
"the container exited" is a symptom; "the rootless dockerd was stopped by an
external job at 23:00 Sunday, and the container's cgroup was not released" is a
mechanism.

## 3. Classify: never ran, ran and failed, ran and did nothing

| Class | Evidence | Typical cause here |
| --- | --- | --- |
| **Never ran** | no run / no log line / install stamp older than the fix | paused DAG, `schedule=None`, timer not installed, merged but never delivered to the host, scheduler stopped creating runs |
| **Ran and failed** | a red run, a non-zero exit, a traceback | expired token (Vault keeper, Schwab weekly), a moved path, a schema drift, a missing sibling checkout |
| **Ran and did nothing** | green run, zero rows written, unchanged output | empty input read as success, a filter that matched nothing, a stale copy treated as valid, a fallback path quietly taken |

The third class is the expensive one: nothing goes red. Prove the work happened
by reading its **output** (a row count, a parquet `post_date`, a file mtime that
moved, a version the service reports), not its exit status.

## 4. Fix -- at the cause, in version control

- Fix the mechanism, in the repo that owns it, on a branch in a **worktree**
  (never in a `/workspaces/<repo>` mount), claimed on the issue first
  (`working this on <branch>`).
- If the cause was **untracked host state** (a hand-edited file, a copy that
  drifted), the fix is to put it in version control and make the deploy path
  re-assert it -- not to edit the host again.
- If a detector failed to notice, fix the detector too, with a test that
  **fails on the old code** (mutation check). A detector that can pass while
  blind is the next incident.
- Anything touching a deploy or provisioning path gets **one independent review**
  before merge.
- **Settling state** (marking a wedged run failed, recreating a container) uses
  the narrow verb that exists for it -- e.g. `claude-prod airflow mark-failed` --
  never a raw database write or a broad delete.

## 5. Verify against the REAL system

Re-run the **same read that showed the fault**, and quote the line that changed:

- liveness: the service's row reads `ok` with real evidence, not just 200;
- DAG: a new run exists **after** the fix and its task states are `success`,
  and the output it writes moved (`dag-recent-runs`, the data itself);
- host script: `claude-prod stamps` shows the new version from the merged sha;
- audit: the next run's tracking-issue body no longer lists the finding
  (dispatch `fleet-audits.yml` with `report=true` rather than wait for the night).

If the fix is not yet installed, the incident is **not** resolved: say what is
waiting, on whom, and how it will be verified.

## 6. Close the loop

- **The host step only Brian can run** (root on a host, a credential only he
  holds): one `BRIAN:` issue, assigned to him, **the command first** with the host
  and account beside each step, a "Success looks like" with real expected output,
  idempotent where possible, linked as a dependency blocking the engineering
  issue. Never append the step to the diagnostic issue.
- **Brian's time is the constraint.** Do not route minor items to him (low-value
  hardening, a self-healing fault): label `priority: low` and handle or close them.
  Do everything that needs no root yourself, including the diagnosis.
- Post the cause, the fix and the verifying line on the issue, then close it on
  that **reporting signal** -- never on "merged" or "configured".
- If the same shape is likely to recur, file the detector or guard that would
  have caught it, with an issue number, in the same turn.

## Quick map: symptom -> first move

| Symptom | First move |
| --- | --- |
| DAG "stale" but nothing red | `airflow-db dag-last-run`: paused / stale / `schedule=None`? |
| a run stuck `running` for days | `airflow-db running-now`, then is the DAG retired? |
| container `Exited (128)`, won't restart | cgroup-wedge runbook; `wedge-log`, `wedge-daemon` |
| page shows old numbers | the upstream DAG's last **successful** run and its output |
| fix merged, still broken | `claude-prod stamps` -- was it ever installed? |
| liveness 502 on twix | `tailscale serve` answering for a dead dockerd (svc-nudl/svc-dev) |
| "Bad credentials" in an agent run | token expired behind a lock -- do it yourself, don't re-fire |
| Vault 403 in a DAG | `keeper-status`; the minter token expired |
