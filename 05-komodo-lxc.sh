#!/usr/bin/env bash
# =============================================================================
#  05-komodo-lxc.sh
#  Creates the Docker LXC via community script + installs Komodo
#
#  Standalone: bash -c "$(curl -fsSL https://raw.githubusercontent.com/MoodyLondon/proxmox/main/iac/05-komodo-lxc.sh)"
# =============================================================================

COMMON_URL="https://raw.githubusercontent.com/MoodyLondon/proxmox/main/iac/common.sh"
if [[ -f "$(dirname "$0")/common.sh" ]]; then
  source "$(dirname "$0")/common.sh"
else
  source <(curl -fsSL "$COMMON_URL")
fi

require_root
require_proxmox
require_whiptail
conf_load

KOMODO_IP="${KOMODO_IP:-10.10.10.12}"
GATEWAY="${GATEWAY:-10.10.10.1}"
DNS_IP="${DNS_IP:-10.10.10.2}"
BRIDGE="${BRIDGE:-vmbr1}"
STORAGE="${STORAGE:-local-lvm}"
KOMODO_PORT="${KOMODO_PORT:-9120}"

if [[ -z "${KOMODO_CTID:-}" ]]; then
  KOMODO_CTID=$(next_ctid 103)
fi

# Collect Komodo passkey if not set
if [[ -z "${KOMODO_PASSKEY:-}" ]]; then
  while true; do
    KOMODO_PASSKEY=$(w_pass "Komodo Passkey" \
      "Set a passkey for Komodo (min 8 chars).\nLeave blank to auto-generate:") || exit 1
    if [[ ${#KOMODO_PASSKEY} -eq 0 ]]; then
      KOMODO_PASSKEY=$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 32)
      w_msg "Komodo Passkey Generated" \
        "Your Komodo passkey:\n\n  ${KOMODO_PASSKEY}\n\nSave this — it will be in /root/proxmox-iac-secrets.txt"
      break
    elif [[ ${#KOMODO_PASSKEY} -ge 8 ]]; then
      break
    else
      w_msg "Too Short" "Passkey must be at least 8 characters."
    fi
  done
  conf_write "KOMODO_PASSKEY" "$KOMODO_PASSKEY"
fi

# ── Pre-flight info ───────────────────────────────────────────────────────────
w_msg "Komodo / Docker LXC — Community Script" "\
The Docker community script is about to run.\n\
\n\
When prompted, use these settings:\n\
\n\
  CT ID:       ${KOMODO_CTID}\n\
  Hostname:    komodo\n\
  IP:          ${KOMODO_IP}/24\n\
  Gateway:     ${GATEWAY}\n\
  DNS:         ${DNS_IP}\n\
  Bridge:      ${BRIDGE}\n\
  Storage:     ${STORAGE}\n\
  RAM:         2048 MB\n\
  CPU:         2 cores\n\
  Disk:        16 GB\n\
  Privileged:  YES  ← important for Docker\n\
\n\
After the script completes, Komodo will be installed\n\
and started automatically.\n\
\n\
Press OK then follow the script prompts."

# ── Run community script ──────────────────────────────────────────────────────
clear
echo ""
msg_step "Running Docker community script"
echo ""

bash -c "$(curl -fsSL https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/ct/docker.sh)" \
  || msg_error "Docker community script failed"

if ! pct status "$KOMODO_CTID" &>/dev/null; then
  KOMODO_CTID=$(w_input "Verify CT ID" \
    "What CT ID did the script create?" "$KOMODO_CTID") || exit 1
fi

conf_write "KOMODO_CTID" "$KOMODO_CTID"

# ── Wait for LXC ─────────────────────────────────────────────────────────────
echo ""
msg_info "Waiting for Komodo LXC to be ready"
wait_for_ct "$KOMODO_CTID" 60 || msg_error "Komodo LXC did not start in time"
msg_ok "Komodo LXC is running"

# ── Install Komodo ────────────────────────────────────────────────────────────
do_install() {
  echo "10|Creating Komodo directory"
  pct exec "$KOMODO_CTID" -- mkdir -p /opt/komodo

  echo "20|Writing Komodo compose file"
  pct exec "$KOMODO_CTID" -- bash -c "cat > /opt/komodo/compose.yml << 'COMPOSEOF'
services:
  komodo-core:
    image: ghcr.io/mbecker20/komodo:latest
    restart: unless-stopped
    depends_on: [mongo]
    ports:
      - '${KOMODO_PORT}:9120'
    environment:
      KOMODO_HOST: http://${KOMODO_IP}:${KOMODO_PORT}
      KOMODO_PASSKEY: ${KOMODO_PASSKEY}
      KOMODO_MONGO_ADDRESS: mongo:27017
    volumes:
      - komodo_repos:/etc/komodo/repos
      - komodo_stacks:/etc/komodo/stacks

  komodo-periphery:
    image: ghcr.io/mbecker20/periphery:latest
    restart: unless-stopped
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - /proc:/proc
      - komodo_repos:/etc/komodo/repos
      - komodo_stacks:/etc/komodo/stacks
    environment:
      PERIPHERY_PASSKEY: ${KOMODO_PASSKEY}

  mongo:
    image: mongo:7
    restart: unless-stopped
    volumes:
      - mongo_data:/data/db

volumes:
  mongo_data:
  komodo_repos:
  komodo_stacks:
COMPOSEOF"

  echo "40|Pulling Komodo images (this may take a minute)"
  pct exec "$KOMODO_CTID" -- bash -c \
    "cd /opt/komodo && docker compose pull -q" &>/dev/null

  echo "80|Starting Komodo"
  pct exec "$KOMODO_CTID" -- bash -c \
    "cd /opt/komodo && docker compose up -d" &>/dev/null

  echo "90|Saving passkey to secrets file"
  local sf="/root/proxmox-iac-secrets.txt"
  sed -i '/^KOMODO_/d' "$sf" 2>/dev/null || true
  cat >> "$sf" << EOF
KOMODO_URL=http://${KOMODO_IP}:${KOMODO_PORT}
KOMODO_PASSKEY=${KOMODO_PASSKEY}
EOF
  chmod 600 "$sf"

  echo "100|Done"
  sleep 1
}

run_with_gauge "Komodo" "Installing Komodo on Docker LXC..." do_install

# Wait for Komodo HTTP
echo ""
msg_info "Waiting for Komodo to be reachable"
if wait_for_http "http://${KOMODO_IP}:${KOMODO_PORT}" 120; then
  msg_ok "Komodo is up → http://${KOMODO_IP}:${KOMODO_PORT}"
else
  msg_warn "Komodo not responding yet — images may still be pulling, check manually"
fi
