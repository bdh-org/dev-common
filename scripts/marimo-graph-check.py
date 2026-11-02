#!/usr/bin/env python3
"""marimo-graph-check.py — static check of a marimo page's DATAFLOW GRAPH (home-infra#394).

It ships in dev-common so that every repo with marimo pages gets it through its
`common` pin, rather than one architect session pointing a private repo's copy at
one consumer by hand (dev-common#332). From a consumer checkout:

    common/scripts/marimo-graph-check.py src/<package>/pages
    common/scripts/marimo-graph-check.py --defs-only src/<package>/pages/derivatives.py

In CI it is the `marimo-pages` input to .github/workflows/self-hosted-ci.yml,
which runs exactly the first form against the path the caller names.

WHY THIS EXISTS

  /derivatives shipped BROKEN THREE TIMES — nothing rendered but the nav and one
  heading — and every check available to the reviewing session passed each time
  (home-infra#394):

    ruff             syntax, imports, style   — knows nothing about marimo cells
    a standalone     that the numbers are     — not that the notebook's dataflow
    script of the    right                      graph is legal
    page logic
    curl == 200      that the marimo shell    — EVERY CELL CAN FAIL BEHIND A 200
                     served
    container log    tracebacks, sometimes    — a page rendering NOTHING may log nothing

  Two of the three defects were graph defects, and both are decidable from the AST
  alone: a multiple-definition violation (`by` bound in two cells), and a rename
  done with a bare regex that corrupted an import into `import _requests` while
  leaving `requests.get(...)` behind — a reference no cell defines.

WHAT IT CHECKS

  1. multiple-definition — marimo requires every non-underscore name to be defined
     in exactly ONE cell. A violation disables the offending cells, and the failure
     cascades into NameError on every cell downstream of them. `ruff` cannot see it.

  2. undefined-reference — a name a cell loads that NO cell, the setup block, the
     module level or builtins defines. This is the `import _requests` class: a
     textual edit does not know what a token means, so it renames a binding and
     not its uses (or the reverse).

  3. unparsable cell — `app._unparsable_cell(...)` is what marimo writes when a cell
     does not parse. The file still imports, so nothing downstream notices.

WHY STDLIB-ONLY, AND WHY IT IS NOT THE WHOLE ANSWER

  `ast` only, no marimo import: this then runs in any repo's CI, on the forge runner,
  and in the architect seat — none of which is guaranteed to have marimo (the forge
  runner has no pip and no venv module at all, measured 2026-08-16). The cost is that
  it is a STATIC check: it proves the graph is legal, never that a cell produces
  output. Executing every page and asserting NON-EMPTY output is the other half, and
  it lives where the deps and the merge gate are — panoptikon's suite, via `app.run()`
  (finzeug/panoptikon#744). Neither replaces the other:

    this          catches the defect before the page is ever started, anywhere
    app.run()     catches the empty render, only where marimo is installed

WHY IT MUST NOT CRY WOLF

  The first attempt at this check flagged five pages — accounts, bond_etfs, forecast,
  tensor_status, yields — and EVERY flagged name was a comprehension variable, which
  Python scopes to the comprehension and marimo models correctly. A live probe of all
  39 routes found zero real violations. A guard that cries wolf gets ignored, which is
  worse than no guard, so the scoping rules below are the point of this file rather
  than a detail of it:

    * comprehension targets, lambda parameters, nested def/class locals — NOT cell
      definitions (their own scope). The nested def's NAME is.
    * a walrus inside a comprehension IS a cell definition: `:=` binds in the
      ENCLOSING scope, which is the one marimo shares between cells.
    * the cell function's own parameters are REFERENCES, not definitions — that is
      how marimo passes another cell's output in.
    * names starting with `_` are cell-private in marimo: never a multiple-definition,
      and never resolvable from another cell.
    * `except E as e` targets are deliberately NOT counted as definitions. Python
      deletes the name at the end of the handler, so no other cell can reference it,
      and two cells writing `except Exception as e` is ordinary code. Counting them
      could only produce false alarms. TRIGGER TO REVERSE: if marimo itself is ever
      observed rejecting two cells that bind the same except-name, count them.

EXIT CODES
  0  every discovered page's graph is legal (prints what it assessed)
  1  at least one defect
  2  discovery or usage failure — no pages found, unreadable path, bad flag.
     Distinct on purpose: "assessed nothing" must never read like "found nothing"
     (home-infra#232, #343).
"""

from __future__ import annotations

import argparse
import ast
import builtins
import difflib
import sys
from pathlib import Path

CHECK_VERSION = 1

BUILTINS = frozenset(dir(builtins)) | {"__name__", "__file__", "__doc__", "__spec__"}

# Decorators that make a module-level def a marimo cell. `app.cell` is the ordinary
# one; `app.function` / `app.class_definition` are the top-level forms, whose defs are
# the NAME they bind (their bodies are a nested scope like any other function body).
CELL_DECORATORS = {"cell"}
TOPLEVEL_DECORATORS = {"function", "class_definition"}


def _decorator_attr(node: ast.expr) -> str | None:
    """`@app.cell` and `@app.cell(...)` both -> "cell". Anything else -> None."""
    if isinstance(node, ast.Call):
        node = node.func
    if isinstance(node, ast.Attribute) and isinstance(node.value, ast.Name):
        if node.value.id == "app":
            return node.attr
    return None


class _Bindings(ast.NodeVisitor):
    """Names bound in ONE scope's own namespace.

    Descends through compound statements (if/for/while/with/try/match) because Python
    function scope is not block-scoped, and stops at every construct that opens a new
    scope — except to pick up walrus targets, which bind outward.
    """

    def __init__(self) -> None:
        self.names: set[str] = set()
        self.star_import = False

    # -- targets ---------------------------------------------------------------
    def _bind_target(self, target: ast.expr) -> None:
        if isinstance(target, ast.Name):
            self.names.add(target.id)
        elif isinstance(target, (ast.Tuple, ast.List)):
            for elt in target.elts:
                self._bind_target(elt)
        elif isinstance(target, ast.Starred):
            self._bind_target(target.value)
        # Attribute/Subscript targets (obj.x = 1, d["k"] = 1) mutate an existing
        # object; they bind no new name.

    def visit_Assign(self, node: ast.Assign) -> None:
        for t in node.targets:
            self._bind_target(t)
        self.visit(node.value)

    def visit_AnnAssign(self, node: ast.AnnAssign) -> None:
        # A bare `x: int` declares and binds nothing; only `x: int = ...` binds.
        if node.value is not None:
            self._bind_target(node.target)
            self.visit(node.value)

    def visit_AugAssign(self, node: ast.AugAssign) -> None:
        self._bind_target(node.target)
        self.visit(node.value)

    def visit_NamedExpr(self, node: ast.NamedExpr) -> None:
        self._bind_target(node.target)
        self.visit(node.value)

    def visit_For(self, node: ast.For) -> None:
        self._bind_target(node.target)
        self.generic_visit(node)

    visit_AsyncFor = visit_For

    def visit_withitem(self, node: ast.withitem) -> None:
        if node.optional_vars is not None:
            self._bind_target(node.optional_vars)
        self.visit(node.context_expr)

    def visit_ExceptHandler(self, node: ast.ExceptHandler) -> None:
        # Deliberately NOT binding node.name — see the module docstring.
        for stmt in node.body:
            self.visit(stmt)
        if node.type is not None:
            self.visit(node.type)

    # -- match statement -------------------------------------------------------
    def visit_MatchAs(self, node: ast.MatchAs) -> None:
        if node.name:
            self.names.add(node.name)
        self.generic_visit(node)

    def visit_MatchStar(self, node: ast.MatchStar) -> None:
        if node.name:
            self.names.add(node.name)

    def visit_MatchMapping(self, node: ast.MatchMapping) -> None:
        if node.rest:
            self.names.add(node.rest)
        self.generic_visit(node)

    # -- imports ---------------------------------------------------------------
    def visit_Import(self, node: ast.Import) -> None:
        for alias in node.names:
            # `import a.b` binds "a"; `import a.b as c` binds "c".
            self.names.add(alias.asname or alias.name.split(".")[0])

    def visit_ImportFrom(self, node: ast.ImportFrom) -> None:
        for alias in node.names:
            if alias.name == "*":
                self.star_import = True
                continue
            self.names.add(alias.asname or alias.name)

    # -- new scopes: bind the NAME, do not descend ------------------------------
    def visit_FunctionDef(self, node: ast.FunctionDef) -> None:
        self.names.add(node.name)
        self._walrus_in_signature(node)

    visit_AsyncFunctionDef = visit_FunctionDef

    def visit_ClassDef(self, node: ast.ClassDef) -> None:
        self.names.add(node.name)
        for expr in list(node.bases) + [kw.value for kw in node.keywords]:
            self.visit(expr)

    def visit_Lambda(self, node: ast.Lambda) -> None:
        self._walrus_in_signature(node)

    def _walrus_in_signature(self, node: ast.FunctionDef | ast.AsyncFunctionDef | ast.Lambda) -> None:
        # Default expressions and decorators are evaluated in THIS scope, so a walrus
        # in one binds here. The body is not.
        for expr in list(node.args.defaults) + [d for d in node.args.kw_defaults if d is not None]:
            self.visit(expr)
        for dec in getattr(node, "decorator_list", []):
            self.visit(dec)

    def _comprehension(self, node: ast.expr) -> None:
        # Python 3 scopes comprehension targets to the comprehension — but `:=` inside
        # one binds in the enclosing scope, so descend for walrus and nothing else.
        for sub in ast.walk(node):
            if isinstance(sub, ast.NamedExpr):
                self._bind_target(sub.target)

    def visit_ListComp(self, node: ast.ListComp) -> None:
        self._comprehension(node)

    visit_SetComp = visit_ListComp
    visit_DictComp = visit_ListComp
    visit_GeneratorExp = visit_ListComp


def _bindings(body: list[ast.stmt]) -> tuple[set[str], bool]:
    """Names bound directly in the scope whose statements these are."""
    v = _Bindings()
    for stmt in body:
        v.visit(stmt)
    return v.names, v.star_import


def _bound_anywhere(body: list[ast.stmt]) -> set[str]:
    """Every name bound at ANY depth, nested scopes included.

    Used only to decide whether a load is resolvable. Deliberately over-broad: a
    comprehension target is not a cell definition, but a load of it inside that same
    comprehension is obviously fine, and reporting it would be exactly the wolf-cry
    that got the first version of this check discarded.
    """
    names: set[str] = set()
    for stmt in body:
        for node in ast.walk(stmt):
            if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)):
                names.add(node.name)
                names.update(_arg_names(node.args))
            elif isinstance(node, ast.Lambda):
                names.update(_arg_names(node.args))
            elif isinstance(node, ast.ClassDef):
                names.add(node.name)
            elif isinstance(node, ast.Name) and isinstance(node.ctx, (ast.Store, ast.Del)):
                names.add(node.id)
            elif isinstance(node, ast.Import):
                for alias in node.names:
                    names.add(alias.asname or alias.name.split(".")[0])
            elif isinstance(node, ast.ImportFrom):
                for alias in node.names:
                    if alias.name != "*":
                        names.add(alias.asname or alias.name)
            elif isinstance(node, ast.ExceptHandler) and node.name:
                names.add(node.name)
            elif isinstance(node, (ast.MatchAs, ast.MatchStar)) and node.name:
                names.add(node.name)
            elif isinstance(node, ast.MatchMapping) and node.rest:
                names.add(node.rest)
            elif isinstance(node, (ast.Global, ast.Nonlocal)):
                names.update(node.names)
    return names


def _arg_names(args: ast.arguments) -> list[str]:
    return [
        a.arg
        for a in list(args.posonlyargs) + list(args.args) + list(args.kwonlyargs)
        if a is not None
    ] + [a.arg for a in (args.vararg, args.kwarg) if a is not None]


def _loads(body: list[ast.stmt]) -> dict[str, int]:
    """name -> first line it is loaded on, at any depth."""
    seen: dict[str, int] = {}
    for stmt in body:
        for node in ast.walk(stmt):
            if isinstance(node, ast.Name) and isinstance(node.ctx, ast.Load):
                seen.setdefault(node.id, node.lineno)
    return seen


class Cell:
    """One marimo cell: the unit that must define each name exactly once."""

    def __init__(self, label: str, lineno: int, body: list[ast.stmt], params: list[str]):
        self.label = label
        self.lineno = lineno
        self.body = body
        self.params = params
        self.defs, self.star_import = _bindings(body)
        self.bound = _bound_anywhere(body) | set(params)
        self.loads = _loads(body)

    @property
    def public_defs(self) -> set[str]:
        return {n for n in self.defs if not n.startswith("_")}


class Defect:
    def __init__(self, kind: str, line: int, message: str):
        self.kind = kind
        self.line = line
        self.message = message


def _is_notebook(tree: ast.Module) -> bool:
    """A marimo page, as opposed to any other .py file that happens to sit beside one."""
    imports_marimo = any(
        isinstance(n, ast.Import) and any(a.name == "marimo" for a in n.names)
        for n in tree.body
    )
    has_app = any(
        isinstance(n, ast.Assign)
        and isinstance(n.value, ast.Call)
        and _dotted(n.value.func) in ("marimo.App", "mo.App")
        for n in tree.body
    )
    has_cells = any(
        isinstance(n, (ast.FunctionDef, ast.AsyncFunctionDef))
        and any(_decorator_attr(d) for d in n.decorator_list)
        for n in tree.body
    )
    return imports_marimo and (has_app or has_cells)


def _dotted(node: ast.expr) -> str:
    parts: list[str] = []
    while isinstance(node, ast.Attribute):
        parts.append(node.attr)
        node = node.value
    if isinstance(node, ast.Name):
        parts.append(node.id)
    return ".".join(reversed(parts))


def _is_setup_block(node: ast.stmt) -> bool:
    """marimo's `with app.setup:` block — its defs are global defs like a cell's."""
    if not isinstance(node, ast.With):
        return False
    return any(_dotted(item.context_expr) == "app.setup" for item in node.items)


def analyse(path: Path, source: str, check_refs: bool = True) -> tuple[list[Cell], list[Defect]]:
    """Parse one page and return its cells plus every defect found. Never raises."""
    defects: list[Defect] = []
    try:
        tree = ast.parse(source, filename=str(path))
    except SyntaxError as exc:
        # A file that does not parse cannot be inspected for the marimo markers, so
        # fall back to a textual sniff. Reporting EVERY unparsable .py under a path
        # would flag a repo's deliberately-broken test fixtures, which is the wolf-cry
        # this check exists not to be.
        if "marimo" in source and "app.cell" in source:
            return [], [Defect("syntax-error", exc.lineno or 1, f"does not parse: {exc.msg}")]
        return [], []

    if not _is_notebook(tree):
        return [], []

    cells: list[Cell] = []
    module_names: set[str] = set()
    module_star = False
    ordinal = 0

    for node in tree.body:
        if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)):
            kinds = {_decorator_attr(d) for d in node.decorator_list}
            if kinds & CELL_DECORATORS:
                # Every cell in a marimo file is `def _(...)`, so the def name identifies
                # nothing -- number them in file order, which is how a reader finds one.
                ordinal += 1
                cells.append(Cell(f"cell {ordinal}", node.lineno, node.body, _arg_names(node.args)))
                continue
            if kinds & TOPLEVEL_DECORATORS:
                # `@app.function def helper(...)`: the cell IS the binding of `helper`.
                ordinal += 1
                cells.append(Cell(f"cell {ordinal} (@app.function {node.name})", node.lineno, [node], []))
                continue
        elif isinstance(node, ast.ClassDef):
            if {_decorator_attr(d) for d in node.decorator_list} & TOPLEVEL_DECORATORS:
                ordinal += 1
                cells.append(Cell(f"cell {ordinal} (@app.class_definition {node.name})", node.lineno, [node], []))
                continue
        elif _is_setup_block(node):
            cells.append(Cell("with app.setup", node.lineno, node.body, []))
            continue
        elif (
            isinstance(node, ast.Expr)
            and isinstance(node.value, ast.Call)
            and _dotted(node.value.func) == "app._unparsable_cell"
        ):
            defects.append(
                Defect(
                    "unparsable-cell",
                    node.lineno,
                    "app._unparsable_cell(...) — marimo could not parse this cell, so it "
                    "renders nothing while the file still imports cleanly",
                )
            )
            continue

        names, star = _bindings([node])
        module_names |= names
        module_star = module_star or star

    # -- 1. multiple definition -------------------------------------------------
    owners: dict[str, list[Cell]] = {}
    for cell in cells:
        for name in cell.public_defs:
            owners.setdefault(name, []).append(cell)
    for name, where in sorted(owners.items()):
        if len(where) > 1:
            sites = ", ".join(f"line {c.lineno} [{c.label}]" for c in where)
            defects.append(
                Defect(
                    "multiple-definition",
                    where[0].lineno,
                    f"`{name}` is defined by {len(where)} cells ({sites}) — marimo requires "
                    f"exactly one, and disables all of them",
                )
            )

    # -- 2. undefined reference -------------------------------------------------
    # Suppressed wholesale by a star import: `from x import *` makes the resolvable set
    # unknowable from the AST, and guessing there is how a guard starts crying wolf.
    star = module_star or any(c.star_import for c in cells)
    if check_refs and not star:
        resolvable = set(module_names) | BUILTINS
        for cell in cells:
            resolvable |= cell.public_defs
        # The suggestion pool is deliberately WIDER than the resolvable set: it includes
        # every cell's private (`_`-prefixed) defs, because the defect this hint exists
        # for is a regex rename that underscored the binding and not its uses —
        # `import _requests` left behind a `requests.get(...)` (home-infra#394).
        hint_pool = sorted(resolvable | {n for c in cells for n in c.defs})
        for cell in cells:
            local = resolvable | cell.bound | cell.defs
            for name, line in sorted(cell.loads.items(), key=lambda kv: kv[1]):
                if name in local:
                    continue
                near = difflib.get_close_matches(name, hint_pool + sorted(cell.bound), n=1, cutoff=0.8)
                hint = f" (nearest bound name: `{near[0]}`)" if near else ""
                defects.append(
                    Defect(
                        "undefined-reference",
                        line,
                        f"`{name}` is used in {cell.label} but no cell, the setup block, the "
                        f"module level or builtins defines it{hint}",
                    )
                )

    defects.sort(key=lambda d: (d.line, d.kind))
    return cells, defects


def discover(paths: list[str]) -> list[Path]:
    found: list[Path] = []
    for raw in paths:
        p = Path(raw)
        if p.is_dir():
            found.extend(sorted(q for q in p.rglob("*.py") if q.is_file()))
        elif p.is_file():
            found.append(p)
        else:
            print(f"FAIL: {raw} does not exist — nothing was assessed.", file=sys.stderr)
            raise SystemExit(2)
    return found


def _n(count: int, noun: str) -> str:
    return f"{count} {noun}" if count == 1 else f"{count} {noun}s"


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(
        prog="marimo-graph-check.py",
        description="Static check of a marimo page's dataflow graph (home-infra#394).",
    )
    ap.add_argument("paths", nargs="+", metavar="PATH", help="marimo page file(s) or a directory")
    ap.add_argument(
        "--defs-only",
        action="store_true",
        help="only the multiple-definition check; skip undefined-reference (escape hatch "
        "if the reference check ever cries wolf on a page — say so in the issue too)",
    )
    ap.add_argument("--quiet", action="store_true", help="print the summary line only")
    args = ap.parse_args(argv)

    candidates = discover(args.paths)

    pages = 0
    cells_total = 0
    bad_pages = 0
    defects_total = 0
    for path in candidates:
        try:
            source = path.read_text(encoding="utf-8")
        except (OSError, UnicodeDecodeError) as exc:
            print(f"FAIL: cannot read {path}: {exc}", file=sys.stderr)
            return 2
        cells, defects = analyse(path, source, check_refs=not args.defs_only)
        if not cells and not defects:
            continue  # not a marimo page; every other .py in the tree lands here
        pages += 1
        cells_total += len(cells)
        if defects:
            bad_pages += 1
            defects_total += len(defects)
            print(f"== {path}")
            for d in defects:
                print(f"  {path}:{d.line}: {d.kind}: {d.message}")

    # An assessment of nothing must not read as a clean bill of health: a moved pages
    # directory, a renamed suffix or a bad pathspec would otherwise pass silently
    # (home-infra#232, #343).
    if pages == 0:
        print(
            "FAIL: discovered 0 marimo pages under: " + ", ".join(args.paths) + " — "
            "discovery is broken, not the fleet clean.",
            file=sys.stderr,
        )
        return 2

    scope = "multiple-definition" if args.defs_only else "multiple-definition + undefined-reference"
    assessed = f"assessed {_n(pages, 'marimo page')} ({_n(cells_total, 'cell')})"
    # The detail lines go to stdout and the verdict to stderr; without this flush the
    # two streams interleave wrongly whenever the output is piped, and the verdict
    # appears above the defects it is counting.
    sys.stdout.flush()
    if defects_total:
        print(
            f"FAIL: {assessed} — {_n(bad_pages, 'page')} carrying "
            f"{_n(defects_total, 'defect')} [{scope}]",
            file=sys.stderr,
        )
        return 1
    if not args.quiet:
        print(f"PASS: {assessed} — no defects [{scope}]")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
