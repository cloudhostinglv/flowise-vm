#!/usr/bin/env bash
# seed-credential.sh — first-boot helper for a per-client Flowise VM.
#
# What it does (idempotently):
#   1. waits for Flowise to be up on http://127.0.0.1:3000
#   2. registers the first admin account (Flowise v3 Passport auth) if not present
#   3. logs in to obtain the JWT auth cookies
#   4. creates a ChatOpenAI credential (credentialName "openAIApi") holding the
#      client's avots key, so chatflows can use avots.ai out of the box
#
# Wiring reminder (done in the Flowise UI, see README): the ChatOpenAI node's
# Additional Parameters -> Base Path must be set to AVOTS_BASE_URL. This script
# only injects the API key as a credential; it cannot set a node's Base Path.
#
# Reads everything from the environment (typically the same .env compose uses):
#   AVOTS_API_KEY, AVOTS_BASE_URL, ADMIN_EMAIL, ADMIN_NAME, ADMIN_PASSWORD
#
# Safe to re-run: registration and credential creation are both no-ops if already done.
set -uo pipefail

BASE="${FLOWISE_BASE:-http://127.0.0.1:3000}"
API="$BASE/api/v1"
CRED_NAME="${CRED_NAME:-avots}"          # display name of the credential inside Flowise
CRED_TYPE="openAIApi"                     # ChatOpenAI uses the openAIApi credential type
COOKIES="$(mktemp)"
trap 'rm -f "$COOKIES"' EXIT

: "${AVOTS_API_KEY:?set AVOTS_API_KEY=av_mcp_...}"
: "${ADMIN_EMAIL:?set ADMIN_EMAIL}"
: "${ADMIN_PASSWORD:?set ADMIN_PASSWORD}"
ADMIN_NAME="${ADMIN_NAME:-Administrator}"
AVOTS_BASE_URL="${AVOTS_BASE_URL:-https://api.avots.ai/openai/v1}"

log() { printf '[seed] %s\n' "$*"; }

json_escape() { # minimal escaper for values we embed; prefer python if available
  if command -v python3 >/dev/null 2>&1; then
    python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$1"
  else
    printf '"%s"' "${1//\"/\\\"}"
  fi
}

# ---- 1) wait for Flowise ----
log "waiting for Flowise at $BASE ..."
for i in $(seq 1 60); do
  if curl -fsS -o /dev/null "$BASE/api/v1/ping" 2>/dev/null \
     || curl -fsS -o /dev/null "$BASE/" 2>/dev/null; then
    log "Flowise is up."
    break
  fi
  sleep 3
  [ "$i" = 60 ] && { log "ERROR: Flowise did not become ready in time."; exit 1; }
done

# ---- 2) register first admin (idempotent) ----
# v3: POST /api/v1/account/register with {user:{name,email,credential}}.
# If an account already exists this returns a non-2xx, which we treat as "already done".
reg_body=$(cat <<JSON
{"user":{"name":$(json_escape "$ADMIN_NAME"),"email":$(json_escape "$ADMIN_EMAIL"),"credential":$(json_escape "$ADMIN_PASSWORD")}}
JSON
)
reg_code=$(curl -sS -o /tmp/seed_register.json -w '%{http_code}' \
  -H 'Content-Type: application/json' \
  -X POST "$API/account/register" -d "$reg_body" || echo "000")
case "$reg_code" in
  2*) log "admin account registered ($reg_code)." ;;
  *)  log "register returned $reg_code (account likely already exists — continuing)."
      [ -s /tmp/seed_register.json ] && log "  body: $(head -c 300 /tmp/seed_register.json)" ;;
esac

# NOTE: recent Flowise releases may require e-mail verification before the admin
# can log in (see GHSA-v5w9-prxf-w882 hardening). If login below fails with an
# "unverified"/"not confirmed" style error, finish setup once in the browser
# (set the admin password / verify), then re-run this script to inject the key.

# ---- 3) login -> JWT cookies ----
login_body=$(cat <<JSON
{"email":$(json_escape "$ADMIN_EMAIL"),"password":$(json_escape "$ADMIN_PASSWORD")}
JSON
)
login_code=$(curl -sS -c "$COOKIES" -o /tmp/seed_login.json -w '%{http_code}' \
  -H 'Content-Type: application/json' \
  -X POST "$API/account/login" -d "$login_body" || echo "000")
if ! [[ "$login_code" =~ ^2 ]]; then
  log "ERROR: login failed ($login_code). Cannot inject credential non-interactively."
  [ -s /tmp/seed_login.json ] && log "  body: $(head -c 300 /tmp/seed_login.json)"
  log "Finish admin setup in the browser at https://\$DOMAIN, then re-run this script."
  exit 2
fi
log "logged in."

# ---- 4) create the avots openAIApi credential (idempotent) ----
# Skip if a credential of this type+name already exists.
existing=$(curl -sS -b "$COOKIES" "$API/credentials?credentialName=$CRED_TYPE" 2>/dev/null || echo '[]')
if printf '%s' "$existing" | grep -q "\"name\":\"$CRED_NAME\""; then
  log "credential '$CRED_NAME' already present — nothing to do."
  exit 0
fi

cred_body=$(cat <<JSON
{"name":$(json_escape "$CRED_NAME"),"credentialName":"$CRED_TYPE","plainDataObj":{"openAIApiKey":$(json_escape "$AVOTS_API_KEY")}}
JSON
)
cred_code=$(curl -sS -b "$COOKIES" -o /tmp/seed_cred.json -w '%{http_code}' \
  -H 'Content-Type: application/json' \
  -X POST "$API/credentials" -d "$cred_body" || echo "000")
if [[ "$cred_code" =~ ^2 ]]; then
  log "credential '$CRED_NAME' ($CRED_TYPE) created. avots base URL: $AVOTS_BASE_URL"
  log "Remember: set ChatOpenAI -> Base Path = $AVOTS_BASE_URL in each chatflow."
else
  log "ERROR: credential create failed ($cred_code)."
  [ -s /tmp/seed_cred.json ] && log "  body: $(head -c 300 /tmp/seed_cred.json)"
  exit 3
fi
