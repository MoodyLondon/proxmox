#!/usr/bin/env bash

# dnsmasq LXC Helper Script for Proxmox VE
# Creates a Debian LXC container with dnsmasq (DHCP + DNS)
# Inspired by community-scripts.org
# Run this on the Proxmox host

set -Eeuo pipefail

# ── Colors & Formatting ──────────────────────────────────────────────────────
RD="\033[01;31m"
GN="\033[01;32m"
YW="\033[33m"
BL="\033[36m"
BFR="\\r\\033[K"
BOLD="\033[1m"
CL="\033[m"
TAB="  "

# ── Helper Functions ─────────────────────────────────────────────────────────
msg_info() { echo -ne "${TAB}${YW}⏳ $1...${CL}"; }
msg_ok() { echo -e "${BFR}${TAB}${GN}✔ $1${CL}"; }
msg_error() { echo -e "${BFR}${TAB}${RD}✖ $1${CL}"; }

header_info() {
  clear
  cat <<"EOF"
     _                                 
  __| |_ __  ___ _ __ ___   __ _ ___  __ _ 
 / _` | '_ \/ __| '_ ` _ \ / _` / __|/ _` |
| (_| | | | \__ \ | | | | | (_| \__ \ (_| |
 \__,_|_| |_|___/_| |_| |_|\__,_|___/\__, |
           LXC Helper Script            |_/ 
EOF
  echo ""
}

# ── Preflight Checks ────────────────────────────────────────────────────────
check_root() {
  if [[ $EUID -ne 0 ]]; then
    msg_error "This script must be run as root"
    exit 1
  fi
}

check_pve() {
  if ! command -v pct &>/dev/null; then
    msg_error "This script must be run on a Proxmox VE host"
    exit 1
  fi
}

# ── Default Configuration ────────────────────────────────────────────────────
CTID_DEFAULT=$(pvesh get /cluster/nextid 2>/dev/null || echo 100)
HOSTNAME_DEFAULT="dnsmasq"
DISK_DEFAULT="2"
RAM_DEFAULT="256"
CPU_DEFAULT="1"
BRIDGE_DEFAULT="vmbr1"
IP_DEFAULT="10.10.10.2/24"
GW_DEFAULT="10.10.10.1"
DHCP_RANGE_START_DEFAULT="10.10.10.100"
DHCP_RANGE_END_DEFAULT="10.10.10.200"
DHCP_LEASE_DEFAULT="24h"
UPSTREAM_DNS_DEFAULT="1.1.1.1"
DOMAIN_DEFAULT="lan"

# ── Storage Detection ────────────────────────────────────────────────────────
get_storage() {
  local -a storages=()
  while read -r name type status; do
    [[ "$status" == "active" ]] && storages+=("$name")
  done < <(pvesm status -content rootdir 2>/dev/null | tail -n +2)

  if [[ ${#storages[@]} -eq 0 ]]; then
    # Fall back to any active storage
    while read -r name type status; do
      [[ "$status" == "active" ]] && storages+=("$name")
    done < <(pvesm status 2>/dev/null | tail -n +2)
  fi

  if [[ ${#storages[@]} -eq 0 ]]; then
    msg_error "No active storage found!"
    exit 1
  fi

  STORAGE="${storages[0]}"
}

# ── Template Download ────────────────────────────────────────────────────────
download_template() {
  TEMPLATE="debian-12-standard_12.7-1_amd64.tar.zst"

  if [[ -f "/var/lib/vz/template/cache/${TEMPLATE}" ]]; then
    msg_ok "Template already exists"
    return
  fi

  msg_info "Updating template list"
  pveam update &>/dev/null
  msg_ok "Updated template list"

  # Find latest Debian 12 template
  local available
  available=$(pveam available -section system 2>/dev/null | grep "debian-12-standard" | tail -1 | awk '{print $2}')
  if [[ -n "$available" ]]; then
    TEMPLATE="$available"
  fi

  msg_info "Downloading ${TEMPLATE}"
  pveam download local "$TEMPLATE" &>/dev/null
  msg_ok "Downloaded ${TEMPLATE}"
}

# ── User Input (Advanced Mode) ───────────────────────────────────────────────
get_user_input() {
  echo -e "\n${BOLD}${BL}── Container Settings ──${CL}\n"

  read -rp "${TAB}Container ID [${CTID_DEFAULT}]: " CTID
  CTID="${CTID:-$CTID_DEFAULT}"

  read -rp "${TAB}Hostname [${HOSTNAME_DEFAULT}]: " HOSTNAME
  HOSTNAME="${HOSTNAME:-$HOSTNAME_DEFAULT}"

  read -rp "${TAB}Disk size in GB [${DISK_DEFAULT}]: " DISK
  DISK="${DISK:-$DISK_DEFAULT}"

  read -rp "${TAB}RAM in MB [${RAM_DEFAULT}]: " RAM
  RAM="${RAM:-$RAM_DEFAULT}"

  read -rp "${TAB}CPU cores [${CPU_DEFAULT}]: " CPU
  CPU="${CPU:-$CPU_DEFAULT}"

  echo -e "\n${BOLD}${BL}── Network Settings ──${CL}\n"

  read -rp "${TAB}Bridge [${BRIDGE_DEFAULT}]: " BRIDGE
  BRIDGE="${BRIDGE:-$BRIDGE_DEFAULT}"

  read -rp "${TAB}Container IP [${IP_DEFAULT}]: " IP
  IP="${IP:-$IP_DEFAULT}"

  read -rp "${TAB}Gateway [${GW_DEFAULT}]: " GW
  GW="${GW:-$GW_DEFAULT}"

  echo -e "\n${BOLD}${BL}── DHCP Settings ──${CL}\n"

  read -rp "${TAB}DHCP range start [${DHCP_RANGE_START_DEFAULT}]: " DHCP_RANGE_START
  DHCP_RANGE_START="${DHCP_RANGE_START:-$DHCP_RANGE_START_DEFAULT}"

  read -rp "${TAB}DHCP range end [${DHCP_RANGE_END_DEFAULT}]: " DHCP_RANGE_END
  DHCP_RANGE_END="${DHCP_RANGE_END:-$DHCP_RANGE_END_DEFAULT}"

  read -rp "${TAB}DHCP lease time [${DHCP_LEASE_DEFAULT}]: " DHCP_LEASE
  DHCP_LEASE="${DHCP_LEASE:-$DHCP_LEASE_DEFAULT}"

  read -rp "${TAB}Upstream DNS [${UPSTREAM_DNS_DEFAULT}]: " UPSTREAM_DNS
  UPSTREAM_DNS="${UPSTREAM_DNS:-$UPSTREAM_DNS_DEFAULT}"

  read -rp "${TAB}Local domain [${DOMAIN_DEFAULT}]: " DOMAIN
  DOMAIN="${DOMAIN:-$DOMAIN_DEFAULT}"
}

use_defaults() {
  CTID="$CTID_DEFAULT"
  HOSTNAME="$HOSTNAME_DEFAULT"
  DISK="$DISK_DEFAULT"
  RAM="$RAM_DEFAULT"
  CPU="$CPU_DEFAULT"
  BRIDGE="$BRIDGE_DEFAULT"
  IP="$IP_DEFAULT"
  GW="$GW_DEFAULT"
  DHCP_RANGE_START="$DHCP_RANGE_START_DEFAULT"
  DHCP_RANGE_END="$DHCP_RANGE_END_DEFAULT"
  DHCP_LEASE="$DHCP_LEASE_DEFAULT"
  UPSTREAM_DNS="$UPSTREAM_DNS_DEFAULT"
  DOMAIN="$DOMAIN_DEFAULT"
}

show_summary() {
  local IP_BARE="${IP%%/*}"
  echo -e "\n${BOLD}${BL}── Summary ──${CL}\n"
  echo -e "${TAB}Container:  ${GN}${CTID}${CL} (${HOSTNAME})"
  echo -e "${TAB}Resources:  ${GN}${CPU} CPU / ${RAM}MB RAM / ${DISK}GB Disk${CL}"
  echo -e "${TAB}Storage:    ${GN}${STORAGE}${CL}"
  echo -e "${TAB}Network:    ${GN}${IP} on ${BRIDGE} (gw: ${GW})${CL}"
  echo -e "${TAB}DHCP Range: ${GN}${DHCP_RANGE_START} - ${DHCP_RANGE_END}${CL}"
  echo -e "${TAB}DNS:        ${GN}${UPSTREAM_DNS}${CL} (domain: ${DOMAIN})"
  echo ""

  read -rp "${TAB}Proceed? [Y/n]: " confirm
  if [[ "${confirm,,}" == "n" ]]; then
    echo -e "${TAB}Aborted."
    exit 0
  fi
}

# ── Create Container ─────────────────────────────────────────────────────────
create_container() {
  msg_info "Creating LXC container ${CTID}"
  pct create "$CTID" "local:vztmpl/${TEMPLATE}" \
    --hostname "$HOSTNAME" \
    --memory "$RAM" \
    --cores "$CPU" \
    --rootfs "${STORAGE}:${DISK}" \
    --net0 "name=eth0,bridge=${BRIDGE},ip=${IP},gw=${GW}" \
    --nameserver "$UPSTREAM_DNS" \
    --ostype debian \
    --unprivileged 1 \
    --features nesting=1 \
    --onboot 1 \
    --start 0 &>/dev/null
  msg_ok "Created LXC container ${CTID}"
}

# ── Start Container ──────────────────────────────────────────────────────────
start_container() {
  msg_info "Starting container ${CTID}"
  pct start "$CTID" &>/dev/null
  # Wait for container to be fully running
  local max_wait=30
  local count=0
  while [[ $(pct status "$CTID" 2>/dev/null | awk '{print $2}') != "running" ]]; do
    sleep 1
    ((count++))
    if [[ $count -ge $max_wait ]]; then
      msg_error "Container failed to start within ${max_wait}s"
      exit 1
    fi
  done
  sleep 2
  msg_ok "Started container ${CTID}"
}

# ── Install dnsmasq ──────────────────────────────────────────────────────────
install_dnsmasq() {
  local IP_BARE="${IP%%/*}"

  msg_info "Updating package lists"
  pct exec "$CTID" -- bash -c "apt-get update -qq" &>/dev/null
  msg_ok "Updated package lists"

  msg_info "Installing dnsmasq"
  pct exec "$CTID" -- bash -c "DEBIAN_FRONTEND=noninteractive apt-get install -y -qq dnsmasq" &>/dev/null
  msg_ok "Installed dnsmasq"

  msg_info "Configuring dnsmasq"
  pct exec "$CTID" -- bash -c "cat > /etc/dnsmasq.conf << DNSMASQEOF
# dnsmasq configuration - managed by helper script

# Interface
interface=eth0
bind-interfaces

# DHCP
dhcp-range=${DHCP_RANGE_START},${DHCP_RANGE_END},${DHCP_LEASE}
dhcp-option=option:router,${GW}
dhcp-option=option:dns-server,${IP_BARE}
dhcp-option=option:domain-name,${DOMAIN}

# DNS
domain=${DOMAIN}
local=/${DOMAIN}/
expand-hosts
server=${UPSTREAM_DNS}
server=8.8.8.8

# Logging
log-dhcp
log-queries
log-facility=/var/log/dnsmasq.log

# Performance
cache-size=1000
DNSMASQEOF"
  msg_ok "Configured dnsmasq"

  msg_info "Creating log rotation"
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
  msg_ok "Created log rotation"

  msg_info "Enabling and starting dnsmasq"
  pct exec "$CTID" -- systemctl enable dnsmasq &>/dev/null
  pct exec "$CTID" -- systemctl restart dnsmasq &>/dev/null
  msg_ok "Enabled and started dnsmasq"

  msg_info "Verifying dnsmasq is running"
  if pct exec "$CTID" -- systemctl is-active dnsmasq &>/dev/null; then
    msg_ok "dnsmasq is running"
  else
    msg_error "dnsmasq failed to start! Check logs with: pct exec ${CTID} -- journalctl -u dnsmasq"
    exit 1
  fi
}

# ── Completion ───────────────────────────────────────────────────────────────
show_completion() {
  local IP_BARE="${IP%%/*}"
  echo ""
  echo -e "${BOLD}${GN}══════════════════════════════════════════════════${CL}"
  echo -e "${BOLD}${GN}  ✔ dnsmasq LXC created successfully!${CL}"
  echo -e "${BOLD}${GN}══════════════════════════════════════════════════${CL}"
  echo ""
  echo -e "${TAB}Container ID:   ${BL}${CTID}${CL}"
  echo -e "${TAB}IP Address:     ${BL}${IP_BARE}${CL}"
  echo -e "${TAB}DHCP Range:     ${BL}${DHCP_RANGE_START} - ${DHCP_RANGE_END}${CL}"
  echo -e "${TAB}DNS Server:     ${BL}${IP_BARE}${CL}"
  echo -e "${TAB}Domain:         ${BL}${DOMAIN}${CL}"
  echo ""
  echo -e "${TAB}${YW}Useful commands:${CL}"
  echo -e "${TAB}  Enter container:    ${GN}pct enter ${CTID}${CL}"
  echo -e "${TAB}  View DHCP leases:   ${GN}pct exec ${CTID} -- cat /var/lib/misc/dnsmasq.leases${CL}"
  echo -e "${TAB}  View logs:          ${GN}pct exec ${CTID} -- tail -f /var/log/dnsmasq.log${CL}"
  echo -e "${TAB}  Restart dnsmasq:    ${GN}pct exec ${CTID} -- systemctl restart dnsmasq${CL}"
  echo -e "${TAB}  Edit config:        ${GN}pct exec ${CTID} -- nano /etc/dnsmasq.conf${CL}"
  echo ""
  echo -e "${TAB}${YW}Add static DHCP leases by editing /etc/dnsmasq.conf:${CL}"
  echo -e "${TAB}  ${GN}dhcp-host=AA:BB:CC:DD:EE:FF,hostname,10.10.10.10${CL}"
  echo ""
}

# ── Main ─────────────────────────────────────────────────────────────────────
main() {
  header_info
  check_root
  check_pve
  get_storage

  echo -e "${BOLD}${BL}  dnsmasq LXC Installer for Proxmox VE${CL}\n"
  echo -e "${TAB}This script will create a Debian 12 LXC container"
  echo -e "${TAB}with dnsmasq configured as a DHCP and DNS server.\n"

  read -rp "${TAB}Use default settings? [Y/n]: " mode
  if [[ "${mode,,}" == "n" ]]; then
    get_user_input
  else
    use_defaults
  fi

  show_summary
  download_template
  create_container
  start_container
  install_dnsmasq
  show_completion
}

main "$@"
