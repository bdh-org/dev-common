#!/usr/bin/env bash
# entrypoint-vault.sh — shared, config-driven fetch-at-startup Vault wrapper.
#
# Promotion of freddyb's proven single-secret PoC (home-infra#24) to dev-common
# so EVERY service adopts one DRY wrapper. It is the container ENTRYPOINT: it
# logs in to Vault with the service's OWN AppRole, reads one-or-more secrets
# described by a MANIFEST, exports each as the target ENV VAR, scrubs the Vault
# login creds from the environment, then exec's the real command (the CMD).
#
# ---------------------------------------------------------------------------
# ENV VARS (login)
#   VAULT_ADDR       Vault API base URL, e.g. http://<control-tailnet-ip>:8200
#   VAULT_ROLE_ID    service AppRole role_id   (non-secret; bake or inject)
#   VAULT_SECRET_ID  service AppRole secret_id (SECRET, short-TTL, inject at run)
#
# MANIFEST (what to fetch) — pick ONE source:
#   VAULT_SECRETS_SPEC  inline manifest text (newline-separated), OR
#   VAULT_SECRETS_FILE  path to a manifest file baked into the image.
#   Format, one secret per line ('#' comments + blank lines ignored):
#       <kv-data-path> <field> <ENV_VAR>
#   e.g.
#       kv/data/prod/hog/apikeys        census     CENSUS_API_KEY
#       kv/data/prod/hog/apikeys        eia        EIA_API_KEY
#       kv/data/prod/refdims/connection url        REFDIMS_URL
#   The path is the KV-v2 CAPABILITY path (kv/data/..., NOT kv/...), matching
#   the Vault policy grants. Multiple fields on the same path share ONE read;
#   multiple distinct paths are each read once (hog reads its own apikeys plus a
#   cross-granted refdims/connection). A single-secret manifest reproduces the
#   freddyb PoC exactly, so freddyb can later adopt this wrapper unchanged.
#
# SAFE-MERGE / FALLBACK
#   If VAULT_ROLE_ID *or* VAULT_SECRET_ID is empty/unset, the Vault fetch is
#   SKIPPED and we exec the app unchanged — so each service keeps its existing
#   key source (mounted apikeys file / env vars). This makes adoption safe to
#   merge/deploy BEFORE Vault secret-id delivery is wired: nothing breaks
#   without creds. Retiring the file mount + env fallbacks is home-infra#25,
#   only AFTER a service is proven reading cleanly from Vault.
#
# FAIL-CLOSED
#   If creds ARE provided but the fetch fails (Vault sealed/unreachable/bad
#   secret_id/denied path/missing field), this exits non-zero. With
#   `restart: unless-stopped` the container is brought back and retries — the
#   crude "retry until Vault is up" loop the architecture doc calls for. A
#   persistently bad secret_id crash-loops (visible in logs); that is intended
#   over silently masking a broken Vault by falling back to stale file creds.
#
# SECURITY
#   role_id/secret_id + the manifest are passed to python via the ENVIRONMENT
#   (already exported), never on argv (nothing sensitive in `ps`/logs). The
#   Vault client token stays inside python. Secret VALUES are returned NUL-
#   delimited through a mode-600 temp file (mktemp; unlinked immediately after
#   read) so python's exit status can be checked — bash command substitution
#   `$(...)` strips NUL bytes and would hide a failure. Only ENV VAR *names*
#   are ever logged, never values. Do NOT add `set -x`.
#
# WHY PYTHON (not curl/jq/vault): service images are python:3.13-slim, which
# ship neither curl, jq, nor the vault binary — but python3 is present. Doing
# the login + KV reads with python's stdlib (urllib+json) keeps images lean.
# ---------------------------------------------------------------------------
set -euo pipefail

log() { printf '[entrypoint-vault] %s\n' "$*" >&2; }

# ---- Fallback: no Vault creds -> no-op passthrough (safe pre-cutover) --------
if [ -z "${VAULT_ROLE_ID:-}" ] || [ -z "${VAULT_SECRET_ID:-}" ]; then
  log "VAULT_ROLE_ID/VAULT_SECRET_ID not set — skipping Vault fetch; using existing file/env fallbacks"
  exec "$@"
fi

: "${VAULT_ADDR:?VAULT_ROLE_ID/VAULT_SECRET_ID are set but VAULT_ADDR is empty — cannot reach Vault}"

# ---- Resolve the secrets manifest -------------------------------------------
if [ -n "${VAULT_SECRETS_SPEC:-}" ]; then
  _spec="$VAULT_SECRETS_SPEC"
elif [ -n "${VAULT_SECRETS_FILE:-}" ] && [ -f "${VAULT_SECRETS_FILE}" ]; then
  _spec="$(cat "$VAULT_SECRETS_FILE")"
else
  log "FATAL Vault creds are set but no manifest (set VAULT_SECRETS_SPEC or VAULT_SECRETS_FILE)"
  exit 1
fi

log "fetching secrets from Vault at ${VAULT_ADDR} (AppRole login)..."

# ---- Fetch (python3 stdlib; slim images lack curl/jq/vault) ------------------
umask 077
_tmp="$(mktemp)"
trap 'rm -f "$_tmp"' EXIT

if ! _VAULT_SPEC="$_spec" python3 - >"$_tmp" <<'PY'
import json, os, sys, urllib.request, urllib.error

addr = os.environ["VAULT_ADDR"].rstrip("/")
role_id = os.environ["VAULT_ROLE_ID"]
secret_id = os.environ["VAULT_SECRET_ID"]
spec_text = os.environ["_VAULT_SPEC"]

# Parse manifest -> ordered [(path, field, env_var)].
entries = []
for lineno, raw in enumerate(spec_text.splitlines(), 1):
    line = raw.strip()
    if not line or line.startswith("#"):
        continue
    parts = line.split()
    if len(parts) != 3:
        sys.stderr.write(
            f"[entrypoint-vault] manifest line {lineno}: expected "
            f"'<path> <field> <ENV_VAR>', got: {raw!r}\n"
        )
        sys.exit(1)
    entries.append(tuple(parts))

if not entries:
    sys.stderr.write("[entrypoint-vault] manifest is empty after stripping comments/blanks\n")
    sys.exit(1)


def _request(url, method, headers, payload=None):
    data = json.dumps(payload).encode() if payload is not None else None
    hdrs = {"Content-Type": "application/json", **headers}
    req = urllib.request.Request(url, data=data, method=method, headers=hdrs)
    with urllib.request.urlopen(req, timeout=10) as resp:
        return json.load(resp)


try:
    # 1. AppRole login -> short-TTL client token.
    login = _request(
        f"{addr}/v1/auth/approle/login", "POST", {},
        {"role_id": role_id, "secret_id": secret_id},
    )
    token = login["auth"]["client_token"]

    # 2. Read each unique KV v2 path once (path is the capability path, kv/data/...).
    cache = {}
    for path, _field, _var in entries:
        if path not in cache:
            secret = _request(f"{addr}/v1/{path}", "GET", {"X-Vault-Token": token})
            cache[path] = secret["data"]["data"]
except urllib.error.HTTPError as e:  # 4xx/5xx (bad secret_id, sealed, denied path)
    sys.stderr.write(f"[entrypoint-vault] Vault HTTP {e.code} at {e.url}\n")
    sys.exit(1)
except urllib.error.URLError as e:  # DNS / connect / route failure
    sys.stderr.write(f"[entrypoint-vault] Vault unreachable: {e.reason}\n")
    sys.exit(1)
except (KeyError, ValueError) as e:  # unexpected JSON shape
    sys.stderr.write(f"[entrypoint-vault] unexpected Vault response shape: {e!r}\n")
    sys.exit(1)

# 3. Emit NUL-delimited VAR\0VALUE\0 pairs (safe for spaces/newlines/quotes in
#    values, e.g. a Postgres DSN). Only names reach the log, never values.
out = sys.stdout.buffer
for path, field, var in entries:
    data = cache[path]
    if field not in data:
        sys.stderr.write(f"[entrypoint-vault] field '{field}' not present at {path}\n")
        sys.exit(1)
    val = data[field]
    if val is None or val == "":
        sys.stderr.write(f"[entrypoint-vault] field '{field}' at {path} is empty\n")
        sys.exit(1)
    out.write(var.encode() + b"\0" + str(val).encode() + b"\0")
out.flush()
PY
then
  log "FATAL Vault fetch failed (see errors above) — refusing to start with incomplete secrets"
  exit 1
fi

# ---- Export the fetched vars (NUL-delimited pairs; no secret ever logged) ----
_count=0
while IFS= read -r -d '' _var && IFS= read -r -d '' _val; do
  export "$_var=$_val"
  _count=$((_count + 1))
  log "populated ${_var} from Vault"
done < "$_tmp"
rm -f "$_tmp"; trap - EXIT
unset _val

if [ "$_count" -eq 0 ]; then
  log "FATAL no secrets were exported (empty manifest?)"
  exit 1
fi

# Scrub Vault login creds + wrapper config before handing off to the app.
unset VAULT_ROLE_ID VAULT_SECRET_ID VAULT_ADDR VAULT_SECRETS_SPEC VAULT_SECRETS_FILE

log "populated ${_count} secret(s) from Vault; exec: $*"
exec "$@"
