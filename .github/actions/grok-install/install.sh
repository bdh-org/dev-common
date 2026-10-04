#!/usr/bin/env bash
# install.sh -- fetch a PINNED Grok Build CLI into a private directory for one
# job (bdh-org/dev-common#283, bdh-org/home-infra#1188).
#
# xAI ships the Linux binary as the npm package @xai-official/grok-linux-x64,
# whose tarball holds a brotli-compressed static binary at package/bin/grok.br
# (the wrapper package's postinstall only decompresses it). So this fetches that
# ONE tarball, checks it against the sha512 the npm registry publishes for the
# version -- pinned here, not read from the registry at run time, so a
# republished or tampered tarball fails closed -- and decompresses it.
#
# Why not `npm install -g` or x.ai's curl installer: both write into the SHARED
# $HOME of forge's runner units (the race claude-code-install's lock exists for,
# bdh-org/home-infra#541), and the curl installer runs whatever x.ai serves that
# minute. A private directory per job needs no lock at all.
#
# In:  GROK_VERSION, GROK_INTEGRITY ("sha512-<base64>", npm's dist.integrity),
#      GROK_DEST (directory to install into),
#      GROK_TARBALL_URL (optional; default is the npm registry URL for the
#      version -- tests point it at a file:// fixture).
# Out: path=<abs path to the grok binary> and version=<GROK_VERSION> on
#      $GITHUB_OUTPUT when set; the path on stdout otherwise.
#
# To bump: `npm view @xai-official/grok-linux-x64@<v> dist.integrity` and change
# BOTH inputs in action.yml together.

set -euo pipefail

die() { echo "::error::grok-install: $*" >&2; exit 1; }

: "${GROK_VERSION:?GROK_VERSION is required}"
: "${GROK_INTEGRITY:?GROK_INTEGRITY is required}"
: "${GROK_DEST:?GROK_DEST is required}"
url="${GROK_TARBALL_URL:-https://registry.npmjs.org/@xai-official/grok-linux-x64/-/grok-linux-x64-${GROK_VERSION}.tgz}"

case "$GROK_INTEGRITY" in
  sha512-?*) want="${GROK_INTEGRITY#sha512-}" ;;
  *) die "GROK_INTEGRITY must look like sha512-<base64>, got '${GROK_INTEGRITY}'" ;;
esac

mkdir -p "$GROK_DEST"
work="$(mktemp -d "${GROK_DEST}/.fetch-XXXXXX")"
trap 'rm -rf "$work"' EXIT

curl -fsSL --retry 3 -o "$work/grok.tgz" "$url" || die "could not download ${url}"

got="$(openssl dgst -sha512 -binary "$work/grok.tgz" | openssl base64 -A)"
[ "$got" = "$want" ] || die "integrity MISMATCH for ${url}: want sha512-${want}, got sha512-${got}. Refusing to run it."

tar -xzf "$work/grok.tgz" -C "$work" package/bin/grok.br \
  || die "tarball from ${url} has no package/bin/grok.br -- did xAI change the package layout?"

out="$GROK_DEST/grok"
br="$work/package/bin/grok.br"
if command -v brotli >/dev/null 2>&1; then
  brotli -d -f -o "$out" "$br"
elif command -v node >/dev/null 2>&1; then
  node -e 'const z=require("zlib"),f=require("fs");f.writeFileSync(process.argv[2],z.brotliDecompressSync(f.readFileSync(process.argv[1])))' "$br" "$out"
else
  die "no brotli decompressor: need 'brotli' or 'node' on PATH"
fi
chmod 0755 "$out"
[ -s "$out" ] || die "decompressed binary at ${out} is empty"

if [ -n "${GITHUB_OUTPUT:-}" ]; then
  { echo "path=$out"; echo "version=$GROK_VERSION"; } >> "$GITHUB_OUTPUT"
  echo "grok ${GROK_VERSION} installed at ${out} (integrity verified)"
else
  echo "$out"
fi
