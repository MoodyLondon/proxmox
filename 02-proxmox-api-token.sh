#!/usr/bin/env bash
# =============================================================================
#  02-proxmox-api-token.sh
#  Creates root@pam!opentofu API token for OpenTofu
#
#  Standalone: bash -c "$(curl -fsSL https://raw.githubusercontent.com/MoodyLondon/proxmox/main/iac/02-proxmox-api-token.sh)"
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

# ── Confirm ───────────────────────────────────────────────────────────────────
w_yesno "Proxmox API Token" "\
Create a Proxmox API token for OpenTofu:\n\
\n\
  User:     root@pam\n\
  Token ID: opentofu\n\
  Privs:    full (privsep disabled)\n\
\n\
If a token named 'opentofu' already exists it will be\n\
replaced. The value is saved to /root/proxmox-iac-secrets.txt\n\
\n\
Proceed?" || exit 0

# ── Create token ──────────────────────────────────────────────────────────────
do_install() {
  echo "10|Removing old opentofu token if exists"
  pveum user token remove root@pam opentofu &>/dev/null || true

  echo "40|Creating API token root@pam!opentofu"
  local out
  out=$(pveum user token add root@pam opentofu --privsep 0 --output-format json 2>/dev/null)
  PROXMOX_TOKEN_VALUE=$(echo "$out" \
    | python3 -c "import sys,json; print(json.load(sys.stdin)['value'])" 2>/dev/null \
    || echo "")

  echo "70|Detecting Proxmox host IP"
  PROXMOX_HOST_IP=$(ip -4 addr show vmbr0 2>/dev/null \
    | grep -oP '(?<=inet )\d+\.\d+\.\d+\.\d+' | head -1 \
    || hostname -I | awk '{print $1}')

  echo "85|Saving to config and secrets file"
  conf_write "PROXMOX_TOKEN_VALUE" "$PROXMOX_TOKEN_VALUE"
  conf_write "PROXMOX_HOST_IP"     "$PROXMOX_HOST_IP"

  # Append to secrets file (create or update)
  local sf="/root/proxmox-iac-secrets.txt"
  sed -i '/^PROXMOX_/d' "$sf" 2>/dev/null || true
  cat >> "$sf" << SEOF

PROXMOX_URL=https://${PROXMOX_HOST_IP}:8006
PROXMOX_API_TOKEN=root@pam!opentofu=${PROXMOX_TOKEN_VALUE}
SEOF
  chmod 600 "$sf"

  echo "100|Done"
  sleep 1
}

run_with_gauge "Proxmox API Token" "Creating token..." do_install

# Re-read config so we can display the token
conf_load

w_msg "API Token Created" "\
Token created successfully!\n\
\n\
  root@pam!opentofu=${PROXMOX_TOKEN_VALUE:-<see /root/proxmox-iac-secrets.txt>}\n\
\n\
Saved to: /root/proxmox-iac-secrets.txt\n\
(Delete this file after copying to secrets.env)"

msg_ok "Proxmox API token created: root@pam!opentofu"
