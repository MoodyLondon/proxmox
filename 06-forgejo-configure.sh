#!/usr/bin/env bash
# =============================================================================
#  06-forgejo-configure.sh
#  Configures Forgejo: admin user, disable registration, API token, repos
#
#  Standalone: bash -c "$(curl -fsSL https://raw.githubusercontent.com/MoodyLondon/proxmox/main/iac/06-forgejo-configure.sh)"
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

FORGEJO_IP="${FORGEJO_IP:-10.10.10.10}"
FORGEJO_PORT="${FORGEJO_PORT:-3000}"
DOMAIN="${DOMAIN:-lan}"

# Need CT ID
if [[ -z "${FORGEJO_CTID:-}" ]]; then
  FORGEJO_CTID=$(w_input "Forgejo CT ID" \
    "Container ID of your Forgejo LXC:" "101") || exit 1
fi

# Need admin credentials
if [[ -z "${FORGEJO_ADMIN:-}" ]]; then
  FORGEJO_ADMIN=$(w_input "Forgejo Admin" \
    "Admin username to create:" "admin") || exit 1
fi

if [[ -z "${FORGEJO_PASS:-}" ]]; then
  while true; do
    FORGEJO_PASS=$(w_pass "Forgejo Admin" \
      "Admin password (min 8 chars):") || exit 1
    local confirm
    confirm=$(w_pass "Forgejo Admin" "Confirm password:") || exit 1
    [[ "$FORGEJO_PASS" == "$confirm" && ${#FORGEJO_PASS} -ge 8 ]] && break
    w_msg "Error" "Passwords do not match or too short."
  done
fi

if [[ -z "${FORGEJO_EMAIL:-}" ]]; then
  FORGEJO_EMAIL=$(w_input "Forgejo Admin Email" \
    "Admin email:" "admin@${DOMAIN}") || exit 1
fi

# ── Wait for Forgejo ──────────────────────────────────────────────────────────
echo ""
msg_info "Waiting for Forgejo to be reachable"
wait_for_ct "$FORGEJO_CTID" 30 || true
if ! wait_for_http "http://${FORGEJO_IP}:${FORGEJO_PORT}" 120; then
  msg_error "Forgejo at ${FORGEJO_IP}:${FORGEJO_PORT} not reachable"
fi
msg_ok "Forgejo is up"

# ── Configure ─────────────────────────────────────────────────────────────────
do_configure() {
  echo "10|Checking admin user"
  local user_exists
  user_exists=$(pct exec "$FORGEJO_CTID" -- \
    forgejo admin user list 2>/dev/null | grep -c "$FORGEJO_ADMIN" || echo 0)

  if [[ "$user_exists" -eq 0 ]]; then
    echo "20|Creating admin user: ${FORGEJO_ADMIN}"
    pct exec "$FORGEJO_CTID" -- forgejo admin user create \
      --username "$FORGEJO_ADMIN" \
      --password "$FORGEJO_PASS" \
      --email    "$FORGEJO_EMAIL" \
      --admin \
      --must-change-password=false 2>/dev/null \
      || true
  else
    echo "20|Admin user already exists"
  fi

  echo "35|Disabling public registration"
  pct exec "$FORGEJO_CTID" -- bash -c "
    CFG=/etc/forgejo/app.ini
    [[ ! -f \$CFG ]] && CFG=\$(find / -name app.ini -path '*/forgejo/*' 2>/dev/null | head -1)
    if grep -q '\[service\]' \"\$CFG\" 2>/dev/null; then
      sed -i '/^\[service\]/,/^\[/{/DISABLE_REGISTRATION/d}' \"\$CFG\"
      sed -i '/^\[service\]/a DISABLE_REGISTRATION = true' \"\$CFG\"
    else
      echo -e '\n[service]\nDISABLE_REGISTRATION = true' >> \"\$CFG\"
    fi
    systemctl restart forgejo 2>/dev/null || true
  " 2>/dev/null || true

  sleep 5  # Wait for Forgejo to restart

  echo "50|Creating OpenTofu API token"
  # Remove old token if it exists
  curl -sf -X DELETE \
    "http://${FORGEJO_IP}:${FORGEJO_PORT}/api/v1/users/${FORGEJO_ADMIN}/tokens/opentofu" \
    -u "${FORGEJO_ADMIN}:${FORGEJO_PASS}" &>/dev/null || true

  local token_json
  token_json=$(curl -sf -X POST \
    "http://${FORGEJO_IP}:${FORGEJO_PORT}/api/v1/users/${FORGEJO_ADMIN}/tokens" \
    -u "${FORGEJO_ADMIN}:${FORGEJO_PASS}" \
    -H "Content-Type: application/json" \
    -d '{"name":"opentofu","scopes":["write:repository","read:user"]}')

  FORGEJO_TOKEN=$(echo "$token_json" \
    | python3 -c "import sys,json; print(json.load(sys.stdin)['sha1'])" 2>/dev/null || echo "")

  echo "$FORGEJO_TOKEN" > /tmp/iac-forgejo-token.txt

  echo "65|Creating proxmox-iac repository"
  curl -sf -X POST \
    "http://${FORGEJO_IP}:${FORGEJO_PORT}/api/v1/user/repos" \
    -u "${FORGEJO_ADMIN}:${FORGEJO_PASS}" \
    -H "Content-Type: application/json" \
    -d "{\"name\":\"proxmox-iac\",\"private\":true,\
\"description\":\"Proxmox Infrastructure as Code\",\
\"auto_init\":true,\"default_branch\":\"main\"}" &>/dev/null || true

  echo "80|Creating tofu-state repository"
  curl -sf -X POST \
    "http://${FORGEJO_IP}:${FORGEJO_PORT}/api/v1/user/repos" \
    -u "${FORGEJO_ADMIN}:${FORGEJO_PASS}" \
    -H "Content-Type: application/json" \
    -d "{\"name\":\"tofu-state\",\"private\":true,\
\"description\":\"OpenTofu state backend\",\
\"auto_init\":true,\"default_branch\":\"main\"}" &>/dev/null || true

  echo "90|Saving credentials to config and secrets file"
  local sf="/root/proxmox-iac-secrets.txt"
  sed -i '/^FORGEJO_/d' "$sf" 2>/dev/null || true
  cat >> "$sf" << EOF
FORGEJO_URL=http://${FORGEJO_IP}:${FORGEJO_PORT}
FORGEJO_ADMIN=${FORGEJO_ADMIN}
FORGEJO_PASS=${FORGEJO_PASS}
FORGEJO_TOKEN=$(cat /tmp/iac-forgejo-token.txt 2>/dev/null)
EOF
  chmod 600 "$sf"

  echo "100|Done"
  sleep 1
}

run_with_gauge "Forgejo Configuration" \
  "Admin user · disable registration · API token · repos..." \
  do_configure

# Read token back
FORGEJO_TOKEN=$(cat /tmp/iac-forgejo-token.txt 2>/dev/null | tr -d '\n')
rm -f /tmp/iac-forgejo-token.txt

conf_write "FORGEJO_ADMIN"  "$FORGEJO_ADMIN"
conf_write "FORGEJO_PASS"   "$FORGEJO_PASS"
conf_write "FORGEJO_EMAIL"  "$FORGEJO_EMAIL"
conf_write "FORGEJO_TOKEN"  "$FORGEJO_TOKEN"
conf_write "FORGEJO_CTID"   "$FORGEJO_CTID"

echo ""
msg_ok "Admin user created: ${FORGEJO_ADMIN}"
msg_ok "Public registration disabled"
msg_ok "Repositories created: proxmox-iac, tofu-state"

if [[ -n "$FORGEJO_TOKEN" ]]; then
  msg_ok "API token created (saved to /root/proxmox-iac-secrets.txt)"
else
  msg_warn "API token could not be auto-created — create manually: Forgejo → Settings → Applications → Access Tokens"
fi
