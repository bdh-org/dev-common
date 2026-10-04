#!/usr/bin/env bash
# grok-install.test.sh -- the gate for .github/actions/grok-install
# (bdh-org/dev-common#283).
#
# The properties a careless rewrite would break:
#   - a tarball whose sha512 does not match the PIN is refused, and no binary is
#     left behind for a later step to run;
#   - a malformed pin is refused rather than compared as an empty string;
#   - a tarball without package/bin/grok.br fails loudly, naming the layout;
#   - a matching tarball yields an executable, decompressed binary at `path`.
#
# The tarball is a local file:// fixture holding a stub "binary": no network.
#
# Usage:  bash tests/grok-install.test.sh      (or: make test)

set -uo pipefail   # deliberately NOT -e: every case runs, then we report

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL_SH="$REPO_ROOT/.github/actions/grok-install/install.sh"

pass=0
fail=0
CASE="(none)"

ok()    { pass=$((pass + 1)); printf 'ok     - %s: %s\n' "$CASE" "$1"; }
notok() { fail=$((fail + 1)); printf 'NOT OK - %s: %s\n' "$CASE" "$1"; }
assert_eq() { if [ "$1" = "$2" ]; then ok "$3"; else notok "$3"; printf '         want: %s\n         got:  %s\n' "$1" "$2"; fi; }
assert_contains() { case "$1" in *"$2"*) ok "$3";; *) notok "$3 (no '$2' in output)";; esac; }

if ! command -v node >/dev/null 2>&1 && ! command -v brotli >/dev/null 2>&1; then
  # A FAILURE, not a skip: install.sh needs one of these too, so a host without
  # them cannot run the action either, and a skipped gate reads as green.
  echo "NOT OK - needs node or brotli (the action itself needs one too)"; exit 1
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

compress() {  # $1 in -> $2 out (brotli)
  if command -v brotli >/dev/null 2>&1; then brotli -f -o "$2" "$1"
  else node -e 'const z=require("zlib"),f=require("fs");f.writeFileSync(process.argv[2],z.brotliCompressSync(f.readFileSync(process.argv[1])))' "$1" "$2"; fi
}
integrity() { printf 'sha512-%s' "$(openssl dgst -sha512 -binary "$1" | openssl base64 -A)"; }

# Fixture: a tarball shaped like @xai-official/grok-linux-x64.
mkdir -p "$TMP/fx/package/bin"
printf '#!/bin/sh\necho fake-grok-ok\n' > "$TMP/stub"
compress "$TMP/stub" "$TMP/fx/package/bin/grok.br"
tar -czf "$TMP/good.tgz" -C "$TMP/fx" package
GOOD_INT="$(integrity "$TMP/good.tgz")"

mkdir -p "$TMP/bad/package"
echo '{}' > "$TMP/bad/package/package.json"
tar -czf "$TMP/nolayout.tgz" -C "$TMP/bad" package
NOLAYOUT_INT="$(integrity "$TMP/nolayout.tgz")"

run() {  # $1 tarball $2 integrity $3 dest -> sets OUT, RC
  OUT="$(GROK_VERSION=9.9.9 GROK_INTEGRITY="$2" GROK_DEST="$3" \
         GROK_TARBALL_URL="file://$1" GITHUB_OUTPUT="" bash "$INSTALL_SH" 2>&1)"
  RC=$?
}

CASE="matching pin"
run "$TMP/good.tgz" "$GOOD_INT" "$TMP/d1"
assert_eq 0 "$RC" "exits 0"
assert_eq "$TMP/d1/grok" "$(printf '%s\n' "$OUT" | tail -1)" "prints the binary path"
if [ -x "$TMP/d1/grok" ]; then ok "binary is executable"; else notok "binary is executable"; fi
assert_eq "fake-grok-ok" "$("$TMP/d1/grok" 2>&1)" "binary is the decompressed stub"

CASE="mismatched pin"
run "$TMP/good.tgz" "sha512-AAAA" "$TMP/d2"
if [ "$RC" -ne 0 ]; then ok "exits non-zero"; else notok "exits non-zero"; fi
assert_contains "$OUT" "integrity MISMATCH" "names the mismatch"
if [ ! -e "$TMP/d2/grok" ]; then ok "leaves no binary behind"; else notok "leaves no binary behind"; fi

CASE="malformed pin"
run "$TMP/good.tgz" "AAAA" "$TMP/d3"
if [ "$RC" -ne 0 ]; then ok "exits non-zero"; else notok "exits non-zero"; fi
assert_contains "$OUT" "must look like sha512-" "explains the format"

CASE="wrong package layout"
run "$TMP/nolayout.tgz" "$NOLAYOUT_INT" "$TMP/d4"
if [ "$RC" -ne 0 ]; then ok "exits non-zero"; else notok "exits non-zero"; fi
assert_contains "$OUT" "package/bin/grok.br" "names the missing path"

CASE="GITHUB_OUTPUT"
GO="$TMP/gho"; : > "$GO"
GROK_VERSION=9.9.9 GROK_INTEGRITY="$GOOD_INT" GROK_DEST="$TMP/d5" \
  GROK_TARBALL_URL="file://$TMP/good.tgz" GITHUB_OUTPUT="$GO" bash "$INSTALL_SH" >/dev/null 2>&1
assert_contains "$(cat "$GO")" "path=$TMP/d5/grok" "writes path"
assert_contains "$(cat "$GO")" "version=9.9.9" "writes version"

echo
echo "grok-install: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
