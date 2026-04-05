#!/usr/bin/env bash
# =============================================================================
#  common.sh — shared functions for Proxmox IaC scripts
#  Sourced by all iac/* scripts and iac-setup.sh
# =============================================================================

# ── Colours ───────────────────────────────────────────────────────────────────
RD="\033[01;31m"; GN="\033[01;32m"; YW="\033[33m"; BL="\033[36m"
BOLD="\033[1m"; CL="\033[m"; BFR="\\r\\033[K"; TAB="   "
CM="${GN}✔${CL}"; CROSS="${RD}✖${CL}"

# ── Messages ──────────────────────────────────────────────────────────────────
msg_info()  { echo -ne "${TAB}${YW}⏳ ${1}...${CL}"; }
msg_ok()    { echo -e "${BFR}${TAB}${CM} ${1}${CL}"; }
msg_error() { echo -e "${BFR}${TAB}${CROSS} ${RD}${1}${CL}"; exit 1; }
msg_warn()  { echo -e "${TAB}${YW}⚠  ${1}${CL}"; }
msg_step()  { echo -e "\n${TAB}${BL}${BOLD}▶ ${1}${CL}"; }
msg_title() {
  echo -e "\n${BL}${BOLD}╔══════════════════════════════════════════════════╗${CL}"
  printf  "${BL}${BOLD}║  %-48s║${CL}\n" "$1"
  echo -e "${BL}${BOLD}╚══════════════════════════════════════════════════╝${CL}\n"
}

# ── Whiptail ──────────────────────────────────────────────────────────────────
BT="Proxmox IaC Bootstrap"

w_msg()   { whiptail --backtitle "$BT" --title "$1" --msgbox      "$2" 14 66; }
w_yesno() { whiptail --backtitle "$BT" --title "$1" --yesno       "$2" 12 66; return $?; }
w_input() { whiptail --backtitle "$BT" --title "$1" --inputbox    "$2" 10 60 "$3" 3>&1 1>&2 2>&3; }
w_pass()  { whiptail --backtitle "$BT" --title "$1" --passwordbox "$2" 10 60 3>&1 1>&2 2>&3; }

# Gauge: run a function with a progress bar
# Usage: run_with_gauge "Title" "Label" my_function
# The function must echo "PCT|Message" lines to update the gauge
# e.g.  echo "25|Installing packages"
run_with_gauge() {
  local title="$1" label="$2" func="$3"
  local fifo
  fifo=$(mktemp -u)
  mkfifo "$fifo"

  # Run function in background, writing PCT|MSG to fifo
  "$func" > "$fifo" 2>/tmp/iac-gauge-err &
  local pid=$!

  # Feed whiptail gauge from fifo
  while IFS='|' read -r pct msg; do
    printf "XXX\n%s\n%s\nXXX\n" "$pct" "$msg"
  done < "$fifo" | whiptail --backtitle "$BT" --title "$title" \
    --gauge "$label" 10 60 0

  wait "$pid" || { rm -f "$fifo"; cat /tmp/iac-gauge-err >&2; return 1; }
  rm -f "$fifo"
}

# ── Config file ───────────────────────────────────────────────────────────────
IAC_CONF="/tmp/proxmox-iac.conf"

conf_write() { # conf_write KEY VALUE
  # Remove existing key then append
  sed -i "/^${1}=/d" "$IAC_CONF" 2>/dev/null || true
  echo "${1}=${2}" >> "$IAC_CONF"
}

conf_read() { # conf_read KEY → echoes value
  grep -E "^${1}=" "$IAC_CONF" 2>/dev/null | cut -d= -f2- | tail -1
}

conf_load() {
  [[ -f "$IAC_CONF" ]] && source "$IAC_CONF" || true
}

# ── Utilities ─────────────────────────────────────────────────────────────────
require_root() {
  [[ $EUID -eq 0 ]] || msg_error "Must run as root"
}

require_proxmox() {
  command -v pct &>/dev/null || msg_error "Must run on a Proxmox VE host"
}

require_whiptail() {
  command -v whiptail &>/dev/null || apt-get install -y -qq whiptail
}

next_ctid() {
  local id="${1:-101}"
  while pct status "$id" &>/dev/null || qm status "$id" &>/dev/null; do
    ((id++))
  done
  echo "$id"
}

wait_for_ct() {
  local ctid="$1" timeout="${2:-60}"
  local count=0
  while [[ $(pct status "$ctid" 2>/dev/null | awk '{print $2}') != "running" ]]; do
    sleep 2; ((count += 2))
    [[ $count -ge $timeout ]] && return 1
  done
  sleep 4
  return 0
}

wait_for_http() {
  local url="$1" timeout="${2:-120}"
  local count=0
  while ! curl -sf --max-time 3 "$url" &>/dev/null; do
    sleep 3; ((count += 3))
    [[ $count -ge $timeout ]] && return 1
  done
  return 0
}
