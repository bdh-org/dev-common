#!/usr/bin/env bash
# lock.sh -- serialize the Claude Code CLI install across every runner unit on
# one self-hosted host (bdh-org/home-infra#541).
#
# WHY THIS EXISTS
#
#   forge runs COUNT runner units, and register-forge-runner.sh gives them all
#   the SAME service account, so they share one HOME and therefore one
#   ~/.claude. The official installer (https://claude.ai/install.sh) hardcodes
#
#       DOWNLOAD_DIR="$HOME/.claude/downloads"
#
#   with no way to override it -- CLAUDE_CONFIG_DIR is not read -- and contains
#   no locking of any kind. It names the file after the VERSION, so two runs
#   installing the same version do not miss each other: they write the same
#   path. Verified against the published bootstrap script, 2026-08-20.
#
#   On 2026-08-18 two agent-pr labels applied in the same second fired two runs
#   at 13:08:56. Both died, neither opened a PR, and neither failure had
#   anything to do with the issues being worked:
#
#       Checksum verification failed          (one run reading a half-written file)
#       ...
#       bash: line 183: .../claude-2.1.234-linux-x64: Text file busy
#       Failed to install Claude Code after 3 attempts: exit code 126
#
#   ETXTBSY is the giveaway: exec'ing a file another process still holds open
#   for writing. The action's own three retries cannot help, because all three
#   race the same peer.
#
# WHY A LOCK AND NOT ISOLATION
#
#   Isolating the path per job would be better -- it would keep the runs
#   parallel -- and it is not available: the installer ignores CLAUDE_CONFIG_DIR
#   and hardcodes $HOME. The remaining isolation lever is a per-unit HOME, which
#   is host provisioning (scripts/forge/register-forge-runner.sh) and cannot be
#   fixed from a workflow. REVERSAL TRIGGER: if agent throughput becomes the
#   bottleneck, give each runner unit its own HOME on forge and delete this.
#
# WHY mkdir AND NOT flock
#
#   The lock has to span two workflow STEPS (acquire, then the action itself),
#   and each step is a separate shell -- a flock held by the first process is
#   gone before the second starts. `mkdir` is atomic on a local filesystem and
#   outlives the process, which is exactly the property needed.
#
# THE STALE CASE
#
#   A hard-killed job never runs its release step, so a lock can outlive its
#   holder and would otherwise wedge the pipeline permanently. Anything older
#   than LOCK_STALE_SECONDS is stolen, loudly. Release is OWNER-CHECKED so the
#   original holder returning late cannot delete the thief's lock and leave two
#   runs installing at once -- which would be this bug again, harder to see.
#
# THE ORDERING INVARIANT: job timeout < STALE < WAIT
#
#   These three numbers only work as a set, and the first version got the order
#   backwards: WAIT was 1500 (25min) under STALE 3600 (1h). A waiter therefore
#   had to arrive when the lock was ALREADY older than 2100s to reach the steal
#   path at all -- any waiter arriving in the first 35 minutes of a long hold
#   died instead. The steal case above was, for the common arrival, unreachable.
#
#   Measured on 2026-09-12 (bdh-org/home-infra#881): a healthy agent run held
#   the lock from 19:12:05 while it worked issue #874. The next run waited
#   19:12:54 -> 19:37:56, exactly 1500s, and FAILED with claude-code-action
#   skipped -- a red run about an issue it never touched. A `/revise` on PR #821
#   queued behind it would have given up at 20:11:32, when the lock became
#   stealable at 20:12:05. It missed by 33 seconds.
#
#   Ordered the other way the failure mode disappears, because each number now
#   guards the next one down:
#
#     * the agent job's `timeout-minutes` bounds how long ANY holder can hold;
#     * STALE sits above that, so a slow-but-alive holder is never stolen from
#       -- only one that outlived the job that created it (a runner crash,
#       where no release step ever ran);
#     * WAIT sits above STALE, so a waiter always reaches the steal path rather
#       than timing out first.
#
#   The cost is that a waiter can occupy a runner unit for up to WAIT. That is
#   the right trade while the lock is held across the whole agent run: the
#   fleet's agent throughput is 1 either way, so a waiting unit is not work
#   being displaced, and a wait ends in the PR being revised instead of a red
#   run. Rescoping the lock to the install alone -- which is what it is named
#   for, and which would restore real parallelism -- is home-infra#881.
#
# ENV:
#   LOCK_MODE           acquire | release          (required)
#   LOCK_OWNER          identity written into the lock (required for acquire)
#   LOCK_DIR            default "$HOME/.claude/install.lock.d"
#   LOCK_WAIT_SECONDS   give up waiting after this (default 6600 = 110min)
#   LOCK_STALE_SECONDS  steal a lock older than this (default 6000 = 100min)
#   LOCK_POLL_SECONDS   how often to retry (default 10)
#
# EXIT: 0 acquired/released (or nothing to release); 1 timed out or misused.

set -uo pipefail

MODE="${LOCK_MODE:-}"
LOCK="${LOCK_DIR:-${HOME:?HOME is unset and LOCK_DIR was not given}/.claude/install.lock.d}"
OWNER_FILE="$LOCK/owner"
WAIT="${LOCK_WAIT_SECONDS:-6600}"
STALE="${LOCK_STALE_SECONDS:-6000}"
POLL="${LOCK_POLL_SECONDS:-10}"

# Actions renders ::error:: / ::warning:: as annotations; elsewhere they are
# just prefixed lines, which is why they carry the full sentence themselves.
say()  { printf '%s\n' "$*"; }
warn() { printf '::warning::%s\n' "$*"; }
err()  { printf '::error::%s\n' "$*"; }

holder() { cat "$OWNER_FILE" 2>/dev/null || echo "unknown (no owner file)"; }

# Age of the lock in seconds, from the owner file when it exists (the dir's
# mtime moves when the owner file is written, so they agree) -- 0 if it cannot
# be read, which is the SAFE answer: 0 never looks stale, so an unreadable lock
# is waited on rather than stolen.
lock_age() {
    local ref="$LOCK" now mtime
    [ -f "$OWNER_FILE" ] && ref="$OWNER_FILE"
    now=$(date +%s)
    mtime=$(stat -c %Y "$ref" 2>/dev/null || echo "$now")
    echo $(( now - mtime ))
}

case "$MODE" in
    acquire)
        [ -n "${LOCK_OWNER:-}" ] || { err "claude-install-lock: acquire needs LOCK_OWNER"; exit 1; }
        mkdir -p "$(dirname "$LOCK")" || { err "claude-install-lock: cannot create $(dirname "$LOCK")"; exit 1; }
        waited=0
        while ! mkdir "$LOCK" 2>/dev/null; do
            age=$(lock_age)
            if [ "$age" -gt "$STALE" ]; then
                warn "claude-install-lock: stealing a stale lock ${age}s old, held by $(holder) -- that job almost certainly died without releasing it"
                rm -rf "$LOCK"
                continue
            fi
            if [ "$waited" -ge "$WAIT" ]; then
                err "claude-install-lock: gave up after ${waited}s waiting for the Claude Code install lock, still held by $(holder). Nothing was installed and no work was lost -- re-run this job, or re-apply the label, once that run finishes."
                exit 1
            fi
            # One line a minute: enough to see it is queued, not a wall of text.
            [ "$(( waited % 60 ))" -ne 0 ] || say "claude-install-lock: waiting for the install lock, held by $(holder) (${waited}s of ${WAIT}s)"
            sleep "$POLL"
            waited=$(( waited + POLL ))
        done
        printf '%s\n' "$LOCK_OWNER" > "$OWNER_FILE"
        say "claude-install-lock: acquired after ${waited}s (owner: $LOCK_OWNER)"
        ;;
    release)
        if [ ! -d "$LOCK" ]; then
            say "claude-install-lock: nothing to release (no lock present)"
            exit 0
        fi
        current="$(cat "$OWNER_FILE" 2>/dev/null || true)"
        if [ -n "${LOCK_OWNER:-}" ] && [ "$current" != "$LOCK_OWNER" ]; then
            warn "claude-install-lock: NOT releasing -- the lock is held by '${current:-unknown}', not by us ('$LOCK_OWNER'). Ours was stolen as stale, so releasing it would let two runs install at once."
            exit 0
        fi
        rm -rf "$LOCK"
        say "claude-install-lock: released"
        ;;
    *)
        err "claude-install-lock: LOCK_MODE must be 'acquire' or 'release', got '${MODE:-<empty>}'"
        exit 1
        ;;
esac
