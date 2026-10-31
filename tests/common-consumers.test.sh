#!/usr/bin/env bash
# common-consumers.test.sh -- `make common-consumers` mints a token per org and
# never reports an empty answer as success (bdh-org/dev-common#322).
#
# The defect: it read gh-<org>.token PAT files that were revoked, so the glob
# matched nothing and it printed an empty list with exit 0. `gh-app-token` and
# `gh` are stubbed on PATH; the stub `gh` answers from fixture files keyed by
# org and repo, so a case controls exactly what each org returns.
#
# Usage:  bash tests/common-consumers.test.sh      (or: make test)
set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0
ok()    { pass=$((pass + 1)); printf 'ok     - %s\n' "$1"; }
notok() { fail=$((fail + 1)); printf 'NOT OK - %s\n         got: %s\n' "$1" "${2:-}"; }

mkdir -p "$TMP/bin" "$TMP/fx"
printf 'include %s\n' "$REPO_ROOT/make/utils.mk" > "$TMP/Makefile"

# gh-app-token <org>: prints a token unless fx/notoken-<org> exists.
cat > "$TMP/bin/gh-app-token" <<STUB
#!/usr/bin/env bash
[ -e "$TMP/fx/notoken-\$1" ] && { echo "no App config" >&2; exit 1; }
echo "tok-\$1"
STUB
# gh repo list <org> ... -> fx/repos-<org>; gh api repos/<r>/contents/.gitmodules -> fx/gm-<owner>_<name>
cat > "$TMP/bin/gh" <<STUB
#!/usr/bin/env bash
case "\$1 \$2" in
  "repo list") cat "$TMP/fx/repos-\$3" 2>/dev/null; exit 0 ;;
  "api "*) r="\${2#repos/}"; r="\${r%/contents/.gitmodules}"; f="$TMP/fx/gm-\${r/\//_}"
           [ -e "\$f" ] && cat "\$f" || exit 1 ;;
esac
STUB
chmod +x "$TMP/bin/"*

run() { OUT="$(PATH="$TMP/bin:$PATH" make -C "$TMP" --no-print-directory common-consumers \
          COMMON_CONSUMER_ORGS="$*" 2>&1)"; RC=$?; }

printf 'o1/a\no1/b\n' > "$TMP/fx/repos-o1"
printf 'o2/c\n' > "$TMP/fx/repos-o2"
printf '[submodule "common"]\n\turl = https://github.com/bdh-org/dev-common.git\n' > "$TMP/fx/gm-o1_a"
printf '[submodule "x"]\n\turl = https://github.com/o2/other.git\n' > "$TMP/fx/gm-o2_c"

run o1 o2
[ "$RC" = 0 ] && [ "$OUT" = "o1/a" ] && ok "lists exactly the repo whose .gitmodules names dev-common" \
  || notok "wanted o1/a and exit 0" "rc=$RC $OUT"

touch "$TMP/fx/notoken-o2"
run o1 o2
[ "$RC" != 0 ] && [[ "$OUT" == *"could not mint a token for o2"* ]] \
  && ok "an org it cannot mint for is an error naming the org" || notok "wanted a named mint failure" "rc=$RC $OUT"
rm "$TMP/fx/notoken-o2"

run o1 empty
[ "$RC" != 0 ] && [[ "$OUT" == *"empty listed ZERO repos"* ]] \
  && ok "an org listing no repos is an error, not an empty answer" || notok "wanted a zero-repos failure" "rc=$RC $OUT"

run o2
[ "$RC" != 0 ] && [[ "$OUT" == *"ZERO consumers"* ]] \
  && ok "zero consumers is a failure, never exit 0" || notok "wanted a zero-consumers failure" "rc=$RC $OUT"

printf '\npassed: %d   failed: %d\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
