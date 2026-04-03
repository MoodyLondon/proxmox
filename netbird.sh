#!/usr/bin/env bash

# Netbird Configurator for Proxmox VE
# Installs and configures Netbird on an existing VM as a subnet router
# Run this on the Proxmox host
#
# Usage: bash netbird.sh [VMID]

set -Eeo pipefail
exec < /dev/tty

# ── Colors & Helpers ─────────────────────────────────────────────────────────
RD="\033[01;31m"
GN="\033[01;32m"
YW="\033[33m"
BL="\033[36m"
BFR="\\r\\033[K"
BOLD="\033[1m"
CL="\033[m"
TAB="  "
PARTY="🎉"

msg_info() { echo -ne "${TAB}${YW}⏳ $1...${CL}"; }
msg_ok() { echo -e "${BFR}${TAB}${GN}✔ $1${CL}"; }
msg_error() { echo -e "${BFR}${TAB}${RD}✖ $1${CL}"; }

# ── Whiptail Helpers ─────────────────────────────────────────────────────────
WHIPTAIL_BACKTITLE="Proxmox VE - Netbird Configurator"

whiptail_msg() {
  whiptail --backtitle "$WHIPTAIL_BACKTITLE" --title "$1" --msgbox "$2" 12 60
}

whiptail_input() {
  local title="$1" prompt="$2" default="$3"
  result=$(whiptail --backtitle "$WHIPTAIL_BACKTITLE" --title "$title" \
    --inputbox "$prompt" 10 60 "$default" 3>&1 1>&2 2>&3) || exit 1
  echo "$result"
}

whiptail_yesno() {
  whiptail --backtitle "$WHIPTAIL_BACKTITLE" --title "$1" --yesno "$2" "$3" "$4"
  return $?
}

# ── Preflight ────────────────────────────────────────────────────────────────
if [[ $EUID -ne 0 ]]; then echo "Run as root"; exit 1; fi
if ! command -v qm &>/dev/null; then echo "Run on Proxmox host"; exit 1; fi

# ── VM Selection ─────────────────────────────────────────────────────────────
select_vm() {
  if [[ -n "${1:-}" ]]; then
    VMID="$1"
    if ! qm status "$VMID" &>/dev/null; then
      whiptail_msg "Error" "VM ${VMID} does not exist!"
      exit 1
    fi
    return
  fi

  local menu_items=""
  local count=0
  while read -r id name status mem; do
    [[ "$id" == "VMID" ]] && continue
    menu_items="${menu_items} ${id} ${name}_(${status})"
    ((count++)) || true
  done < <(qm list 2>/dev/null)

  if [[ $count -eq 0 ]]; then
    whiptail_msg "Error" "No VMs found!\nCreate a Debian VM first."
    exit 1
  fi

  VMID=$(whiptail --backtitle "$WHIPTAIL_BACKTITLE" \
    --title "Select VM" \
    --menu "Choose a VM to install Netbird on:" 16 50 "$count" \
    $menu_items \
    3>&1 1>&2 2>&3) || exit 1
}

# ── Check VM ─────────────────────────────────────────────────────────────────
ensure_vm_ready() {
  local status
  status=$(qm status "$VMID" | awk '{print $2}')
  if [[ "$status" != "running" ]]; then
    whiptail_msg "Error" "VM ${VMID} is not running!\nStart it first: qm start ${VMID}"
    exit 1
  fi

  # Check guest agent
  if ! qm guest exec "$VMID" --timeout 5 -- echo "ok" &>/dev/null; then
    whiptail_msg "Error" "QEMU Guest Agent not responding!\n\nInstall inside VM:\n  apt install qemu-guest-agent\n  systemctl start qemu-guest-agent\n\nThen retry."
    exit 1
  fi
}

# ── Gather Settings ──────────────────────────────────────────────────────────
gather_settings() {
  whiptail --backtitle "$WHIPTAIL_BACKTITLE" \
    --title "Netbird Setup" \
    --yesno "Install Netbird on VM ${VMID} as a subnet router.\n\nYou need:\n  • Management URL\n  • Setup key\n\nProceed?" 12 55 || exit 0

  NB_MGMT_URL=$(whiptail_input "Management URL" "Netbird management URL:" "https://netbird.example.com")
  [[ -z "$NB_MGMT_URL" ]] && { whiptail_msg "Error" "Management URL required!"; exit 1; }

  NB_SETUP_KEY=$(whiptail_input "Setup Key" "Netbird setup key:" "")
  [[ -z "$NB_SETUP_KEY" ]] && { whiptail_msg "Error" "Setup key required!"; exit 1; }

  NB_SUBNET=$(whiptail_input "Subnet Route" "Subnet to advertise:" "10.10.10.0/24")

  ENABLE_SSH="no"
  SSH_PORT="22"
  SSH_KEY=""
  SSH_PASSWORD_AUTH="yes"

  if whiptail_yesno "Enable SSH" "Enable SSH on the VM?" 8 40; then
    ENABLE_SSH="yes"
    SSH_PORT=$(whiptail_input "SSH Port" "SSH port:" "22")

    if whiptail_yesno "SSH Key" "Add an SSH public key?" 8 40; then
      SSH_KEY=$(whiptail_input "SSH Key" "Paste your public key:" "")
    fi

    if whiptail_yesno "Password Auth" "Allow password authentication?" 8 45; then
      SSH_PASSWORD_AUTH="yes"
    else
      SSH_PASSWORD_AUTH="no"
    fi
  fi
}

# ── Confirm ──────────────────────────────────────────────────────────────────
confirm_settings() {
  local ssh_info="disabled"
  [[ "$ENABLE_SSH" == "yes" ]] && ssh_info="port ${SSH_PORT}"

  whiptail --backtitle "$WHIPTAIL_BACKTITLE" \
    --title "Confirm" \
    --yesno "\
VM: ${VMID}  Management: ${NB_MGMT_URL}\n\
Key: ${NB_SETUP_KEY:0:8}...  Subnet: ${NB_SUBNET}\n\
SSH: ${ssh_info}  Auto-start: yes\n\n\
Apply?" 10 58 || exit 0
}

# ── Generate Install Script ──────────────────────────────────────────────────
generate_install_script() {
  INSTALL_SCRIPT=$(cat << SCRIPTEOF
#!/bin/bash
set -e

echo ">>> Installing Netbird..."
curl -fsSL https://pkgs.netbird.io/install.sh | sh

echo ">>> Connecting to management server..."
netbird up --management-url ${NB_MGMT_URL} --setup-key ${NB_SETUP_KEY}

echo ">>> Enabling Netbird on boot..."
systemctl enable netbird 2>/dev/null || true

echo ">>> Enabling IP forwarding..."
sysctl -w net.ipv4.ip_forward=1
mkdir -p /etc/sysctl.d
echo "net.ipv4.ip_forward=1" > /etc/sysctl.d/99-netbird.conf

SCRIPTEOF
)

  if [[ "$ENABLE_SSH" == "yes" ]]; then
    INSTALL_SCRIPT+=$(cat << SSHEOF

echo ">>> Configuring SSH..."
apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq openssh-server

sed -i 's/^#*Port .*/Port ${SSH_PORT}/' /etc/ssh/sshd_config
sed -i 's/^#*PermitRootLogin .*/PermitRootLogin yes/' /etc/ssh/sshd_config
sed -i 's/^#*PasswordAuthentication .*/PasswordAuthentication ${SSH_PASSWORD_AUTH}/' /etc/ssh/sshd_config

SSHEOF
)

    if [[ -n "$SSH_KEY" ]]; then
      INSTALL_SCRIPT+=$(cat << KEYEOF

mkdir -p /root/.ssh
chmod 700 /root/.ssh
echo '${SSH_KEY}' >> /root/.ssh/authorized_keys
chmod 600 /root/.ssh/authorized_keys

KEYEOF
)
    fi

    INSTALL_SCRIPT+=$(cat << SSHENDEOF

systemctl enable sshd 2>/dev/null || systemctl enable ssh 2>/dev/null || true
systemctl restart sshd 2>/dev/null || systemctl restart ssh 2>/dev/null || true

SSHENDEOF
)
  fi

  INSTALL_SCRIPT+=$(cat << ENDEOF

echo ">>> Verifying..."
netbird status
echo ">>> Done!"
ENDEOF
)
}

# ── Push & Execute ───────────────────────────────────────────────────────────
run_installation() {
  clear
  echo -e "\n${BOLD}${BL}  Installing Netbird on VM ${VMID}${CL}\n"

  msg_info "Pushing install script to VM"
  # Write install script into the VM
  printf '%s' "$INSTALL_SCRIPT" | qm guest exec "$VMID" --timeout 10 -- bash -c "cat > /tmp/netbird-install.sh && chmod +x /tmp/netbird-install.sh" &>/dev/null
  msg_ok "Install script pushed"

  msg_info "Running install script (this may take a few minutes)"
  echo ""

  # Execute with generous timeout and show output
  local result
  result=$(qm guest exec "$VMID" --timeout 300 -- bash /tmp/netbird-install.sh 2>&1) || true

  # Parse and display output
  local out_data
  out_data=$(echo "$result" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    if 'out-data' in data:
        print(data['out-data'], end='')
    if 'err-data' in data:
        print(data['err-data'], end='', file=sys.stderr)
except:
    print(sys.stdin.read(), end='')
" 2>&1) || out_data="$result"

  # Show output line by line with formatting
  while IFS= read -r line; do
    if [[ "$line" == ">>>"* ]]; then
      msg_ok "${line#>>> }"
    elif [[ -n "$line" ]]; then
      echo -e "${TAB}  ${line}"
    fi
  done <<< "$out_data"

  echo ""

  # Verify
  msg_info "Verifying Netbird status"
  local status_result
  status_result=$(qm guest exec "$VMID" --timeout 10 -- netbird status 2>&1) || true
  local nb_status
  nb_status=$(echo "$status_result" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    print(data.get('out-data', ''), end='')
except:
    print(sys.stdin.read(), end='')
" 2>&1) || nb_status="$status_result"

  if echo "$nb_status" | grep -qi "connected"; then
    msg_ok "Netbird is connected"
  else
    msg_ok "Netbird installed (may need approval in admin panel)"
  fi

  # Cleanup
  qm guest exec "$VMID" --timeout 5 -- rm -f /tmp/netbird-install.sh &>/dev/null || true
}

# ── Completion ───────────────────────────────────────────────────────────────
show_completion() {
  local ssh_info=""
  [[ "$ENABLE_SSH" == "yes" ]] && ssh_info="\nSSH: port ${SSH_PORT} enabled"

  whiptail --backtitle "$WHIPTAIL_BACKTITLE" \
    --title "Setup Complete ${PARTY}" \
    --msgbox "\
Netbird installed on VM ${VMID}\n\
Subnet: ${NB_SUBNET}  Auto-start: yes${ssh_info}\n\n\
Next steps:\n\
1. Add route in Netbird admin panel:\n\
   Network: ${NB_SUBNET}\n\
2. Test: ping 10.10.10.1\n\
3. Lock down Hetzner firewall" 16 50

  clear
  echo -e "\n${TAB}${GN}${BOLD}${PARTY} Netbird configured on VM ${VMID}${CL}\n"
  echo -e "${TAB}Management: ${BL}${NB_MGMT_URL}${CL}"
  echo -e "${TAB}Subnet:     ${BL}${NB_SUBNET}${CL}"
  [[ "$ENABLE_SSH" == "yes" ]] && echo -e "${TAB}SSH:        ${BL}port ${SSH_PORT}${CL}"
  echo ""
}

# ── Main ─────────────────────────────────────────────────────────────────────
select_vm "${1:-}"
ensure_vm_ready
gather_settings
confirm_settings
generate_install_script
run_installation
show_completion
