#!/usr/bin/env bash
# =============================================================================
#  01-dnsmasq-leases.sh
#  Adds static DHCP leases and DNS records for the IaC LXCs
#
#  Standalone: bash -c "$(curl -fsSL https://raw.githubusercontent.com/MoodyLondon/proxmox/main/iac/01-dnsmasq-leases.sh)"
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

# ── Collect settings (skip if already set by orchestrator) ────────────────────
if [[ -z "${DNSMASQ_CTID:-}" ]]; then
  DNSMASQ_CTID=$(w_input "dnsmasq LXC" \
    "Container ID of your dnsmasq LXC:" "100") || exit 1
  if ! pct status "$DNSMASQ_CTID" &>/dev/null; then
    w_msg "Error" "Container $DNSMASQ_CTID not found.\nRun your bootstrap.sh first."
    exit 1
  fi
fi

FORGEJO_IP="${FORGEJO_IP:-10.10.10.10}"
RUNNER_IP="${RUNNER_IP:-10.10.10.11}"
KOMODO_IP="${KOMODO_IP:-10.10.10.12}"
DOMAIN="${DOMAIN:-lan}"

if ! pct status "$DNSMASQ_CTID" &>/dev/null; then
  msg_error "dnsmasq container $DNSMASQ_CTID not found"
fi

# ── Confirm ───────────────────────────────────────────────────────────────────
w_yesno "Confirm" "\
Add static DHCP leases to dnsmasq CT${DNSMASQ_CTID}:\n\
\n\
  forgejo  →  ${FORGEJO_IP}  (forgejo.${DOMAIN})\n\
  runner   →  ${RUNNER_IP}  (runner.${DOMAIN})\n\
  komodo   →  ${KOMODO_IP}  (komodo.${DOMAIN})\n\
\n\
Proceed?" || exit 0

# ── Install ───────────────────────────────────────────────────────────────────
do_install() {
  echo "10|Removing any previous IaC entries"
  pct exec "$DNSMASQ_CTID" -- bash -c \
    "sed -i '/# IaC Bootstrap/,/# END IaC Bootstrap/d' /etc/dnsmasq.conf" 2>/dev/null || true

  echo "40|Adding static leases and DNS records"
  pct exec "$DNSMASQ_CTID" -- bash -c "cat >> /etc/dnsmasq.conf << 'EOF'

# IaC Bootstrap
dhcp-host=forgejo,${FORGEJO_IP}
dhcp-host=runner,${RUNNER_IP}
dhcp-host=komodo,${KOMODO_IP}
address=/forgejo.${DOMAIN}/${FORGEJO_IP}
address=/runner.${DOMAIN}/${RUNNER_IP}
address=/komodo.${DOMAIN}/${KOMODO_IP}
# END IaC Bootstrap
EOF"

  echo "80|Restarting dnsmasq"
  pct exec "$DNSMASQ_CTID" -- systemctl restart dnsmasq

  echo "100|Done"
  sleep 1
}

run_with_gauge "dnsmasq Static Leases" "Configuring dnsmasq..." do_install

msg_ok "Static leases added — forgejo/runner/komodo pinned to fixed IPs"
