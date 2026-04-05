#!/usr/bin/env bash
# =============================================================================
#  04-runner-lxc.sh
#  Creates the Forgejo Runner LXC + installs OpenTofu, Ansible, SOPS, age
#
#  Standalone: bash -c "$(curl -fsSL https://raw.githubusercontent.com/MoodyLondon/proxmox/main/iac/04-runner-lxc.sh)"
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

RUNNER_IP="${RUNNER_IP:-10.10.10.11}"
GATEWAY="${GATEWAY:-10.10.10.1}"
DNS_IP="${DNS_IP:-10.10.10.2}"
BRIDGE="${BRIDGE:-vmbr1}"
STORAGE="${STORAGE:-local-lvm}"

if [[ -z "${RUNNER_CTID:-}" ]]; then
  RUNNER_CTID=$(next_ctid 102)
fi

# ── Pre-flight info ───────────────────────────────────────────────────────────
w_msg "Forgejo Runner LXC — Community Script" "\
The Forgejo Runner community script is about to run.\n\
\n\
When prompted, use these settings:\n\
\n\
  CT ID:      ${RUNNER_CTID}\n\
  Hostname:   runner\n\
  IP:         ${RUNNER_IP}/24\n\
  Gateway:    ${GATEWAY}\n\
  DNS:        ${DNS_IP}\n\
  Bridge:     ${BRIDGE}\n\
  Storage:    ${STORAGE}\n\
  RAM:        1024 MB\n\
  CPU:        2 cores\n\
  Disk:       8 GB\n\
\n\
After the script completes, this script will automatically\n\
install: OpenTofu · Ansible · age · SOPS · bws CLI\n\
\n\
Press OK then follow the script prompts."

# ── Run community script ──────────────────────────────────────────────────────
clear
echo ""
msg_step "Running Forgejo Runner community script"
echo ""

bash -c "$(curl -fsSL https://raw.githubusercontent.com/community-scripts/ProxmoxVED/main/ct/forgejo-runner.sh)" \
  || msg_error "Forgejo Runner community script failed"

# Verify
if ! pct status "$RUNNER_CTID" &>/dev/null; then
  RUNNER_CTID=$(w_input "Verify CT ID" \
    "What CT ID did the script create?" "$RUNNER_CTID") || exit 1
fi

conf_write "RUNNER_CTID" "$RUNNER_CTID"

# ── Wait for LXC ─────────────────────────────────────────────────────────────
echo ""
msg_info "Waiting for runner LXC to be ready"
wait_for_ct "$RUNNER_CTID" 60 || msg_error "Runner LXC did not start in time"
msg_ok "Runner LXC is running"

# ── Install tools ─────────────────────────────────────────────────────────────
do_install() {
  echo "5|Updating packages"
  pct exec "$RUNNER_CTID" -- bash -c \
    "apt-get update -qq && apt-get upgrade -yq" &>/dev/null

  echo "15|Installing base packages"
  pct exec "$RUNNER_CTID" -- bash -c \
    "apt-get install -yq git openssh-client python3-pip python3-full jq curl" &>/dev/null

  echo "25|Installing OpenTofu"
  pct exec "$RUNNER_CTID" -- bash -c "
    curl --proto '=https' --tlsv1.2 -fsSL \
      https://get.opentofu.org/install-opentofu.sh \
      | sh -s -- --install-method deb 2>/dev/null
  " &>/dev/null || true

  echo "45|Installing Ansible"
  pct exec "$RUNNER_CTID" -- bash -c \
    "pip3 install ansible --break-system-packages -q" &>/dev/null || true

  echo "55|Installing age"
  pct exec "$RUNNER_CTID" -- bash -c "
    AGE_VER=\$(curl -sf https://api.github.com/repos/FiloSottile/age/releases/latest \
      | jq -r .tag_name 2>/dev/null || echo 'v1.2.0')
    curl -fsSL https://github.com/FiloSottile/age/releases/download/\${AGE_VER}/age-\${AGE_VER}-linux-amd64.tar.gz \
      | tar -xz --strip-components=1 -C /usr/local/bin age/age age/age-keygen
    chmod +x /usr/local/bin/age /usr/local/bin/age-keygen
  " &>/dev/null

  echo "70|Installing SOPS"
  pct exec "$RUNNER_CTID" -- bash -c "
    SOPS_VER=\$(curl -sf https://api.github.com/repos/getsops/sops/releases/latest \
      | jq -r .tag_name 2>/dev/null || echo 'v3.9.0')
    curl -fsSL https://github.com/getsops/sops/releases/download/\${SOPS_VER}/sops-\${SOPS_VER}.linux.amd64 \
      -o /usr/local/bin/sops
    chmod +x /usr/local/bin/sops
  " &>/dev/null

  echo "80|Generating age keypair for SOPS"
  pct exec "$RUNNER_CTID" -- bash -c "
    mkdir -p /root/.config/sops/age
    [[ ! -f /root/.config/sops/age/keys.txt ]] && \
      age-keygen -o /root/.config/sops/age/keys.txt 2>/dev/null
    chmod 600 /root/.config/sops/age/keys.txt
  "

  echo "88|Generating Ansible SSH keypair"
  pct exec "$RUNNER_CTID" -- bash -c "
    mkdir -p /root/.ssh
    [[ ! -f /root/.ssh/ansible_id ]] && \
      ssh-keygen -t ed25519 -f /root/.ssh/ansible_id -N '' -C 'ansible@runner' 2>/dev/null
    chmod 600 /root/.ssh/ansible_id
  "

  echo "95|Saving keys to config"
  # Write keys to temp files so we can read them outside the pipe/subshell
  pct exec "$RUNNER_CTID" -- \
    bash -c "grep 'public key' /root/.config/sops/age/keys.txt | awk '{print \$NF}'" \
    > /tmp/iac-age-pubkey.txt 2>/dev/null || true

  pct exec "$RUNNER_CTID" -- cat /root/.ssh/ansible_id.pub \
    > /tmp/iac-ansible-pubkey.txt 2>/dev/null || true

  echo "100|Done"
  sleep 1
}

run_with_gauge "Runner — Installing Tools" \
  "OpenTofu · Ansible · age · SOPS · SSH keypair..." \
  do_install

# Read keys back now that gauge subshell is done
AGE_PUBLIC_KEY=$(cat /tmp/iac-age-pubkey.txt 2>/dev/null | tr -d '\n')
ANSIBLE_PUBLIC_KEY=$(cat /tmp/iac-ansible-pubkey.txt 2>/dev/null | tr -d '\n')
rm -f /tmp/iac-age-pubkey.txt /tmp/iac-ansible-pubkey.txt

conf_write "AGE_PUBLIC_KEY"     "$AGE_PUBLIC_KEY"
conf_write "ANSIBLE_PUBLIC_KEY" "$ANSIBLE_PUBLIC_KEY"

# Append to secrets file
sf="/root/proxmox-iac-secrets.txt"
sed -i '/^AGE_PUBLIC_KEY=/d; /^ANSIBLE_PUBLIC_KEY=/d' "$sf" 2>/dev/null || true
cat >> "$sf" << EOF
AGE_PUBLIC_KEY=${AGE_PUBLIC_KEY}
ANSIBLE_PUBLIC_KEY=${ANSIBLE_PUBLIC_KEY}
EOF
chmod 600 "$sf"

echo ""
msg_ok "OpenTofu, Ansible, age, SOPS installed on runner CT${RUNNER_CTID}"
msg_ok "age public key: ${AGE_PUBLIC_KEY}"
msg_ok "Ansible public key saved to /root/proxmox-iac-secrets.txt"
