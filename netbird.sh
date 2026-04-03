#!/usr/bin/env bash

# Proxmox Internal Network Bootstrap
# Sets up vmbr1, NAT, IP forwarding, Debian LXC + dnsmasq
# Run once on a fresh Proxmox host
#
# Usage: bash bootstrap.sh

set -Eeo pipefail
exec < /dev/tty

# ── Colors & Formatting ──────────────────────────────────────────────────────
RD="\033[01;31m"
GN="\033[01;32m"
YW="\033[33m"
BL="\033[36m"
BFR="\\r\\033[K"
BOLD="\033[1m"
CL="\033[m"
TAB="  "
CM="${GN}✔${CL}"
CROSS="${RD}✖${CL}"
PARTY="🎉"

msg_info() { echo -ne "${TAB}${YW}⏳ $1...${CL}"; }
msg_ok() { echo -e "${BFR}${TAB}${CM} $1${CL}"; }
msg_error() { echo -e "${BFR}${TAB}${CROSS} $1${CL}"; }

# ── Whiptail Helpers ─────────────────────────────────────────────────────────
WHIPTAIL_BACKTITLE="Proxmox VE - Internal Network Bootstrap"

whiptail_msg() {
  whiptail --backtitle "$WHIPTAIL_BACKTITLE" --title "$1" --msgbox "$2" 12 60
}

whiptail_yesno() {
  whiptail --backtitle "$WHIPTAIL_BACKTITLE" --title "$1" --yesno "$2" 12 60
  return $?
}

whiptail_input() {
  local title="$1" prompt="$2" default="$3"
  local result
  result=$(whiptail --backtitle "$WHIPTAIL_BACKTITLE" --title "$title" \
    --inputbox "$prompt" 10 60 "$default" 3>&1 1>&2 2>&3) || exit 1
  echo "$result"
}

whiptail_progress() {
  local pct="$1" text="$2"
  echo -e "XXX\n${pct}\n${text}\nXXX"
}

# ── Preflight ────────────────────────────────────────────────────────────────
check_root() {
  if [[ $EUID -ne 0 ]]; then
    clear
    msg_error "This script must be run as root"
    exit 1
  fi
}

check_pve() {
  if ! command -v pct &>/dev/null; then
    clear
    msg_error "This script must be run on a Proxmox VE host"
    exit 1
  fi
}

# ── Default Configuration ────────────────────────────────────────────────────
BRIDGE="vmbr1"
SUBNET="10.10.10"
HOST_IP="${SUBNET}.1"
CT_IP="${SUBNET}.2"
DHCP_START="${SUBNET}.100"
DHCP_END="${SUBNET}.200"
DHCP_LEASE="24h"
UPSTREAM_DNS="1.1.1.1"
DOMAIN="lan"
CTID="100"
CT_HOSTNAME="dnsmasq"
CT_DISK="2"
CT_RAM="256"
CT_CPU="1"

# ── Detect Public Bridge ────────────────────────────────────────────────────
detect_public_bridge() {
  PUBLIC_BRIDGE_NAME=$(awk '/^auto vmbr/{name=$2} /bridge-ports\s+[^n]/{print name; exit}' /etc/network/interfaces)
  PUBLIC_BRIDGE_NAME="${PUBLIC_BRIDGE_NAME:-vmbr0}"
}

# ── Detect Available Storage ─────────────────────────────────────────────────
detect_storage() {
  STORAGE=$(pvesm status 2>/dev/null | tail -n +2 | awk '/active/ {print $1; exit}')
  if [[ -z "$STORAGE" ]]; then
    whiptail_msg "Error" "No active storage found!"
    exit 1
  fi
}

# ── Welcome Screen ───────────────────────────────────────────────────────────
show_welcome() {
  whiptail --backtitle "$WHIPTAIL_BACKTITLE" \
    --title "Internal Network Bootstrap" \
    --yesno "This will set up on your Proxmox host:\n\n\
  • Private bridge with NAT + IP forwarding\n\
  • Debian LXC with dnsmasq (DHCP + DNS)\n\n\
New containers on ${BRIDGE} with DHCP get IPs automatically.\n\n\
Proceed?" 14 58 || exit 0
}

# ── Simple vs Advanced ───────────────────────────────────────────────────────
choose_mode() {
  local MODE
  MODE=$(whiptail --backtitle "$WHIPTAIL_BACKTITLE" \
    --title "Configuration Mode" \
    --menu "Choose setup mode:" 12 60 2 \
    "1" "Use Defaults (recommended)" \
    "2" "Advanced Configuration" \
    3>&1 1>&2 2>&3) || exit 1

  if [[ "$MODE" == "2" ]]; then
    advanced_config
  fi
}

# ── Advanced Configuration ───────────────────────────────────────────────────
advanced_config() {
  # Network settings
  BRIDGE=$(whiptail_input "Bridge Name" "Internal bridge name:" "$BRIDGE")

  SUBNET=$(whiptail_input "Subnet" "Internal subnet (first 3 octets):" "$SUBNET")
  HOST_IP="${SUBNET}.1"
  CT_IP="${SUBNET}.2"
  DHCP_START="${SUBNET}.100"
  DHCP_END="${SUBNET}.200"

  HOST_IP=$(whiptail_input "Host IP" "Host IP on internal bridge:" "$HOST_IP")

  # DHCP settings
  DHCP_START=$(whiptail_input "DHCP Start" "DHCP range start:" "$DHCP_START")
  DHCP_END=$(whiptail_input "DHCP End" "DHCP range end:" "$DHCP_END")
  DHCP_LEASE=$(whiptail_input "Lease Time" "DHCP lease time:" "$DHCP_LEASE")
  UPSTREAM_DNS=$(whiptail_input "Upstream DNS" "Upstream DNS server:" "$UPSTREAM_DNS")
  DOMAIN=$(whiptail_input "Domain" "Local domain name:" "$DOMAIN")

  # Container settings
  CTID=$(whiptail_input "Container ID" "LXC container ID:" "$CTID")
  CT_HOSTNAME=$(whiptail_input "Hostname" "Container hostname:" "$CT_HOSTNAME")
  CT_RAM=$(whiptail_input "RAM" "Container RAM (MB):" "$CT_RAM")
  CT_CPU=$(whiptail_input "CPU" "Container CPU cores:" "$CT_CPU")
  CT_DISK=$(whiptail_input "Disk" "Container disk size (GB):" "$CT_DISK")
  CT_IP=$(whiptail_input "Container IP" "dnsmasq container IP:" "$CT_IP")
}

# ── Confirm Settings ─────────────────────────────────────────────────────────
confirm_settings() {
  whiptail --backtitle "$WHIPTAIL_BACKTITLE" \
    --title "Confirm Settings" \
    --yesno "\
Bridge: ${BRIDGE} (${HOST_IP}/24) NAT → ${PUBLIC_BRIDGE_NAME}\n\
CT ${CTID}: ${CT_HOSTNAME} (${CT_CPU}C/${CT_RAM}M/${CT_DISK}G) IP ${CT_IP}\n\
DHCP: ${DHCP_START}-${DHCP_END} (${DHCP_LEASE})\n\
DNS: ${UPSTREAM_DNS} Domain: ${DOMAIN}\n\n\
Apply?" 12 58 || exit 0
}

# ── Installation (with progress bar) ─────────────────────────────────────────
run_installation() {
  local INSTALL_LOG="/tmp/bootstrap-install.log"

  {
    whiptail_progress 0 "Setting up host networking..."
    setup_host_networking >> "$INSTALL_LOG" 2>&1

    whiptail_progress 15 "Downloading Debian template..."
    download_template >> "$INSTALL_LOG" 2>&1

    whiptail_progress 35 "Creating LXC container ${CTID}..."
    create_container >> "$INSTALL_LOG" 2>&1

    whiptail_progress 50 "Starting container..."
    start_and_configure_container >> "$INSTALL_LOG" 2>&1

    whiptail_progress 70 "Installing dnsmasq..."
    install_dnsmasq >> "$INSTALL_LOG" 2>&1

    whiptail_progress 100 "Complete!"
    sleep 1
  } | whiptail --backtitle "$WHIPTAIL_BACKTITLE" \
      --title "Installing" \
      --gauge "Starting..." 8 60 0

  # Verify everything actually worked
  if ! pct exec "$CTID" -- systemctl is-active dnsmasq &>/dev/null; then
    whiptail_msg "Error" "Installation failed!\n\nCheck log: cat ${INSTALL_LOG}\nOr: pct exec ${CTID} -- journalctl -u dnsmasq"
    exit 1
  fi

  rm -f "$INSTALL_LOG"
}

# ── Step 1: Host Networking ──────────────────────────────────────────────────
setup_host_networking() {
  if ip link show "$BRIDGE" &>/dev/null; then
    return
  fi

  cp /etc/network/interfaces "/etc/network/interfaces.bak.$(date +%s)"

  cat >> /etc/network/interfaces << EOF

auto ${BRIDGE}
iface ${BRIDGE} inet static
        address ${HOST_IP}/24
        bridge-ports none
        bridge-stp off
        bridge-fd 0
        post-up   iptables -t nat -A POSTROUTING -s ${SUBNET}.0/24 -o ${PUBLIC_BRIDGE_NAME} -j MASQUERADE
        post-down iptables -t nat -D POSTROUTING -s ${SUBNET}.0/24 -o ${PUBLIC_BRIDGE_NAME} -j MASQUERADE
EOF

  sysctl -w net.ipv4.ip_forward=1 &>/dev/null
  if [[ -f /etc/sysctl.conf ]]; then
    sed -i '/net.ipv4.ip_forward/d' /etc/sysctl.conf
  fi
  echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf

  ifreload -a &>/dev/null
  sleep 2
}

# ── Step 2: Download Template ────────────────────────────────────────────────
download_template() {
  TEMPLATE=""
  local available
  available=$(pveam available -section system 2>/dev/null | grep "debian-12-standard" | tail -1 | awk '{print $2}')

  if [[ -z "$available" ]]; then
    pveam update &>/dev/null
    available=$(pveam available -section system 2>/dev/null | grep "debian-12-standard" | tail -1 | awk '{print $2}')
  fi

  if [[ -z "$available" ]]; then
    whiptail_msg "Error" "Could not find Debian 12 template!"
    exit 1
  fi

  TEMPLATE="$available"

  if [[ ! -f "/var/lib/vz/template/cache/${TEMPLATE}" ]]; then
    pveam download local "$TEMPLATE" &>/dev/null
  fi
}

# ── Step 3: Create Container ─────────────────────────────────────────────────
create_container() {
  if pct status "$CTID" &>/dev/null; then
    whiptail_msg "Error" "Container ${CTID} already exists!\nDestroy it first or choose a different ID."
    exit 1
  fi

  pct create "$CTID" "local:vztmpl/${TEMPLATE}" \
    --hostname "$CT_HOSTNAME" \
    --memory "$CT_RAM" \
    --cores "$CT_CPU" \
    --rootfs "${STORAGE}:${CT_DISK}" \
    --net0 "name=eth0,bridge=${BRIDGE},ip=${CT_IP}/24,gw=${HOST_IP}" \
    --nameserver "$UPSTREAM_DNS" \
    --ostype debian \
    --unprivileged 1 \
    --features nesting=1 \
    --onboot 1 \
    --start 0 &>/dev/null
}

# ── Step 4: Start & Configure Container ──────────────────────────────────────
start_and_configure_container() {
  pct start "$CTID" &>/dev/null
  local count=0
  while [[ $(pct status "$CTID" 2>/dev/null | awk '{print $2}') != "running" ]]; do
    sleep 1
    ((count++))
    if [[ $count -ge 30 ]]; then
      whiptail_msg "Error" "Container failed to start within 30s"
      exit 1
    fi
  done
  sleep 3

  # Configure networking inside container (fixes Debian 13 issue)
  pct exec "$CTID" -- bash -c "cat > /etc/network/interfaces << NETEOF
auto lo
iface lo inet loopback

auto eth0
iface eth0 inet static
    address ${CT_IP}/24
    gateway ${HOST_IP}
    dns-nameservers ${UPSTREAM_DNS}
NETEOF"
  pct exec "$CTID" -- bash -c "echo 'nameserver ${UPSTREAM_DNS}' > /etc/resolv.conf"
  pct exec "$CTID" -- systemctl restart networking &>/dev/null 2>&1 || true
  pct exec "$CTID" -- ip addr flush dev eth0 2>/dev/null || true
  pct exec "$CTID" -- ip addr add "${CT_IP}/24" dev eth0 2>/dev/null || true
  pct exec "$CTID" -- ip link set eth0 up 2>/dev/null || true
  pct exec "$CTID" -- ip route add default via "${HOST_IP}" 2>/dev/null || true

  # Verify connectivity
  local retries=0
  while ! pct exec "$CTID" -- ping -c 1 -W 3 1.1.1.1 &>/dev/null; do
    ((retries++))
    if [[ $retries -ge 5 ]]; then
      whiptail_msg "Error" "Container cannot reach the internet.\n\nDebug with:\n  pct exec ${CTID} -- ip a\n  pct exec ${CTID} -- ip route"
      exit 1
    fi
    sleep 2
  done
}

# ── Step 5: Install dnsmasq ──────────────────────────────────────────────────
install_dnsmasq() {
  pct exec "$CTID" -- bash -c "apt-get update -qq" &>/dev/null
  pct exec "$CTID" -- bash -c "DEBIAN_FRONTEND=noninteractive apt-get install -y -qq dnsmasq" &>/dev/null

  pct exec "$CTID" -- bash -c "cat > /etc/dnsmasq.conf << DNSMASQEOF
# dnsmasq configuration - managed by bootstrap script
# $(date +%Y-%m-%d)

# Interface
interface=eth0
bind-interfaces

# DHCP
dhcp-range=${DHCP_START},${DHCP_END},${DHCP_LEASE}
dhcp-option=option:router,${HOST_IP}
dhcp-option=option:dns-server,${CT_IP}
dhcp-option=option:domain-name,${DOMAIN}

# DNS
domain=${DOMAIN}
local=/${DOMAIN}/
expand-hosts
server=${UPSTREAM_DNS}
server=8.8.8.8

# Static DHCP leases
# dhcp-host=AA:BB:CC:DD:EE:FF,hostname,${SUBNET}.10

# Local DNS records
# address=/myapp.${DOMAIN}/${SUBNET}.10

# Logging
log-dhcp
log-queries
log-facility=/var/log/dnsmasq.log

# Performance
cache-size=1000
DNSMASQEOF"

  pct exec "$CTID" -- bash -c "cat > /etc/logrotate.d/dnsmasq << 'LOGEOF'
/var/log/dnsmasq.log {
    monthly
    missingok
    notifempty
    compress
    delaycompress
    sharedscripts
    postrotate
        [ -f /var/run/dnsmasq/dnsmasq.pid ] && kill -USR2 \$(cat /var/run/dnsmasq/dnsmasq.pid)
    endscript
}
LOGEOF"

  pct exec "$CTID" -- systemctl enable dnsmasq &>/dev/null
  pct exec "$CTID" -- systemctl restart dnsmasq &>/dev/null

  if ! pct exec "$CTID" -- systemctl is-active dnsmasq &>/dev/null; then
    whiptail_msg "Error" "dnsmasq failed to start!\n\nCheck: pct exec ${CTID} -- journalctl -u dnsmasq"
    exit 1
  fi
}

# ── Completion ───────────────────────────────────────────────────────────────
show_completion() {
  whiptail --backtitle "$WHIPTAIL_BACKTITLE" \
    --title "Setup Complete ${PARTY}" \
    --msgbox "\
Bridge: ${BRIDGE} (${HOST_IP}/24) NAT active\n\
dnsmasq CT ${CTID}: ${CT_IP} DHCP ${DHCP_START}-${DHCP_END}\n\
Domain: ${DOMAIN}  Upstream: ${UPSTREAM_DNS}\n\n\
Containers on ${BRIDGE} with ip=dhcp get IPs automatically.\n\n\
Leases: pct exec ${CTID} -- cat /var/lib/misc/dnsmasq.leases\n\
Logs:   pct exec ${CTID} -- tail -f /var/log/dnsmasq.log\n\
Config: pct exec ${CTID} -- nano /etc/dnsmasq.conf" 16 62

  clear
  echo -e "\n${TAB}${GN}${BOLD}${PARTY} Proxmox internal network bootstrapped successfully!${CL}\n"
  echo -e "${TAB}Container ${BL}${CTID}${CL} (${CT_HOSTNAME}) is running dnsmasq"
  echo -e "${TAB}DHCP: ${BL}${DHCP_START} - ${DHCP_END}${CL} on ${BL}${BRIDGE}${CL}"
  echo -e "${TAB}DNS:  ${BL}${CT_IP}${CL} (domain: ${DOMAIN})\n"
}

# ── Main ─────────────────────────────────────────────────────────────────────
main() {
  check_root
  check_pve
  detect_public_bridge
  detect_storage
  show_welcome
  choose_mode
  confirm_settings
  run_installation
  show_completion
}

main "$@"
