#!/usr/bin/env bash

# dnsmasq LXC Configurator for Proxmox VE
# Installs and configures dnsmasq (DHCP + DNS) on an existing LXC container
# Run this on the Proxmox host
#
# Usage: bash dnsmasq-lxc.sh [CTID]

set -Eeo pipefail

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
         LXC Configurator Script        |_/ 
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

# ── Container Selection ──────────────────────────────────────────────────────
select_container() {
  if [[ -n "${1:-}" ]]; then
    CTID="$1"
  else
    echo -e "${TAB}${BOLD}Available containers:${CL}\n"
    pct list | tail -n +2 | while read -r id status lock name; do
      echo -e "${TAB}  ${GN}${id}${CL} - ${name} (${status})"
    done
    echo ""
    read -rp "${TAB}Enter container ID: " CTID
  fi

  if [[ -z "${CTID:-}" ]]; then
    msg_error "No container ID provided"
    exit 1
  fi

  # Verify container exists
  if ! pct status "$CTID" &>/dev/null; then
    msg_error "Container ${CTID} does not exist"
    exit 1
  fi

  # Get container name
  CT_NAME=$(pct config "$CTID" | grep '^hostname:' | awk '{print $2}')
  CT_STATUS=$(pct status "$CTID" | awk '{print $2}')

  msg_ok "Found container ${CTID} (${CT_NAME}) - ${CT_STATUS}"
}

# ── Detect Container Network ────────────────────────────────────────────────
detect_network() {
  local net_config
  net_config=$(pct config "$CTID" | grep '^net0:' || echo "")

  # Extract IP if set
  CT_IP=$(echo "$net_config" | grep -oP 'ip=\K[^,]+' || echo "")
  CT_GW=$(echo "$net_config" | grep -oP 'gw=\K[^,]+' || echo "")
  CT_BRIDGE=$(echo "$net_config" | grep -oP 'bridge=\K[^,]+' || echo "")

  if [[ -n "$CT_IP" && "$CT_IP" != "dhcp" ]]; then
    IP_BARE="${CT_IP%%/*}"
    msg_ok "Detected IP: ${CT_IP} on ${CT_BRIDGE} (gw: ${CT_GW})"
  else
    IP_BARE=""
  fi
}

# ── DHCP Settings ────────────────────────────────────────────────────────────
get_dhcp_settings() {
  # Derive sensible defaults from container IP
  local subnet_prefix=""
  if [[ -n "${IP_BARE:-}" ]]; then
    subnet_prefix=$(echo "$IP_BARE" | cut -d. -f1-3)
    DHCP_RANGE_START_DEFAULT="${subnet_prefix}.100"
    DHCP_RANGE_END_DEFAULT="${subnet_prefix}.200"
    GW_DEFAULT="${CT_GW:-${subnet_prefix}.1}"
    DNS_DEFAULT="$IP_BARE"
  else
    DHCP_RANGE_START_DEFAULT="10.10.10.100"
    DHCP_RANGE_END_DEFAULT="10.10.10.200"
    GW_DEFAULT="10.10.10.1"
    DNS_DEFAULT="10.10.10.2"
  fi

  DHCP_LEASE_DEFAULT="24h"
  UPSTREAM_DNS_DEFAULT="1.1.1.1"
  DOMAIN_DEFAULT="lan"

  echo -e "\n${BOLD}${BL}── DHCP/DNS Settings ──${CL}\n"

  read -rp "${TAB}DHCP range start [${DHCP_RANGE_START_DEFAULT}]: " DHCP_RANGE_START
  DHCP_RANGE_START="${DHCP_RANGE_START:-$DHCP_RANGE_START_DEFAULT}"

  read -rp "${TAB}DHCP range end [${DHCP_RANGE_END_DEFAULT}]: " DHCP_RANGE_END
  DHCP_RANGE_END="${DHCP_RANGE_END:-$DHCP_RANGE_END_DEFAULT}"

  read -rp "${TAB}DHCP lease time [${DHCP_LEASE_DEFAULT}]: " DHCP_LEASE
  DHCP_LEASE="${DHCP_LEASE:-$DHCP_LEASE_DEFAULT}"

  read -rp "${TAB}Gateway to advertise [${GW_DEFAULT}]: " GW_ADVERTISE
  GW_ADVERTISE="${GW_ADVERTISE:-$GW_DEFAULT}"

  read -rp "${TAB}DNS server to advertise [${DNS_DEFAULT}]: " DNS_ADVERTISE
  DNS_ADVERTISE="${DNS_ADVERTISE:-$DNS_DEFAULT}"

  read -rp "${TAB}Upstream DNS [${UPSTREAM_DNS_DEFAULT}]: " UPSTREAM_DNS
  UPSTREAM_DNS="${UPSTREAM_DNS:-$UPSTREAM_DNS_DEFAULT}"

  read -rp "${TAB}Local domain [${DOMAIN_DEFAULT}]: " DOMAIN
  DOMAIN="${DOMAIN:-$DOMAIN_DEFAULT}"
}

show_summary() {
  echo -e "\n${BOLD}${BL}── Summary ──${CL}\n"
  echo -e "${TAB}Container:    ${GN}${CTID}${CL} (${CT_NAME})"
  echo -e "${TAB}DHCP Range:   ${GN}${DHCP_RANGE_START} - ${DHCP_RANGE_END}${CL} (${DHCP_LEASE})"
  echo -e "${TAB}Router:       ${GN}${GW_ADVERTISE}${CL}"
  echo -e "${TAB}DNS Server:   ${GN}${DNS_ADVERTISE}${CL}"
  echo -e "${TAB}Upstream DNS: ${GN}${UPSTREAM_DNS}${CL}"
  echo -e "${TAB}Domain:       ${GN}${DOMAIN}${CL}"
  echo ""

  read -rp "${TAB}Proceed? [Y/n]: " confirm
  if [[ "${confirm,,}" == "n" ]]; then
    echo -e "${TAB}Aborted."
    exit 0
  fi
}

# ── Start Container if Stopped ───────────────────────────────────────────────
ensure_running() {
  if [[ "$CT_STATUS" != "running" ]]; then
    msg_info "Starting container ${CTID}"
    pct start "$CTID" &>/dev/null
    local count=0
    while [[ $(pct status "$CTID" 2>/dev/null | awk '{print $2}') != "running" ]]; do
      sleep 1
      ((count++))
      if [[ $count -ge 30 ]]; then
        msg_error "Container failed to start within 30s"
        exit 1
      fi
    done
    sleep 2
    msg_ok "Started container ${CTID}"
  fi
}

# ── Install & Configure dnsmasq ──────────────────────────────────────────────
install_dnsmasq() {
  msg_info "Updating package lists"
  pct exec "$CTID" -- bash -c "apt-get update -qq" &>/dev/null
  msg_ok "Updated package lists"

  msg_info "Installing dnsmasq"
  pct exec "$CTID" -- bash -c "DEBIAN_FRONTEND=noninteractive apt-get install -y -qq dnsmasq" &>/dev/null
  msg_ok "Installed dnsmasq"

  msg_info "Configuring dnsmasq"
  pct exec "$CTID" -- bash -c "cat > /etc/dnsmasq.conf << DNSMASQEOF
# dnsmasq configuration - managed by helper script
# $(date +%Y-%m-%d)

# Interface
interface=eth0
bind-interfaces

# DHCP
dhcp-range=${DHCP_RANGE_START},${DHCP_RANGE_END},${DHCP_LEASE}
dhcp-option=option:router,${GW_ADVERTISE}
dhcp-option=option:dns-server,${DNS_ADVERTISE}
dhcp-option=option:domain-name,${DOMAIN}

# DNS
domain=${DOMAIN}
local=/${DOMAIN}/
expand-hosts
server=${UPSTREAM_DNS}
server=8.8.8.8

# Static DHCP leases (add your own)
# dhcp-host=AA:BB:CC:DD:EE:FF,hostname,10.10.10.10

# Local DNS records (add your own)
# address=/myapp.${DOMAIN}/10.10.10.10

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

  msg_info "Verifying dnsmasq"
  if pct exec "$CTID" -- systemctl is-active dnsmasq &>/dev/null; then
    msg_ok "dnsmasq is running"
  else
    msg_error "dnsmasq failed to start! Check: pct exec ${CTID} -- journalctl -u dnsmasq"
    exit 1
  fi
}

# ── Completion ───────────────────────────────────────────────────────────────
show_completion() {
  echo ""
  echo -e "${BOLD}${GN}══════════════════════════════════════════════════${CL}"
  echo -e "${BOLD}${GN}  ✔ dnsmasq configured successfully!${CL}"
  echo -e "${BOLD}${GN}══════════════════════════════════════════════════${CL}"
  echo ""
  echo -e "${TAB}Container:      ${BL}${CTID}${CL} (${CT_NAME})"
  echo -e "${TAB}DHCP Range:     ${BL}${DHCP_RANGE_START} - ${DHCP_RANGE_END}${CL}"
  echo -e "${TAB}DNS Server:     ${BL}${DNS_ADVERTISE}${CL}"
  echo -e "${TAB}Domain:         ${BL}${DOMAIN}${CL}"
  echo ""
  echo -e "${TAB}${YW}Useful commands:${CL}"
  echo -e "${TAB}  View DHCP leases:   ${GN}pct exec ${CTID} -- cat /var/lib/misc/dnsmasq.leases${CL}"
  echo -e "${TAB}  View logs:          ${GN}pct exec ${CTID} -- tail -f /var/log/dnsmasq.log${CL}"
  echo -e "${TAB}  Restart dnsmasq:    ${GN}pct exec ${CTID} -- systemctl restart dnsmasq${CL}"
  echo -e "${TAB}  Edit config:        ${GN}pct exec ${CTID} -- nano /etc/dnsmasq.conf${CL}"
  echo ""
}

# ── Main ─────────────────────────────────────────────────────────────────────
main() {
  header_info
  check_root
  check_pve

  echo -e "${TAB}This script installs and configures dnsmasq (DHCP + DNS)"
  echo -e "${TAB}on an existing Proxmox LXC container.\n"

  select_container "${1:-}"
  detect_network
  get_dhcp_settings
  show_summary
  ensure_running
  install_dnsmasq
  show_completion
}

main "$@"
