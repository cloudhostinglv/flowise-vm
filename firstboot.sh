#!/usr/bin/env bash
# firstboot.sh — one-shot first-boot provisioning for the Flowise per-client VM.
#
# Runs ONCE via flowise-firstboot.service. Idempotent; disables itself at the end.
# Brings up: flowise (product) + panel (CloudHosting setup UI) + caddy (TLS).
#
# Steps:
#   1. Generate the per-VM Flowise secrets into .env if absent.
#   2. Ensure ./paneldata (panel HOME) owned by the panel uid.
#   3. Derive PANEL_DOMAIN from the primary IPv4 if blank.
#   4. docker compose pull && up -d.
#   5. Disable this oneshot.
# No host applier: builders don't write product config from the panel (the client
# configures providers inside Flowise's own UI).

set -euo pipefail

APP_DIR="/opt/flowise-vm"
ENV_FILE="${APP_DIR}/.env"
COMPOSE_FILE="${APP_DIR}/docker-compose.yml"
PANEL_UID="${PANEL_UID:-1000}"
PANEL_GID="${PANEL_GID:-1000}"

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
  # remove any empty placeholder line, then append
  sed -i "/^${key}=$/d" "${ENV_FILE}" 2>/dev/null || true
  printf '%s=%s\n' "${key}" "${val}" >> "${ENV_FILE}"
  log "Generated ${key}"
}

# --- 1. Per-VM Flowise secrets ------------------------------------------------------
for k in FLOWISE_SECRETKEY_OVERWRITE JWT_AUTH_TOKEN_SECRET JWT_REFRESH_TOKEN_SECRET TOKEN_HASH_SECRET EXPRESS_SESSION_SECRET; do
  gen_secret "$k"
done

# --- 2. Panel HOME dir (session.key + brand.json persistence) -----------------------
mkdir -p "${APP_DIR}/paneldata"
chown -R "${PANEL_UID}:${PANEL_GID}" "${APP_DIR}/paneldata"
chmod 0700 "${APP_DIR}/paneldata"

# --- Load .env for PANEL_DOMAIN -----------------------------------------------------
# shellcheck disable=SC1090
set -a && . "${ENV_FILE}" && set +a || true

# --- 3. Derive PANEL_DOMAIN from the primary IPv4 if blank --------------------------
if [ -z "${PANEL_DOMAIN:-}" ]; then
  IP="$(ip -4 route get 1.1.1.1 2>/dev/null | grep -oE 'src [0-9.]+' | awk '{print $2}' | head -n1)"
  [ -n "${IP}" ] || IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
  [ -n "${IP}" ] || die "could not determine primary IPv4 to derive PANEL_DOMAIN"
  O3="$(printf '%s' "${IP}" | cut -d. -f3)"; O4="$(printf '%s' "${IP}" | cut -d. -f4)"
  PANEL_DOMAIN="vps-${O3}-${O4}.cloudhosting.lv"
  log "Derived PANEL_DOMAIN=${PANEL_DOMAIN} from IP ${IP}"
  if grep -q '^PANEL_DOMAIN=' "${ENV_FILE}" 2>/dev/null; then
    sed -i "s|^PANEL_DOMAIN=.*|PANEL_DOMAIN=${PANEL_DOMAIN}|" "${ENV_FILE}"
  else
    printf 'PANEL_DOMAIN=%s\n' "${PANEL_DOMAIN}" >> "${ENV_FILE}"
  fi
else
  log "PANEL_DOMAIN already set: ${PANEL_DOMAIN}"
fi

# --- 4. Pull + start ----------------------------------------------------------------
log "docker compose pull"; docker compose -f "${COMPOSE_FILE}" pull
log "docker compose up -d"; docker compose -f "${COMPOSE_FILE}" up -d

# --- 4b. Install the host-side software updater (panel "Update software" button) -----
# The panel (unprivileged) writes ./paneldata/.update-request; this host updater
# git-pulls the repo + docker compose pull/up. No applier (builders need no restart).
log "Installing updater units"
APPLIER_LIB="/usr/local/lib/cloudhosting"
install -d -m 0755 "${APPLIER_LIB}"
install -m 0755 "${APP_DIR}/applier/update.sh" "${APPLIER_LIB}/update.sh"
cp "${APP_DIR}/applier/cloudhosting-updater.path"    /etc/systemd/system/
cp "${APP_DIR}/applier/cloudhosting-updater.service" /etc/systemd/system/
cat > /etc/cloudhosting-panel.env <<EOF
PRODUCT=flowise
COMPOSE_FILE=${COMPOSE_FILE}
COMPOSE_PROJECT_DIR=${APP_DIR}
REPO_DIR=${APP_DIR}
DATA_DIR=${APP_DIR}/paneldata
UPDATE_BRANCH=main
EOF
chmod 0644 /etc/cloudhosting-panel.env
systemctl daemon-reload
systemctl enable --now cloudhosting-updater.path
log "Updater enabled (watching ${APP_DIR}/paneldata/.update-request)"
"${APPLIER_LIB}/update.sh" --stamp-only || log "WARN: initial version stamp failed"

# --- 5. Disable this oneshot --------------------------------------------------------
log "Disabling flowise-firstboot.service (provisioning complete)"
systemctl disable flowise-firstboot.service 2>/dev/null || true

log "First boot complete. Panel: https://${PANEL_DOMAIN}:8443  ·  Flowise: https://${PANEL_DOMAIN}"
