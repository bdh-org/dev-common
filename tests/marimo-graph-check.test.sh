#!/usr/bin/env bash
# marimo-graph-check.test.sh -- the marimo graph guard must catch the defects that shipped,
# and must NOT flag the shapes that only look like them (bdh-org/home-infra#394). Ported
# from bdh-org/home-infra's tests/test-marimo-graph-check.sh together with the checker
# itself, so that the guard and its suite travel with the `common` pin (dev-common#332).
#
#   RUNS: anywhere with python3 and this repo checked out. No network, no marimo, no host
#         access, ~1s. In CI on every PR via shell-tests.yml, and via `make test`.
#
# WHY THIS EXISTS
#   panoptikon's /derivatives shipped blank three times behind an HTTP 200. Two of the
#   three defects were decidable from the AST: a multiple-definition violation, and a
#   bare-regex rename that left `import _requests` next to `requests.get(...)`.
#
#   But the FIRST attempt at that check flagged five pages -- accounts, bond_etfs,
#   forecast, tensor_status, yields -- and every flagged name was a comprehension
#   variable, which Python scopes to the comprehension and marimo models correctly. A live
#   probe of all 39 routes found zero real violations. So this suite spends most of its
#   cases on the negative space: a guard that cries wolf gets ignored, and an ignored
#   guard is worse than no guard because it also looks like coverage.
#
# THE ORACLE, AND WHY IT IS NOT AN ASSERTION
#   The load-bearing case does not assert what the scoping rules ought to be. marimo runs a
#   cell's code in the shared notebook namespace, so "what this cell defines" IS "what
#   names are still bound after the cell body runs". scoping-oracle.py's cells are pure
#   stdlib and executable, so this suite RUNS each one and compares the surviving names,
#   name for name, against what the checker computed statically.
#
#   Two rules the intuitive answer gets wrong, both settled by that oracle rather than by
#   argument: a comprehension target does NOT leak, even though CPython 3.12 lists it in
#   the enclosing function's co_varnames and symtable (PEP 709 inlines comprehensions, so
#   neither is usable as an oracle here); and an `except ... as e` target is DELETED at the
#   end of its handler, so no other cell can ever reference it.
set -uo pipefail

# The repo root from this file's own location, not from `git rev-parse`: dev-common is
# checked out as a SUBMODULE in every consumer, and the suite must find its own fixtures
# whether or not the surrounding tree is a git worktree at all.
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT" || { echo "FAIL: cannot cd to $REPO_ROOT" >&2; exit 2; }

CHECK="scripts/marimo-graph-check.py"
FIXSRC="tests/fixtures/marimo"
WORKFLOW=".github/workflows/self-hosted-ci.yml"
[ -x "$CHECK" ]  || { echo "FAIL: ${CHECK} missing or not executable" >&2; exit 2; }
[ -d "$FIXSRC" ] || { echo "FAIL: ${FIXSRC} missing" >&2; exit 2; }
command -v python3 >/dev/null || { echo "FAIL: no python3" >&2; exit 2; }

pass=0; fail=0
ok()  { printf '  ok   %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  FAIL %s\n     %s\n' "$1" "$2"; fail=$((fail+1)); }

OUT="$(mktemp)"
EMPTY="$(mktemp -d)"
FIX="$(mktemp -d)"
trap 'rm -f "$OUT"; rm -rf "$EMPTY" "$FIX"' EXIT

# -- the fixtures are STAGED, not checked in as .py --------------------------------
#
# Most of them are deliberately invalid Python: an undefined reference, a star import,
# an unused import kept because the page's defect is what matters. That is the point of
# a fixture and a problem for a linter -- and dev-common is VENDORED into every
# consumer as common/, where `make lint` is `ruff check .` with no vendored excludes
# (make/python.mk). A .py here is therefore 30-odd ruff errors in every repo in the
# fleet, in files that repo's author cannot fix: the shape of bdh-org/dev-common#191.
#
# So they live on disk as *.py.fixture, which ruff and pytest both ignore, and this
# suite copies them to a temp directory under their real .py names. The checker
# discovers pages by globbing *.py, so the rename has to happen somewhere; doing it
# here costs one loop and keeps the fleet's lint untouched.
staged=0
for src in "$FIXSRC"/*.py.fixture; do
  [ -e "$src" ] || continue
  cp "$src" "$FIX/$(basename "$src" .fixture)"
  staged=$((staged + 1))
done
# A broken glob would otherwise present as an empty directory, and every case below
# would report "assessed nothing" -- the failure reading as the fixtures being clean.
if [ "$staged" -ge 9 ]; then
  ok "staged ${staged} fixtures from ${FIXSRC} as .py"
else
  echo "FAIL: staged only ${staged} fixtures from ${FIXSRC}/*.py.fixture -- the glob or the" >&2
  echo "      suffix is wrong, not the guard clean." >&2
  exit 2
fi

# run <fixture-or-path> [flags...] -> exit code in $rc, combined output in $OUT
#
# `-B` here and on the oracle below: the oracle imports the checker as a module, which
# otherwise writes scripts/__pycache__/ into the checkout. This repo has no .gitignore
# (it ships shell, make and workflows), so a suite that leaves bytecode behind shows up
# as untracked files in whatever branch the next session is working on.
run() { python3 -B "$CHECK" "$@" >"$OUT" 2>&1; rc=$?; }

# expect_rc <want> <label> <path...> -- the exit code IS the contract: 1 means defects, 2
# means it assessed nothing. Collapsing those two is how "found nothing" starts reading
# like "nothing to find" (bdh-org/home-infra#232, #343).
expect_rc() {
  local want="$1" label="$2"; shift 2
  run "$@"
  if [ "$rc" = "$want" ]; then ok "$label (exit ${rc})"
  else bad "$label" "expected exit ${want}, got ${rc}: $(head -3 "$OUT" | tr '\n' ' ')"; fi
}

expect_match() {
  local pattern="$1" label="$2"
  if grep -qE -- "$pattern" "$OUT"; then ok "$label"
  else bad "$label" "output has no /${pattern}/: $(tr '\n' ' ' <"$OUT")"; fi
}

expect_no_match() {
  local pattern="$1" label="$2"
  if grep -qE -- "$pattern" "$OUT"; then
    bad "$label" "output matched /${pattern}/, which is a false alarm: $(grep -E -- "$pattern" "$OUT" | head -2 | tr '\n' ' ')"
  else ok "$label"; fi
}

echo "== the defects that actually shipped must be caught"

expect_rc 1 "a name bound by two cells is a multiple-definition" "${FIX}/multiple-defs.py"
expect_match 'multiple-definition: `by` is defined by 2 cells' "it names the colliding name"
expect_match 'line 25 .*line 32' "it names BOTH cells, not just the second"

expect_rc 1 "a regex rename that underscored the binding is caught" "${FIX}/corrupted-rename.py"
expect_match 'undefined-reference: `requests`' "it names the unresolved reference"
expect_match 'nearest bound name: `_requests`' "it points at the corrupted binding, which is the fix"

expect_rc 1 "an unparsable cell is a defect, not a passing import" "${FIX}/unparsable-cell.py"
expect_match 'unparsable-cell' "it says the cell renders nothing"

expect_rc 1 "a setup-block binding collides with a cell binding" "${FIX}/setup-block.py"
expect_match 'THRESHOLD.*with app.setup' "it names the setup block as one of the two sites"

echo "== and the shapes that only LOOK like them must not be"

expect_rc 0 "comprehension/lambda/nested-def/except/param reuse is legal" "${FIX}/clean-scoping.py"
# The defect-line form, with its trailing colon -- the PASS summary names the checks that
# RAN, so a bare word match here would find the summary and call a clean page dirty.
expect_no_match 'multiple-definition: ' "no multiple-definition on the clean page"
expect_no_match 'undefined-reference: ' "no undefined-reference on the clean page"

# The pair that pulls in opposite directions inside ONE comprehension: the iteration
# variable is comprehension-scoped, the walrus binds outward. A guard that treats the
# comprehension as one thing gets exactly one of these wrong.
expect_rc 1 "a walrus in a comprehension binds outward, so it can collide" "${FIX}/walrus-in-comprehension.py"
expect_match 'multiple-definition: `scaled`' "the walrus target is reported"
expect_no_match '`v`' "the comprehension target beside it is NOT reported"

expect_rc 0 "a star import suppresses the reference check rather than guessing" "${FIX}/star-import.py"
expect_no_match 'undefined-reference: ' 'no wolf-cry on a name that came from a star import'

echo "== it must know what is and is not a marimo page"

# A helper module beside the pages rebinds names at module level all the time. The
# multiple-definition rule is marimo's, not Python's.
expect_rc 2 "a plain .py is not a page, so pointing at one assesses nothing" "${FIX}/not-a-notebook.py"
expect_match 'discovered 0 marimo pages' "it says it assessed nothing, rather than passing"

expect_rc 2 "an empty directory fails loudly instead of passing green" "$EMPTY"
expect_match "discovered 0 marimo pages under: ${EMPTY}" "it names the path it looked at"
expect_rc 2 "a path that does not exist is a discovery failure" "${EMPTY}/nope"

echo "== the escape hatch narrows the check without silencing it"
expect_rc 0 "--defs-only drops the reference check" --defs-only "${FIX}/corrupted-rename.py"
expect_match 'PASS: .*\[multiple-definition\]' "the summary says which checks ran, so a narrowed run cannot be mistaken for a full one"
expect_rc 1 "--defs-only still catches a real collision" --defs-only "${FIX}/multiple-defs.py"

echo "== a whole directory reports every page, and counts what it assessed"
expect_rc 1 "a mixed tree fails on the bad pages" "$FIX"
expect_match 'assessed [0-9]+ marimo pages \([0-9]+ cells\)' "the summary says how much was assessed"
expect_match 'multiple-defs.py' "the bad pages are named"
expect_no_match 'clean-scoping.py' "the clean page is not"

echo "== ORACLE: Python itself decides what a cell defines"
# Not an assertion about scoping rules -- an execution of them. Each oracle cell runs at
# module level (which is how marimo executes a cell), and whatever is still bound
# afterwards is what that cell defines.
if python3 -B - "$CHECK" "${FIX}/scoping-oracle.py" <<'PY'
import ast, importlib.util, sys

check_path, fixture = sys.argv[1], sys.argv[2]
spec = importlib.util.spec_from_file_location("mgc", check_path)
mgc = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mgc)

tree = ast.parse(open(fixture, encoding="utf-8").read(), filename=fixture)
cells = [
    n for n in tree.body
    if isinstance(n, ast.FunctionDef)
    and any(mgc._decorator_attr(d) == "cell" for d in n.decorator_list)
]
if len(cells) < 5:
    print(f"  FAIL oracle discovered {len(cells)} cells in {fixture} — discovery is broken, "
          "not the fixture clean.")
    raise SystemExit(2)

bad = 0
for cell in cells:
    body = [s for s in cell.body if not isinstance(s, ast.Return)]
    mod = ast.Module(body=body, type_ignores=[])
    ast.fix_missing_locations(mod)
    ns: dict = {}
    try:
        exec(compile(mod, "<cell>", "exec"), ns)
    except Exception as exc:                       # a cell that cannot run proves nothing
        print(f"  FAIL oracle cell at line {cell.lineno} did not execute: {exc!r}")
        bad += 1
        continue
    # __builtins__ is injected by exec; __annotations__ is created by an annotated
    # assignment at module level. Neither is a name the cell defined.
    runtime = {k for k in ns if k not in ("__builtins__", "__annotations__")}
    static, _ = mgc._bindings(cell.body)
    if runtime != static:
        print(f"  FAIL oracle cell at line {cell.lineno}: "
              f"claimed-but-not-bound={sorted(static - runtime)} "
              f"bound-but-not-claimed={sorted(runtime - static)}")
        bad += 1

if bad:
    print(f"  {bad} of {len(cells)} oracle cells disagree with Python")
    raise SystemExit(1)
print(f"  ok   all {len(cells)} oracle cells: the static answer IS what Python leaves bound")
raise SystemExit(0)
PY
then pass=$((pass+1))
else bad "the static analysis matches Python's own bindings" "see the oracle output above"; fi

# --- the CI wiring, which nothing in THIS repo executes ----------------------------
#
# self-hosted-ci.yml is a `workflow_call` implementation: its steps only ever run in a
# CONSUMER repo, so the first execution of a mistake here is a red run in somebody
# else's PR -- or, worse for a guard, a step that silently never fires. Same reason
# tests/ci-submodules.test.sh and tests/template-initialised.test.sh exist.
echo "== the self-hosted-ci.yml step that runs this guard in consumer repos"

if [ -f "$WORKFLOW" ]; then
  wf="$(grep -hv '^[[:space:]]*#' "$WORKFLOW")"

  if grep -qE '^      marimo-pages:' <<<"$wf"; then
    ok "self-hosted-ci.yml declares the marimo-pages input"
  else
    bad "self-hosted-ci.yml declares the marimo-pages input" "no 'marimo-pages:' input found"
  fi

  # Default empty IS the backward-compatibility contract: every existing caller omits
  # the input, and must keep behaving exactly as before.
  #
  # The block is read to the next sibling key rather than over a fixed number of
  # lines: the description is a folded scalar many lines long, so a `grep -A<n>`
  # window would silently stop short of the `default:` and report it absent.
  block="$(awk '
    /^      marimo-pages:$/ { inblock = 1; next }
    inblock && /^      [A-Za-z]/ { exit }
    inblock { print }
  ' <<<"$wf")"
  if grep -qE '^        default: (""|'"''"')$' <<<"$block"; then
    ok "the input defaults to empty, so existing callers are untouched"
  else
    bad "the input defaults to empty" "marimo-pages has no empty default -- every current caller would start running the guard"
  fi

  # The guard on the step is the other half of that contract: an empty input must SKIP
  # rather than run the checker on "", which would exit 2 and redden every repo at once.
  if grep -qE "if:.*inputs\.marimo-pages.*!=.*''" <<<"$wf"; then
    ok "the step is skipped when the input is empty"
  else
    bad "the step is skipped when the input is empty" "no \"if: inputs.marimo-pages != ''\" guard on the step"
  fi

  # The path a consumer reaches this file by. A rename of scripts/ or of this file is
  # exactly the change that leaves the workflow calling something that is not there.
  if grep -qF "common/$CHECK" <<<"$wf"; then
    ok "the step invokes common/$CHECK, the path a consumer sees"
  else
    bad "the step invokes common/$CHECK" "the workflow does not name that path -- a consumer run would die on 'No such file'"
  fi
else
  bad "self-hosted-ci.yml is present" "$WORKFLOW not found"
fi

# --- and the other half of "unchanged for a caller that does not opt in" ----------
#
# The fixtures must stay invisible to the fleet's linter, for the reason given at the
# staging loop above. Enforced rather than commented: the next person to add a fixture
# will reach for the obvious name, and nothing in THIS repo lints Python, so the first
# report would be a red `make lint` in somebody else's PR.
echo "== no .py under tests/fixtures/, which every consumer's \`ruff check .\` would walk"
stray="$(find tests/fixtures -name '*.py' -o -name '*.pyi' -o -name '*.ipynb' 2>/dev/null)"
if [ -z "$stray" ]; then
  ok "the fixtures are *.py.fixture, so common/ adds no lintable Python but the checker"
else
  bad "the fixtures are *.py.fixture" "these would be linted in every consumer repo: $(tr '\n' ' ' <<<"$stray")"
fi

# The checker itself IS shipped as .py and IS linted in every consumer, so it has to be
# clean under the ruff this repo pins. Only asserted where a matching ruff exists --
# `make lint` is not defined in this repo, and a check that silently substitutes a
# different linter's verdict is worse than one that says it did not run.
if command -v ruff >/dev/null 2>&1; then
  if ruff check --no-cache "$CHECK" >"$OUT" 2>&1; then
    ok "$CHECK is ruff-clean ($(ruff --version))"
  else
    bad "$CHECK is ruff-clean" "$(head -5 "$OUT" | tr '\n' ' ')"
  fi
else
  ok "ruff is not on PATH, so the lint of $CHECK is left to the consumer repos that have it"
fi

echo
total=$((pass + fail))
if [ "$total" -eq 0 ]; then
  echo "FAIL: 0 cases ran -- discovery is broken, not the guard clean." >&2
  exit 2
fi
if [ "$fail" -ne 0 ]; then
  echo "FAIL: ${fail} of ${total} cases failed" >&2
  exit 1
fi
echo "PASS: ${total} cases -- the guard catches what shipped, flags nothing that did not, and is wired into self-hosted-ci.yml"
