#!/usr/bin/env bash
# lint-vendored-excludes.test.sh -- `make lint` must not fail a repo on its VENDORED trees
# (common/, stack-common/, lib/*), the same exclusion `format` already had
# (bdh-org/dev-common#191, #341). Once common/ shipped .py files (#340), `ruff check .`
# from a consumer root linted dev-common's code in every consumer at once.
#
# Two halves: the wiring (always runs), and the behavior in a simulated consumer root
# (runs where ruff is installed -- the devcontainer; says so when it cannot).
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${HERE}/.." && pwd)"
pass=0; fail=0
ok()    { echo "ok   - $1"; pass=$((pass+1)); }
notok() { echo "NOT OK - $1"; fail=$((fail+1)); [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/       /'; }

mk="${ROOT}/make/python.mk"
for target in lint lint-fix; do
  recipe="$(awk -v t="${target}:" '$1==t {getline; print; exit}' "$mk")"
  case "$recipe" in
    *'ruff check'*'$(RUFF_VENDORED_EXCLUDES)'*) ok "python.mk '$target' passes the vendored excludes" ;;
    *) notok "python.mk '$target' passes the vendored excludes" "$recipe" ;;
  esac
done

# ci.yml's Lint and Format check steps walk the same tree, so they exclude the same set.
ci="${ROOT}/.github/workflows/ci.yml"
lint_ex="$(grep -E 'run: ruff check ' "$ci" | grep -oE -- '--exclude [a-z-]+' | sort | tr '\n' ' ')"
fmt_ex="$(grep -E 'run: ruff format --check ' "$ci" | grep -oE -- '--exclude [a-z-]+' | sort | tr '\n' ' ')"
if [ -n "$fmt_ex" ] && [ "$lint_ex" = "$fmt_ex" ]; then
  ok "ci.yml Lint excludes what Format check excludes ($lint_ex)"
else
  notok "ci.yml Lint excludes what Format check excludes" "lint: [$lint_ex] format: [$fmt_ex]"
fi

RUFF="$(command -v ruff || true)"
if [ -z "$RUFF" ]; then
  echo "note - ruff not installed here: the simulated-consumer half did not run"
else
  work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
  mkdir -p "$work/bin" "$work/make" "$work/common" "$work/stack-common" "$work/lib/dep" "$work/src"
  ln -s "$RUFF" "$work/bin/ruff"
  cp "$mk" "$work/make/python.mk"
  printf 'include make/python.mk\n' > "$work/Makefile"
  bad='import os\n'                      # F401: unused import
  for d in common stack-common lib/dep; do printf "$bad" > "$work/$d/vendored.py"; done
  printf 'x = 1\n' > "$work/src/own.py"
  if out="$(make -s -C "$work" CONDA_PREFIX="$work" lint 2>&1)"; then
    ok "a lint error only in vendored trees does not fail make lint"
  else
    notok "a lint error only in vendored trees does not fail make lint" "$out"
  fi
  printf "$bad" > "$work/src/own.py"
  if make -s -C "$work" CONDA_PREFIX="$work" lint >/dev/null 2>&1; then
    notok "a lint error in the repo's OWN code still fails make lint"
  else
    ok "a lint error in the repo's OWN code still fails make lint"
  fi
fi

echo
[ "$fail" -eq 0 ] && { echo "PASS: $pass"; exit 0; }
echo "FAIL: $fail failed, $pass passed"; exit 1
