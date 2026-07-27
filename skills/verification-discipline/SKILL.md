---
name: verification-discipline
description: Write checks, gates and tests that ask the data what it holds rather than asserting what it ought to hold. Use when writing a test, a health check, a data-quality guard, a staleness indicator, or any code that decides whether something "looks right" — and when a check passes but the thing it checks is broken.
---

# Verification discipline

The failure mode this exists for: **a check written by someone who already
believes the system works.**

It is not a testing-style preference. On the home stack, nine defects in a
single day were one shape — an assumption about the data expressed as a rule
about the calendar or the artefact. Each was a claim about what the data *ought*
to contain. Each was wrong for a population nobody enumerated. Several sat in
production for months, green.

## The shape, from real cases

| the rule that was written | what the data actually held |
| --- | --- |
| "times ≤ 05:00 are UTC instants" | 285 book prices stamped exactly `00:00:00` had no time at all — filed a day early |
| "the most recent weekday has market data" | the upstream sync lands at 22:00 UTC and consolidation lags another day |
| "both filers are over 65" | born 1967/1969 → qualify 2032/2034; the projection starts 2026 |
| "a high failure count means a fault" | permanently-failing holidays never leave the retry set, so a *healthy* book reads ~100% failed |
| "the first ticker alphabetically is a holding" | it was `ADF`, the Andorran Franc, from GnuCash's built-in ISO table |
| "`price_history` tells us how fresh the book is" | it is forward-padded to quarter-end — the staleness gap was structurally zero |

Note the last two: the check *itself* was the defect. A staleness indicator that
cannot detect staleness is worse than none, because it is trusted.

## Ask the object for its own answer

Whenever you are about to write a rule, look for the datum that makes the rule
unnecessary:

| instead of | ask for |
| --- | --- |
| `date.today()`, "the last weekday" | the table's own `max()` date |
| a weekday/holiday calendar | the set of dates the data actually covers |
| counting failures | the failure's **type** — `ValueError("no data")` is a gap, `KeyError` is a fault |
| a hardcoded example value | a value drawn from the data, intersected with what the other side has |
| a frozen constant (`age_65_count: 2`) | computed per period from the underlying facts |

If you cannot find such a datum, say so in the code. A stated assumption is
recoverable; an implied one is not.

## Gate what the thing does, not what it reads

A check that only exercises the read path proves nothing about the write path.
A ledger writer once passed its gate having never successfully run: the gate
opened the book, read it, and never touched the acquisition path where all
three of its faults lived.

- Exercise **every injected dependency** for real — not a mock of it.
- Run **all** the probes and report the failures **together**. Stopping at the
  first turns one round trip into several, and hides which half works.
- Distinguish "cannot be answered" from "answered wrongly", and let only the
  first be benign.

## Test the contract, not your memory of it

When two components agree on something — a header, a URI, a column name — assert
against **the other side's actual source**, not against a constant you retyped.
A mock will happily agree with the bug.

```python
# hog matches on a substring; assert against ITS source, and skip if absent
response_py = ROOT.parent / "hog" / "src" / "api" / "response.py"
if not response_py.is_file():
    pytest.skip("hog not checked out alongside")
assert '"application/parquet" in request.headers.get("accept", "")' in response_py.read_text()
```

## Two concrete traps

**Do not assert a bad expression is absent from source text.** A good fix
documents the old behaviour, so the broken expression *reappears in the
comments* and your test fails against the documentation. Compare unparsed ASTs
with docstrings stripped:

```python
tree = ast.parse(path.read_text())
for node in ast.walk(tree):
    body = getattr(node, "body", None)
    if isinstance(body, list) and body:
        first = body[0]
        if (isinstance(first, ast.Expr) and isinstance(first.value, ast.Constant)
                and isinstance(first.value.value, str)):
            node.body = body[1:] or [ast.Pass()]
code = ast.unparse(tree)
```

**Do not conclude anything from a truncated listing.** `ls | tail` on Airflow
run directories hides asset-triggered runs entirely — `asset_triggered__` sorts
*before* `manual__`. Absence in a filtered view is not absence. Grep the field.

## Record the negative space

End an audit or a gate with **what you checked and found sound**. A short report
is otherwise ambiguous between "clean" and "did not look", and the reader cannot
tell which. It also retires whole classes of worry: confirming that
`date_range(freq='D', tz=...)` holds wall-clock across DST is worth as much as
any finding.

## When a check passes but the thing is broken

Work backwards through this, in order:

1. Did the check ever **run**? Absence of a log directory, a run record or an
   artefact is the tell.
2. Did it exercise the **path that matters**, or only the one that reads?
3. Is the failure being **swallowed** — a bare `except`, a warning in a loop
   that treats failure as routine, a `.get()` with a default?
4. Is the check asserting a **rule** where it could ask the **data**?
