#!/usr/bin/env bash
# =============================================================================
#  03-forgejo-lxc.sh
#  Creates the Forgejo LXC via community script
#
#  Standalone: bash -c "$(curl -fsSL https://raw.githubusercontent.com/MoodyLondon/proxmox/main/iac/03-forgejo-lxc.sh)"
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

FORGEJO_IP="${FORGEJO_IP:-10.10.10.10}"
GATEWAY="${GATEWAY:-10.10.10.1}"
DNS_IP="${DNS_IP:-10.10.10.2}"
BRIDGE="${BRIDGE:-vmbr1}"
STORAGE="${STORAGE:-local-lvm}"

# Suggest next available CT ID if not set
if [[ -z "${FORGEJO_CTID:-}" ]]; then
  FORGEJO_CTID=$(next_ctid 101)
fi

# ── Pre-flight info screen ────────────────────────────────────────────────────
w_msg "Forgejo LXC — Community Script" "\
The Forgejo community script is about to run.\n\
\n\
When prompted, use these settings:\n\
\n\
  CT ID:      ${FORGEJO_CTID}\n\
  Hostname:   forgejo\n\
  IP:         ${FORGEJO_IP}/24\n\
  Gateway:    ${GATEWAY}\n\
  DNS:        ${DNS_IP}\n\
  Bridge:     ${BRIDGE}\n\
  Storage:    ${STORAGE}\n\
  RAM:        1024 MB\n\
  CPU:        2 cores\n\
  Disk:       8 GB\n\
\n\
Press OK then follow the script prompts."

# ── Run community script ──────────────────────────────────────────────────────
clear
echo ""
msg_step "Running Forgejo community script"
echo ""

bash -c "$(curl -fsSL https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/ct/forgejo.sh)" \
  || msg_error "Forgejo community script failed"

# ── Verify ────────────────────────────────────────────────────────────────────
if ! pct status "$FORGEJO_CTID" &>/dev/null; then
  FORGEJO_CTID=$(w_input "Verify CT ID" \
    "What CT ID did the script create?\n(Check Proxmox UI if unsure)" \
    "$FORGEJO_CTID") || exit 1
fi

conf_write "FORGEJO_CTID" "$FORGEJO_CTID"

msg_ok "Forgejo LXC CT${FORGEJO_CTID} created at ${FORGEJO_IP}"
