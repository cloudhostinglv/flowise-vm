#!/usr/bin/env bash
# firstboot.sh — one-shot first-boot provisioning for the Flowise per-client VM.
#
# Runs ONCE via flowise-firstboot.service. Idempotent; disables itself at the end.
# Vanilla product: brings up Flowise on its own standard port (:3000), no CloudHosting
# panel/Caddy layer. The customer reaches Flowise directly at http://<host>:3000 and
# uses Flowise's built-in account/login + provider config (avots = OpenAI-compatible).
#
# Steps:
#   1. Generate the per-VM Flowise secrets into .env if absent.
#   2. docker compose pull && up -d.
#   3. Disable this oneshot.

set -euo pipefail

APP_DIR="/opt/flowise-vm"
ENV_FILE="${APP_DIR}/.env"
COMPOSE_FILE="${APP_DIR}/docker-compose.yml"

log() { printf '[firstboot %s] %s\n' "$(date -u +%FT%TZ)" "$*"; }
die() { printf '[firstboot ERROR] %s\n' "$*" >&2; exit 1; }

cd "${APP_DIR}" || die "missing ${APP_DIR}"
touch "${ENV_FILE}"; chmod 0600 "${ENV_FILE}"

# Append KEY=<random hex> to .env if the key isn't already set.
gen_secret() {
  local key="$1"
  grep -q "^${key}=." "${ENV_FILE}" 2>/dev/null && return 0
  local val
  val="$(openssl rand -hex 32 2>/dev/null || head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')"
  sed -i "/^${key}=$/d" "${ENV_FILE}" 2>/dev/null || true
  printf '%s=%s\n' "${key}" "${val}" >> "${ENV_FILE}"
  log "Generated ${key}"
}

# --- 1. Per-VM Flowise secrets ------------------------------------------------------
for k in FLOWISE_SECRETKEY_OVERWRITE JWT_AUTH_TOKEN_SECRET JWT_REFRESH_TOKEN_SECRET TOKEN_HASH_SECRET EXPRESS_SESSION_SECRET; do
  gen_secret "$k"
done

# --- 2. Pull + start ----------------------------------------------------------------
log "docker compose pull"; docker compose -f "${COMPOSE_FILE}" pull
log "docker compose up -d"; docker compose -f "${COMPOSE_FILE}" up -d

# --- 3. Disable this oneshot --------------------------------------------------------
log "Disabling flowise-firstboot.service (provisioning complete)"
systemctl disable flowise-firstboot.service 2>/dev/null || true

IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
log "First boot complete. Flowise: http://${IP:-<host>}:3000 (create your admin account on first visit)."
