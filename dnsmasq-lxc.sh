#!/usr/bin/env bash

# dnsmasq LXC Configurator for Proxmox VE
# Installs and configures dnsmasq on an existing LXC container
# Run this on the Proxmox host
#
# Usage: bash dnsmasq-lxc.sh [CTID]

set -Eeo pipefail

# ── Colors ───────────────────────────────────────────────────────────────────
GN="\033[01;32m"
BL="\033[36m"
BOLD="\033[1m"
CL="\033[m"
TAB="  "
PARTY="🎉"

# ── Whiptail Helpers ─────────────────────────────────────────────────────────
WHIPTAIL_BACKTITLE="Proxmox VE - dnsmasq Configurator"

whiptail_msg() {
  whiptail --backtitle "$WHIPTAIL_BACKTITLE" --title "$1" --msgbox "$2" 12 60
}

whiptail_input() {
  local title="$1" prompt="$2" default="$3"
  local result
  result=$(whiptail --backtitle "$WHIPTAIL_BACKTITLE" --title "$title" \
    --inputbox "$prompt" 10 60 "$default" 3>&1 1>&2 2>&3) || exit 1
  echo "$result"
}

whiptail_progress() {
  echo -e "XXX\n${1}\n${2}\nXXX"
}

# ── Preflight ────────────────────────────────────────────────────────────────
if [[ $EUID -ne 0 ]]; then echo "Run as root"; exit 1; fi
if ! command -v pct &>/dev/null; then echo "Run on Proxmox host"; exit 1; fi

# ── Container Selection ──────────────────────────────────────────────────────
select_container() {
  if [[ -n "${1:-}" ]]; then
    CTID="$1"
    if ! pct status "$CTID" &>/dev/null; then
      whiptail_msg "Error" "Container ${CTID} does not exist!"
      exit 1
    fi
    return
  fi

  # Build menu from running/stopped containers
  local menu_items=""
  local count=0
  while read -r id status lock name; do
    menu_items="${menu_items} ${id} ${name}_(${status})"
    ((count++))
  done < <(pct list | tail -n +2)

  if [[ $count -eq 0 ]]; then
    whiptail_msg "Error" "No containers found!\nCreate a Debian LXC first."
    exit 1
  fi

  CTID=$(whiptail --backtitle "$WHIPTAIL_BACKTITLE" \
    --title "Select Container" \
    --menu "Choose a container to install dnsmasq on:" 16 50 "$count" \
    $menu_items \
    3>&1 1>&2 2>&3) || exit 1
}

# ── Detect Network ──────────────────────────────────────────────────────────
detect_network() {
  local net_config
  net_config=$(pct config "$CTID" | grep '^net0:' || echo "")
  CT_IP=$(echo "$net_config" | grep -oP 'ip=\K[^,]+' || echo "")
  CT_GW=$(echo "$net_config" | grep -oP 'gw=\K[^,]+' || echo "")
  CT_BRIDGE=$(echo "$net_config" | grep -oP 'bridge=\K[^,]+' || echo "")
  CT_NAME=$(pct config "$CTID" | grep '^hostname:' | awk '{print $2}')
  CT_STATUS=$(pct status "$CTID" | awk '{print $2}')

  if [[ -n "$CT_IP" && "$CT_IP" != "dhcp" ]]; then
    IP_BARE="${CT_IP%%/*}"
    local subnet_prefix
    subnet_prefix=$(echo "$IP_BARE" | cut -d. -f1-3)
    DHCP_START="${subnet_prefix}.100"
    DHCP_END="${subnet_prefix}.200"
    GW_ADVERTISE="${CT_GW:-${subnet_prefix}.1}"
    DNS_ADVERTISE="$IP_BARE"
  else
    IP_BARE=""
    DHCP_START="10.10.10.100"
    DHCP_END="10.10.10.200"
    GW_ADVERTISE="10.10.10.1"
    DNS_ADVERTISE="10.10.10.2"
  fi

  DHCP_LEASE="24h"
  UPSTREAM_DNS="1.1.1.1"
  DOMAIN="lan"
}

# ── Configure Settings ───────────────────────────────────────────────────────
configure_settings() {
  local MODE
  MODE=$(whiptail --backtitle "$WHIPTAIL_BACKTITLE" \
    --title "Configuration" \
    --menu "Container: ${CTID} (${CT_NAME})\nDetected IP: ${CT_IP:-none} on ${CT_BRIDGE:-unknown}" 14 60 2 \
    "1" "Use Defaults (recommended)" \
    "2" "Advanced Configuration" \
    3>&1 1>&2 2>&3) || exit 1

  if [[ "$MODE" == "2" ]]; then
    DHCP_START=$(whiptail_input "DHCP Start" "DHCP range start:" "$DHCP_START")
    DHCP_END=$(whiptail_input "DHCP End" "DHCP range end:" "$DHCP_END")
    DHCP_LEASE=$(whiptail_input "Lease Time" "DHCP lease time:" "$DHCP_LEASE")
    GW_ADVERTISE=$(whiptail_input "Gateway" "Gateway to advertise:" "$GW_ADVERTISE")
    DNS_ADVERTISE=$(whiptail_input "DNS Server" "DNS server to advertise:" "$DNS_ADVERTISE")
    UPSTREAM_DNS=$(whiptail_input "Upstream DNS" "Upstream DNS server:" "$UPSTREAM_DNS")
    DOMAIN=$(whiptail_input "Domain" "Local domain name:" "$DOMAIN")
  fi
}

# ── Confirm ──────────────────────────────────────────────────────────────────
confirm_settings() {
  whiptail --backtitle "$WHIPTAIL_BACKTITLE" \
    --title "Confirm Settings" \
    --yesno "\
CT ${CTID} (${CT_NAME}) - ${CT_STATUS}\n\
DHCP: ${DHCP_START}-${DHCP_END} (${DHCP_LEASE})\n\
Router: ${GW_ADVERTISE}  DNS: ${DNS_ADVERTISE}\n\
Upstream: ${UPSTREAM_DNS}  Domain: ${DOMAIN}\n\n\
Install dnsmasq?" 12 55 || exit 0
}

# ── Installation ─────────────────────────────────────────────────────────────
run_installation() {
  {
    # Start container if needed
    whiptail_progress 5 "Checking container status..."
    if [[ "$CT_STATUS" != "running" ]]; then
      pct start "$CTID" &>/dev/null
      local count=0
      while [[ $(pct status "$CTID" 2>/dev/null | awk '{print $2}') != "running" ]]; do
        sleep 1
        ((count++))
        [[ $count -ge 30 ]] && break
      done
      sleep 2
    fi

    whiptail_progress 20 "Updating package lists..."
    pct exec "$CTID" -- bash -c "apt-get update -qq" &>/dev/null

    whiptail_progress 40 "Installing dnsmasq..."
    pct exec "$CTID" -- bash -c "DEBIAN_FRONTEND=noninteractive apt-get install -y -qq dnsmasq" &>/dev/null

    whiptail_progress 60 "Writing dnsmasq configuration..."
    pct exec "$CTID" -- bash -c "cat > /etc/dnsmasq.conf << DNSMASQEOF
# dnsmasq configuration - managed by helper script
# $(date +%Y-%m-%d)

# Interface
interface=eth0
bind-interfaces

# DHCP
dhcp-range=${DHCP_START},${DHCP_END},${DHCP_LEASE}
dhcp-option=option:router,${GW_ADVERTISE}
dhcp-option=option:dns-server,${DNS_ADVERTISE}
dhcp-option=option:domain-name,${DOMAIN}

# DNS
domain=${DOMAIN}
local=/${DOMAIN}/
expand-hosts
server=${UPSTREAM_DNS}
server=8.8.8.8

# Static DHCP leases
# dhcp-host=AA:BB:CC:DD:EE:FF,hostname,10.10.10.10

# Local DNS records
# address=/myapp.${DOMAIN}/10.10.10.10

# Logging
log-dhcp
log-queries
log-facility=/var/log/dnsmasq.log

# Performance
cache-size=1000
DNSMASQEOF"

    whiptail_progress 75 "Setting up log rotation..."
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

    whiptail_progress 85 "Starting dnsmasq service..."
    pct exec "$CTID" -- systemctl enable dnsmasq &>/dev/null
    pct exec "$CTID" -- systemctl restart dnsmasq &>/dev/null

    whiptail_progress 95 "Verifying..."
    sleep 1

    whiptail_progress 100 "Complete!"
    sleep 1
  } | whiptail --backtitle "$WHIPTAIL_BACKTITLE" \
      --title "Installing dnsmasq" \
      --gauge "Starting..." 8 60 0

  # Verify
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
dnsmasq configured on CT ${CTID} (${CT_NAME})\n\
DHCP: ${DHCP_START}-${DHCP_END}  Router: ${GW_ADVERTISE}\n\
DNS: ${DNS_ADVERTISE}  Domain: ${DOMAIN}\n\n\
Leases: pct exec ${CTID} -- cat /var/lib/misc/dnsmasq.leases\n\
Logs:   pct exec ${CTID} -- tail -f /var/log/dnsmasq.log\n\
Config: pct exec ${CTID} -- nano /etc/dnsmasq.conf" 14 62

  clear
  echo -e "\n${TAB}${GN}${BOLD}${PARTY} dnsmasq configured on container ${CTID} (${CT_NAME})${CL}\n"
  echo -e "${TAB}DHCP: ${BL}${DHCP_START} - ${DHCP_END}${CL}"
  echo -e "${TAB}DNS:  ${BL}${DNS_ADVERTISE}${CL} (domain: ${DOMAIN})\n"
}

# ── Main ─────────────────────────────────────────────────────────────────────
select_container "${1:-}"
detect_network
configure_settings
confirm_settings
run_installation
show_completion
