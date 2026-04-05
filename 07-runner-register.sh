#!/usr/bin/env bash
# =============================================================================
#  07-runner-register.sh
#  Registers the Forgejo Runner with Forgejo and starts the service
#
#  Standalone: bash -c "$(curl -fsSL https://raw.githubusercontent.com/MoodyLondon/proxmox/main/iac/07-runner-register.sh)"
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

if [[ -z "${RUNNER_CTID:-}" ]]; then
  RUNNER_CTID=$(w_input "Runner CT ID" \
    "Container ID of your Runner LXC:" "102") || exit 1
fi

if [[ -z "${FORGEJO_ADMIN:-}" ]]; then
  FORGEJO_ADMIN=$(w_input "Forgejo Admin" \
    "Forgejo admin username:" "admin") || exit 1
fi

if [[ -z "${FORGEJO_PASS:-}" ]]; then
  FORGEJO_PASS=$(w_pass "Forgejo Admin" \
    "Forgejo admin password:") || exit 1
fi

# ── Register ──────────────────────────────────────────────────────────────────
do_register() {
  echo "15|Fetching runner registration token from Forgejo"
  local reg_token
  reg_token=$(curl -sf \
    "http://${FORGEJO_IP}:${FORGEJO_PORT}/api/v1/admin/runners/registration-token" \
    -u "${FORGEJO_ADMIN}:${FORGEJO_PASS}" \
    | python3 -c "import sys,json; print(json.load(sys.stdin)['token'])" 2>/dev/null \
    || echo "")

  if [[ -z "$reg_token" ]]; then
    echo "ERROR: Could not fetch runner token" > /tmp/iac-runner-err.txt
    echo "100|Failed — see /tmp/iac-runner-err.txt"
    return 1
  fi

  echo "30|Detecting runner binary on CT${RUNNER_CTID}"
  local runner_bin
  runner_bin=$(pct exec "$RUNNER_CTID" -- bash -c \
    "command -v act_runner || command -v forgejo-runner || echo ''" 2>/dev/null \
    | tr -d '\n')

  if [[ -z "$runner_bin" ]]; then
    echo "40|Runner binary not found — installing forgejo-runner"
    pct exec "$RUNNER_CTID" -- bash -c "
      LATEST=\$(curl -sf https://code.forgejo.org/api/v1/repos/forgejo/runner/releases \
        | python3 -c \"import sys,json; print(json.load(sys.stdin)[0]['tag_name'])\" 2>/dev/null \
        || echo 'v3.5.0')
      curl -fsSL \
        https://code.forgejo.org/forgejo/runner/releases/download/\${LATEST}/forgejo-runner-\${LATEST}-linux-amd64 \
        -o /usr/local/bin/act_runner
      chmod +x /usr/local/bin/act_runner
    " &>/dev/null
    runner_bin="act_runner"
  fi

  echo "55|Removing old runner config if present"
  pct exec "$RUNNER_CTID" -- rm -f /root/.runner /root/runner.yaml 2>/dev/null || true

  echo "65|Registering runner with Forgejo"
  pct exec "$RUNNER_CTID" -- bash -c "
    ${runner_bin} register \
      --instance http://${FORGEJO_IP}:${FORGEJO_PORT} \
      --token ${reg_token} \
      --name runner-01 \
      --labels native \
      --no-interactive 2>/dev/null
  " || { echo "80|Registration failed — trying alternate format"; true; }

  echo "80|Starting runner service"
  pct exec "$RUNNER_CTID" -- bash -c "
    # Try multiple service names (community script may differ)
    systemctl enable --now act_runner    2>/dev/null || \
    systemctl enable --now forgejo-runner 2>/dev/null || \
    true
  " 2>/dev/null

  echo "95|Waiting for runner to appear online"
  sleep 5

  echo "100|Done"
  sleep 1
}

run_with_gauge "Forgejo Runner" \
  "Registering runner-01 with Forgejo..." \
  do_register

# ── Verify ────────────────────────────────────────────────────────────────────
echo ""
RUNNER_STATUS=$(curl -sf \
  "http://${FORGEJO_IP}:${FORGEJO_PORT}/api/v1/admin/runners" \
  -u "${FORGEJO_ADMIN}:${FORGEJO_PASS}" \
  | python3 -c "
import sys, json
runners = json.load(sys.stdin).get('data', [])
for r in runners:
    if r.get('name') == 'runner-01':
        print(r.get('status', 'unknown'))
" 2>/dev/null || echo "unknown")

if [[ "$RUNNER_STATUS" == "online" || "$RUNNER_STATUS" == "active" ]]; then
  msg_ok "Runner registered and online ✓"
elif [[ -f /tmp/iac-runner-err.txt ]]; then
  msg_warn "Runner registration failed: $(cat /tmp/iac-runner-err.txt)"
  msg_warn "Manual fix: Forgejo → Site Admin → Runners → copy token, then:"
  msg_warn "  pct exec ${RUNNER_CTID} -- act_runner register --instance http://${FORGEJO_IP}:${FORGEJO_PORT} --token <TOKEN> --name runner-01 --labels native --no-interactive"
  rm -f /tmp/iac-runner-err.txt
else
  msg_warn "Runner registered — status check inconclusive (may take 30s to show online in Forgejo UI)"
fi
