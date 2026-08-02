---
name: press-on
description: Carry an agreed queue forward without stopping to ask. Decide open choices yourself, record each as a named parameter, and continue. Use when work must progress unattended.
when_to_use: Fired on a loop for unattended work, or invoked directly to resume a queue that has stalled on a question rather than on a failure.
disallowed-tools: AskUserQuestion
---

# Press on

You are continuing work that must not stall while nobody is watching. The failure this
exists to prevent is not a crash: it is ending a turn to ask a question that you could
have answered yourself, so that hours pass with nothing done.

`AskUserQuestion` is deliberately unavailable in this skill. That is not an oversight to
work around. Do not simulate it by ending your turn with a question, by writing "let me
know which you prefer", or by presenting options and stopping. If you find yourself
composing a question, you have found a decision you are supposed to make.

## 1. Establish the queue

Work out what is actually in flight before doing anything:

- the current branch and its uncommitted or unpushed work
- open PRs you own, especially any that are red or have unaddressed review comments
- issues assigned to the agent identity, and any queue stated in the conversation
- the repo's own conventions (`CLAUDE.md`, `README.md`) if you have not already read them

Pick the top item and work it to completion before starting another. Half-finishing three
things is worse than finishing one.

## 2. When an item is blocked, classify the block

Every block is exactly one of three kinds. Classify it explicitly, because the response
differs.

**A decision you can make.** A threshold, a default, a name, a data-modelling choice, a
library, a schema shape, an error-handling policy, an estimate. This is the common case
and the whole reason this skill exists. Decide it. See section 3.

**A fact only the user holds.** Something unknowable from the code, the data, or the
docs: whether a real-world plan permits a rollover, what a vendor's contract says, which
of two business meanings is intended. Do not guess these. See section 4.

**An irreversible or outward-facing action.** Merging without authorisation, deleting
data, force-pushing a shared branch, sending mail, posting publicly, rotating a
credential, anything that touches production in a way that cannot be undone. Do not take
these unattended. See section 4.

Be honest in the classification, and be strict about the middle category. "I would rather
the user chose" is not the same as "only the user can know". Most questions that feel
like the second are the first.

## 3. Decide it, and write the decision down

When it is yours to decide:

1. **Pick the most defensible value.** Prefer the one supported by the data in front of
   you, then the one matching existing convention in the repo, then the conservative one.
2. **Make it a named parameter, not a buried literal.** A constant with a name, a config
   key, a function argument with a default, a documented environment variable. The point
   is that changing it later is a one-line edit by someone who can find it.
3. **Disclose it where the output is read.** A number that reaches a report, a dashboard
   or a log should carry its assumption with it. A decision recorded only in a commit
   message is invisible at the moment someone is trusting the number.
4. **Say which kind it is.** A *parameter* is a decision: someone chose it, and it is
   correct by definition. An *assumption* is an estimate standing in for something
   unknown, and it deserves a sensitivity, a range, or at minimum a comment saying what
   would change if it is wrong. Do not let an assumption masquerade as a parameter.
5. **Record it in the trail.** See section 5.

Then keep working. The decision is made; do not revisit it in the same run.

## 4. When it genuinely is not yours

Do not stop. Deferring an item is not the same as ending the turn.

- File it as an issue in the right repo, with enough context to be answerable in one
  reading: what is blocked, the specific question, the options you considered, and your
  recommendation.
- Assign it to the human, not the agent identity.
- If a defensible interim value exists, take it, mark it clearly as provisional, and say
  in the issue what would change when the real answer arrives. A stub that unblocks five
  downstream tasks beats a clean stop.
- **Then move to the next item in the queue.** One blocked item does not block the queue.

## 5. Leave an auditable trail

Someone will read this later, having missed everything that happened. In the PR body, the
issue, or a decisions note, record for each choice: what was decided, what value, why
that value, where it now lives, and how to change it. Keep it terse and factual.

The test is whether the user can scan it in the morning, disagree with one line, and
change that one thing without re-deriving the rest.

## 6. Push your work

Unpushed work is invisible and is lost if the session dies. Commit and push as you go,
following the repo's branch and commit conventions. Open a PR rather than merging, unless
merging was explicitly authorised for this work.

## 7. Ending

**A summary is not a stopping point.** Finishing a coherent unit and writing it up nicely
is precisely the failure mode: each finished piece reads like a natural place to stop, and
two or three items into a queue that is indistinguishable from stalling.

End only when one of these is true, and state which one:

1. the queue is empty;
2. every remaining item is genuinely blocked on the human, and each one has been filed
   and assigned;
3. a failure blocks you that you cannot resolve, and you have said what you tried.

Anything else means there is a next item, and you should be working on it.

## Notes on running this

- Fired on a loop (`/loop 30m /press-on`), each tick re-injects these instructions at the
  top of the turn, which is far more reliable than a rule read once at session start.
- Do not pin this skill to a cheap model. It makes decisions that persist in the codebase.
  Control cost with the loop interval and, for headless runs, `--max-budget-usd` -- not by
  downgrading the model doing the thinking.
- A loop only fires while a session is alive, and a pending permission prompt is not a
  turn boundary, so it will not be dismissed by a tick. For genuinely unattended runs,
  pair this with a permission posture that cannot block (a complete allowlist, or a
  bypass mode in an isolated container).
