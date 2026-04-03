#!/usr/bin/env bash

# Netbird Configurator for Proxmox VE
# Installs and configures Netbird on an existing VM as a subnet router
# Run this on the Proxmox host
#
# Usage: bash netbird.sh [VMID]

set -Eeo pipefail

# ── Colors ───────────────────────────────────────────────────────────────────
GN="\033[01;32m"
BL="\033[36m"
BOLD="\033[1m"
CL="\033[m"
TAB="  "
PARTY="🎉"

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

whiptail_password() {
  local title="$1" prompt="$2"
  result=$(whiptail --backtitle "$WHIPTAIL_BACKTITLE" --title "$title" \
    --passwordbox "$prompt" 10 60 3>&1 1>&2 2>&3) || exit 1
  echo "$result"
}

whiptail_yesno() {
  whiptail --backtitle "$WHIPTAIL_BACKTITLE" --title "$1" --yesno "$2" "$3" "$4"
  return $?
}

whiptail_progress() {
  echo -e "XXX\n${1}\n${2}\nXXX"
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

  # Build menu from VMs
  local menu_items=""
  local count=0
  while read -r id name status mem; do
    [[ "$id" == "VMID" ]] && continue
    menu_items="${menu_items} ${id} ${name}_(${status})"
    ((count++))
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

# ── Check VM is Running ─────────────────────────────────────────────────────
ensure_vm_running() {
  local status
  status=$(qm status "$VMID" | awk '{print $2}')
  if [[ "$status" != "running" ]]; then
    whiptail_msg "Error" "VM ${VMID} is not running!\nStart it first with: qm start ${VMID}"
    exit 1
  fi
}

# ── Check VM has Guest Agent ─────────────────────────────────────────────────
check_guest_agent() {
  if ! qm guest exec "$VMID" -- echo "ok" &>/dev/null; then
    whiptail_msg "Error" "QEMU Guest Agent not responding on VM ${VMID}!\n\nInstall it inside the VM:\n  apt install qemu-guest-agent\n  systemctl enable --now qemu-guest-agent\n\nThen retry this script."
    exit 1
  fi
}

# ── Helper to exec commands in VM ────────────────────────────────────────────
vm_exec() {
  local result
  result=$(qm guest exec "$VMID" -- bash -c "$1" 2>/dev/null)
  local exit_code
  exit_code=$(echo "$result" | grep -oP '"exitcode":\K[0-9]+' || echo "1")
  local out_data
  out_data=$(echo "$result" | grep -oP '"out-data":"[^"]*"' | sed 's/"out-data":"//;s/"$//' | sed 's/\\n/\n/g')
  local err_data
  err_data=$(echo "$result" | grep -oP '"err-data":"[^"]*"' | sed 's/"err-data":"//;s/"$//' | sed 's/\\n/\n/g')

  if [[ -n "$out_data" ]]; then
    echo -e "$out_data"
  fi
  if [[ -n "$err_data" ]]; then
    echo -e "$err_data" >&2
  fi
  return "$exit_code"
}

# ── Gather Settings ──────────────────────────────────────────────────────────
gather_settings() {
  # Welcome
  whiptail --backtitle "$WHIPTAIL_BACKTITLE" \
    --title "Netbird Setup" \
    --yesno "This will install Netbird on VM ${VMID} and configure\nit as a subnet router for your internal network.\n\nYou'll need:\n  • Management URL\n  • Setup key from your Netbird admin panel\n\nProceed?" 14 58 || exit 0

  # Management URL
  NB_MGMT_URL=$(whiptail_input "Management URL" "Netbird management URL:" "https://netbird.example.com")

  if [[ -z "$NB_MGMT_URL" ]]; then
    whiptail_msg "Error" "Management URL is required!"
    exit 1
  fi

  # Setup key
  NB_SETUP_KEY=$(whiptail_input "Setup Key" "Netbird setup key:" "")

  if [[ -z "$NB_SETUP_KEY" ]]; then
    whiptail_msg "Error" "Setup key is required!"
    exit 1
  fi

  # Subnet to route
  NB_SUBNET=$(whiptail_input "Subnet Route" "Subnet to advertise via Netbird:" "10.10.10.0/24")

  # Enable SSH?
  ENABLE_SSH="no"
  if whiptail_yesno "Enable SSH" "Enable SSH server on the VM?\n\nThis allows you to SSH into the Netbird VM\nthrough the VPN." 12 50; then
    ENABLE_SSH="yes"

    SSH_PORT=$(whiptail_input "SSH Port" "SSH port:" "22")

    if whiptail_yesno "SSH Key" "Add an SSH public key for root?\n\n(Recommended over password auth)" 10 50; then
      SSH_KEY=$(whiptail_input "SSH Key" "Paste your SSH public key:" "")
    else
      SSH_KEY=""
    fi

    if whiptail_yesno "Password Auth" "Allow password authentication?\n\n(Less secure, but useful as fallback)" 10 50; then
      SSH_PASSWORD_AUTH="yes"
    else
      SSH_PASSWORD_AUTH="no"
    fi
  fi
}

# ── Confirm ──────────────────────────────────────────────────────────────────
confirm_settings() {
  local ssh_info="disabled"
  if [[ "$ENABLE_SSH" == "yes" ]]; then
    ssh_info="port ${SSH_PORT}, pw-auth: ${SSH_PASSWORD_AUTH}"
  fi

  whiptail --backtitle "$WHIPTAIL_BACKTITLE" \
    --title "Confirm Settings" \
    --yesno "\
VM:         ${VMID}\n\
Management: ${NB_MGMT_URL}\n\
Setup Key:  ${NB_SETUP_KEY:0:8}...\n\
Subnet:     ${NB_SUBNET}\n\
SSH:        ${ssh_info}\n\
Auto-start: yes\n\n\
Apply?" 14 55 || exit 0
}

# ── Installation ─────────────────────────────────────────────────────────────
run_installation() {
  {
    whiptail_progress 0 "Checking VM connectivity..."
    # Quick connectivity check
    vm_exec "ping -c 1 -W 3 1.1.1.1" &>/dev/null || true
    sleep 1

    whiptail_progress 10 "Installing Netbird..."
    vm_exec "curl -fsSL https://pkgs.netbird.io/install.sh | sh" &>/dev/null

    whiptail_progress 40 "Connecting to management server..."
    vm_exec "netbird up --management-url ${NB_MGMT_URL} --setup-key ${NB_SETUP_KEY}" &>/dev/null

    whiptail_progress 55 "Enabling Netbird on boot..."
    vm_exec "systemctl enable netbird" &>/dev/null

    whiptail_progress 65 "Enabling IP forwarding..."
    vm_exec "sysctl -w net.ipv4.ip_forward=1" &>/dev/null
    vm_exec "echo 'net.ipv4.ip_forward=1' > /etc/sysctl.d/99-netbird.conf" &>/dev/null

    if [[ "$ENABLE_SSH" == "yes" ]]; then
      whiptail_progress 75 "Configuring SSH..."
      vm_exec "apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq openssh-server" &>/dev/null

      # Configure SSH
      vm_exec "sed -i 's/^#*Port .*/Port ${SSH_PORT}/' /etc/ssh/sshd_config" &>/dev/null
      vm_exec "sed -i 's/^#*PermitRootLogin .*/PermitRootLogin yes/' /etc/ssh/sshd_config" &>/dev/null

      if [[ "$SSH_PASSWORD_AUTH" == "yes" ]]; then
        vm_exec "sed -i 's/^#*PasswordAuthentication .*/PasswordAuthentication yes/' /etc/ssh/sshd_config" &>/dev/null
      else
        vm_exec "sed -i 's/^#*PasswordAuthentication .*/PasswordAuthentication no/' /etc/ssh/sshd_config" &>/dev/null
      fi

      # Add SSH key if provided
      if [[ -n "$SSH_KEY" ]]; then
        vm_exec "mkdir -p /root/.ssh && chmod 700 /root/.ssh && echo '${SSH_KEY}' >> /root/.ssh/authorized_keys && chmod 600 /root/.ssh/authorized_keys" &>/dev/null
      fi

      vm_exec "systemctl enable --now sshd" &>/dev/null
      vm_exec "systemctl restart sshd" &>/dev/null
    fi

    whiptail_progress 90 "Verifying Netbird status..."
    sleep 2

    whiptail_progress 100 "Complete!"
    sleep 1
  } | whiptail --backtitle "$WHIPTAIL_BACKTITLE" \
      --title "Installing Netbird" \
      --gauge "Starting..." 8 60 0

  # Verify
  local nb_status
  nb_status=$(vm_exec "netbird status" 2>/dev/null || echo "unknown")

  if echo "$nb_status" | grep -qi "connected"; then
    return 0
  else
    whiptail_msg "Warning" "Netbird may not be fully connected yet.\n\nCheck status inside VM:\n  qm guest exec ${VMID} -- netbird status\n\nIt may need approval in your admin panel."
  fi
}

# ── Completion ───────────────────────────────────────────────────────────────
show_completion() {
  local ssh_info=""
  if [[ "$ENABLE_SSH" == "yes" ]]; then
    ssh_info="\nSSH: port ${SSH_PORT} enabled"
  fi

  whiptail --backtitle "$WHIPTAIL_BACKTITLE" \
    --title "Setup Complete ${PARTY}" \
    --msgbox "\
Netbird installed on VM ${VMID}\n\
Management: ${NB_MGMT_URL}\n\
Subnet: ${NB_SUBNET}\n\
Auto-start: enabled${ssh_info}\n\n\
NEXT STEPS\n\
──────────────────────────────\n\
1. Open Netbird admin panel\n\
2. Find this peer and add route:\n\
   Network: ${NB_SUBNET}\n\
3. Test: ping 10.10.10.1 from\n\
   another Netbird peer\n\
4. Then lock down Hetzner firewall" 18 50

  clear
  echo -e "\n${TAB}${GN}${BOLD}${PARTY} Netbird configured on VM ${VMID}${CL}\n"
  echo -e "${TAB}Management: ${BL}${NB_MGMT_URL}${CL}"
  echo -e "${TAB}Subnet:     ${BL}${NB_SUBNET}${CL}"
  echo -e "${TAB}Auto-start: ${BL}enabled${CL}"
  if [[ "$ENABLE_SSH" == "yes" ]]; then
    echo -e "${TAB}SSH:        ${BL}port ${SSH_PORT}${CL}"
  fi
  echo ""
  echo -e "${TAB}Add the subnet route in your Netbird admin panel,"
  echo -e "${TAB}then test access to ${BL}10.10.10.1:8006${CL} through VPN.\n"
}

# ── Main ─────────────────────────────────────────────────────────────────────
select_vm "${1:-}"
ensure_vm_running
check_guest_agent
gather_settings
confirm_settings
run_installation
show_completion
