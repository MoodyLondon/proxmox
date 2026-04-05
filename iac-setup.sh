#!/usr/bin/env bash
# =============================================================================
#  iac-setup.sh — Proxmox IaC Orchestrator
#
#  Runs all setup scripts in order, or lets you pick individual ones.
#
#  Run from Proxmox host shell:
#    bash -c "$(curl -fsSL https://raw.githubusercontent.com/MoodyLondon/proxmox/main/iac-setup.sh)"
# =============================================================================

set -Eeo pipefail

BASE_URL="https://raw.githubusercontent.com/MoodyLondon/proxmox/main"
IAC_CONF="/tmp/proxmox-iac.conf"

# ── Bootstrap: load common functions ─────────────────────────────────────────
source <(curl -fsSL "${BASE_URL}/iac/common.sh")

require_root
require_proxmox
require_whiptail

# ── Welcome ───────────────────────────────────────────────────────────────────
whiptail --backtitle "$BT" \
  --title "🚀  Proxmox IaC Setup" \
  --msgbox "\
Infrastructure as Code setup for Proxmox.\n\
\n\
This will set up:\n\
\n\
  ① dnsmasq static leases (pin IPs)\n\
  ② Proxmox API token for OpenTofu\n\
  ③ Forgejo LXC          (10.10.10.10)\n\
  ④ Forgejo Runner LXC   (10.10.10.11)\n\
  ⑤ Komodo / Docker LXC  (10.10.10.12)\n\
  ⑥ Forgejo configuration (admin, repos)\n\
  ⑦ Runner registered with Forgejo\n\
  ⑧ OpenTofu repo scaffolded + pushed\n\
\n\
Requires: bootstrap.sh already run (vmbr1 + dnsmasq)\n\
\n\
You can run all steps or pick individual ones." \
  20 66

# ── Mode selection ────────────────────────────────────────────────────────────
MODE=$(whiptail --backtitle "$BT" \
  --title "Setup Mode" \
  --menu "How would you like to proceed?" 14 60 3 \
  "1" "Full install — run all steps in order" \
  "2" "Pick steps — choose which to run" \
  "3" "Exit" \
  3>&1 1>&2 2>&3) || exit 0

[[ "$MODE" == "3" ]] && exit 0

# ── Collect all settings upfront ─────────────────────────────────────────────
collect_settings() {
  # Load any previously saved config
  conf_load

  # ── dnsmasq ─────────────────────────────────────────────────────
  DNSMASQ_CTID=$(w_input "dnsmasq LXC" \
    "Container ID of your existing dnsmasq LXC:" \
    "${DNSMASQ_CTID:-100}") || exit 1

  if ! pct status "$DNSMASQ_CTID" &>/dev/null; then
    w_msg "Error" "Container $DNSMASQ_CTID not found.\nRun bootstrap.sh first, then re-run this script."
    exit 1
  fi

  # ── CT IDs for new LXCs ─────────────────────────────────────────
  local next
  next=$(next_ctid 101)

  FORGEJO_CTID=$(w_input "Forgejo LXC ID" \
    "Container ID to use for Forgejo LXC:" \
    "${FORGEJO_CTID:-$next}") || exit 1
  next=$(next_ctid $((FORGEJO_CTID + 1)))

  RUNNER_CTID=$(w_input "Runner LXC ID" \
    "Container ID to use for Forgejo Runner LXC:" \
    "${RUNNER_CTID:-$next}") || exit 1
  next=$(next_ctid $((RUNNER_CTID + 1)))

  KOMODO_CTID=$(w_input "Komodo LXC ID" \
    "Container ID to use for Komodo / Docker LXC:" \
    "${KOMODO_CTID:-$next}") || exit 1

  # ── Forgejo admin ────────────────────────────────────────────────
  FORGEJO_ADMIN=$(w_input "Forgejo Admin" \
    "Admin username for Forgejo:" \
    "${FORGEJO_ADMIN:-admin}") || exit 1

  while true; do
    FORGEJO_PASS=$(w_pass "Forgejo Admin Password" \
      "Password for ${FORGEJO_ADMIN} (min 8 chars):") || exit 1
    local confirm
    confirm=$(w_pass "Confirm Password" "Confirm password:") || exit 1
    if [[ "$FORGEJO_PASS" == "$confirm" && ${#FORGEJO_PASS} -ge 8 ]]; then break; fi
    w_msg "Password Error" "Passwords do not match or are fewer than 8 characters."
  done

  FORGEJO_EMAIL=$(w_input "Forgejo Admin Email" \
    "Email for ${FORGEJO_ADMIN}:" \
    "${FORGEJO_EMAIL:-admin@lan}") || exit 1

  # ── Komodo passkey ───────────────────────────────────────────────
  KOMODO_PASSKEY=$(w_pass "Komodo Passkey" \
    "Komodo passkey (min 8 chars, or leave blank to auto-generate):") || exit 1
  if [[ ${#KOMODO_PASSKEY} -lt 8 ]]; then
    KOMODO_PASSKEY=$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 32)
    w_msg "Komodo Passkey" \
      "Auto-generated passkey:\n\n  ${KOMODO_PASSKEY}\n\nSaved to /root/proxmox-iac-secrets.txt"
  fi

  # ── Confirm ──────────────────────────────────────────────────────
  whiptail --backtitle "$BT" --title "Confirm Settings" --yesno "\
  Forgejo LXC:   CT${FORGEJO_CTID}  →  10.10.10.10\n\
  Runner LXC:    CT${RUNNER_CTID}   →  10.10.10.11\n\
  Komodo LXC:    CT${KOMODO_CTID}   →  10.10.10.12\n\
\n\
  Forgejo admin: ${FORGEJO_ADMIN} <${FORGEJO_EMAIL}>\n\
  Storage:       local-lvm\n\
  Node:          pve1\n\
\n\
  Proceed?" 16 58 || exit 0

  # ── Save to config ───────────────────────────────────────────────
  conf_write "DNSMASQ_CTID"   "$DNSMASQ_CTID"
  conf_write "FORGEJO_CTID"   "$FORGEJO_CTID"
  conf_write "RUNNER_CTID"    "$RUNNER_CTID"
  conf_write "KOMODO_CTID"    "$KOMODO_CTID"
  conf_write "FORGEJO_ADMIN"  "$FORGEJO_ADMIN"
  conf_write "FORGEJO_PASS"   "$FORGEJO_PASS"
  conf_write "FORGEJO_EMAIL"  "$FORGEJO_EMAIL"
  conf_write "KOMODO_PASSKEY" "$KOMODO_PASSKEY"

  # Initialise the secrets file
  cat > /root/proxmox-iac-secrets.txt << EOF
# Proxmox IaC Secrets — generated $(date)
# Copy values into secrets.env, encrypt with SOPS, then delete this file.
FORGEJO_ADMIN=${FORGEJO_ADMIN}
FORGEJO_PASS=${FORGEJO_PASS}
KOMODO_PASSKEY=${KOMODO_PASSKEY}
EOF
  chmod 600 /root/proxmox-iac-secrets.txt
}

# ── Run a script from the repo ────────────────────────────────────────────────
run_script() {
  local name="$1" url="${BASE_URL}/iac/${1}"
  msg_title "Running: ${name}"
  bash <(curl -fsSL "$url")
}

# ── All steps list ────────────────────────────────────────────────────────────
STEPS=(
  "01-dnsmasq-leases.sh"
  "02-proxmox-api-token.sh"
  "03-forgejo-lxc.sh"
  "04-runner-lxc.sh"
  "05-komodo-lxc.sh"
  "06-forgejo-configure.sh"
  "07-runner-register.sh"
  "08-scaffold-repo.sh"
)

STEP_LABELS=(
  "01  dnsmasq static leases"
  "02  Proxmox API token"
  "03  Forgejo LXC (community script)"
  "04  Runner LXC + tool install"
  "05  Komodo / Docker LXC"
  "06  Forgejo configuration"
  "07  Register runner"
  "08  Scaffold + push repo"
)

# ── Full install ──────────────────────────────────────────────────────────────
run_full() {
  collect_settings
  for script in "${STEPS[@]}"; do
    run_script "$script"
    echo ""
    echo -e "${TAB}${GN}✔ ${script} complete${CL}"
    echo ""
  done
}

# ── Pick steps ────────────────────────────────────────────────────────────────
run_pick() {
  # Build whiptail checklist
  local items=()
  for i in "${!STEPS[@]}"; do
    items+=("${STEPS[$i]}" "${STEP_LABELS[$i]}" "OFF")
  done

  local selected
  selected=$(whiptail --backtitle "$BT" \
    --title "Select Steps" \
    --checklist "Space to select, Enter to confirm:" \
    22 70 10 \
    "${items[@]}" \
    3>&1 1>&2 2>&3) || exit 0

  # At least collect settings so scripts have their env vars
  collect_settings

  # Run selected scripts in order
  for script in "${STEPS[@]}"; do
    if echo "$selected" | grep -q "\"${script}\""; then
      run_script "$script"
      echo ""
      echo -e "${TAB}${GN}✔ ${script} complete${CL}"
      echo ""
    fi
  done
}

# ── Execute ───────────────────────────────────────────────────────────────────
case "$MODE" in
  1) run_full ;;
  2) run_pick ;;
esac

# ── Final summary ─────────────────────────────────────────────────────────────
conf_load

clear
echo ""
echo -e "${GN}${BOLD}╔══════════════════════════════════════════════════════════╗${CL}"
echo -e "${GN}${BOLD}║       🎉  Proxmox IaC Setup Complete!                   ║${CL}"
echo -e "${GN}${BOLD}╚══════════════════════════════════════════════════════════╝${CL}"
echo ""
echo -e "  ${CM} Forgejo   →  http://10.10.10.10:3000   (${FORGEJO_ADMIN:-admin})"
echo -e "  ${CM} Komodo    →  http://10.10.10.12:9120"
echo -e "  ${CM} Runner    →  10.10.10.11 (registered, native executor)"
echo ""
echo -e "${YW}${BOLD}  ── 3 manual steps remaining ────────────────────────────${CL}"
echo ""
echo -e "  ${YW}1.${CL} On your workstation:"
echo -e "       git clone ssh://git@10.10.10.10:22/${FORGEJO_ADMIN:-admin}/proxmox-iac.git"
echo -e "       cp secrets.env.example secrets.env"
echo -e "       nano secrets.env  ← values in /root/proxmox-iac-secrets.txt"
echo -e "       sops --encrypt secrets.env > secrets.enc.env"
echo -e "       git add secrets.enc.env && git commit -m 'secrets: initial' && git push"
echo -e "       rm secrets.env"
echo ""
echo -e "  ${YW}2.${CL} Proxmox UI → Datacenter → Storage → local → Edit → tick ${BOLD}Snippets${CL}"
echo ""
echo -e "  ${YW}3.${CL} Delete /root/proxmox-iac-secrets.txt after use"
echo ""
echo -e "  ${BL}Optional later:${CL} bash scripts/sync-to-bitwarden.sh"
echo ""
echo -e "  Secrets file: ${YW}/root/proxmox-iac-secrets.txt${CL} ← delete after use!"
echo ""
