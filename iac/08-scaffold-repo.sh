#!/usr/bin/env bash
# =============================================================================
#  08-scaffold-repo.sh
#  Scaffolds the proxmox-iac repository and pushes it to Forgejo
#
#  Standalone: bash -c "$(curl -fsSL https://raw.githubusercontent.com/MoodyLondon/proxmox/main/iac/08-scaffold-repo.sh)"
# =============================================================================

COMMON_URL="https://raw.githubusercontent.com/MoodyLondon/proxmox/main/iac/common.sh"
if [[ -f "$(dirname "$0")/common.sh" ]]; then
  source "$(dirname "$0")/common.sh"
else
  source <(curl -fsSL "$COMMON_URL")
fi

require_root
require_whiptail
conf_load

FORGEJO_IP="${FORGEJO_IP:-10.10.10.10}"
FORGEJO_PORT="${FORGEJO_PORT:-3000}"
FORGEJO_ADMIN="${FORGEJO_ADMIN:-admin}"
GATEWAY="${GATEWAY:-10.10.10.1}"

if [[ -z "${FORGEJO_PASS:-}" ]]; then
  FORGEJO_PASS=$(w_pass "Forgejo Admin" \
    "Forgejo admin password:") || exit 1
fi

if [[ -z "${FORGEJO_TOKEN:-}" ]]; then
  FORGEJO_TOKEN=$(w_input "Forgejo API Token" \
    "Forgejo API token (from 06-forgejo-configure.sh or Settings → Applications):" \
    "") || exit 1
fi

# ── Build scaffold ────────────────────────────────────────────────────────────
WORK=$(mktemp -d)
trap "rm -rf $WORK" EXIT

do_scaffold() {
  echo "5|Creating directory structure"
  mkdir -p \
    "$WORK/.forgejo/workflows" \
    "$WORK/tofu/modules/vm" \
    "$WORK/tofu/modules/lxc" \
    "$WORK/ansible/playbooks" \
    "$WORK/ansible/roles" \
    "$WORK/cloud-init" \
    "$WORK/scripts"

  # ── .gitignore ──────────────────────────────────────────────────
  echo "10|Writing .gitignore"
  cat > "$WORK/.gitignore" << 'EOF'
.terraform/
.terraform.lock.hcl
*.tfplan
tfplan
*.tfstate
*.tfstate.backup
secrets.env
*.tfvars
!*.tfvars.example
EOF

  # ── .sops.yaml ──────────────────────────────────────────────────
  echo "15|Writing .sops.yaml"
  cat > "$WORK/.sops.yaml" << EOF
# SOPS configuration
# age private key lives on the runner at /root/.config/sops/age/keys.txt
# Never commit the private key — only the public key goes here.
creation_rules:
  - path_regex: secrets\\.enc\\.env\$
    age: ${AGE_PUBLIC_KEY:-<paste-age-public-key-here>}
EOF

  # ── secrets.env.example ─────────────────────────────────────────
  echo "20|Writing secrets.env.example"
  cat > "$WORK/secrets.env.example" << EOF
# secrets.env — fill in real values from /root/proxmox-iac-secrets.txt
# Then encrypt and commit:
#
#   cp secrets.env.example secrets.env
#   nano secrets.env
#   sops --encrypt secrets.env > secrets.enc.env
#   git add secrets.enc.env && git commit -m 'secrets: initial'
#   rm secrets.env   ← NEVER commit this file

PROXMOX_URL=https://<proxmox-vmbr0-ip>:8006
PROXMOX_API_TOKEN=root@pam!opentofu=<token>
FORGEJO_TOKEN=<forgejo-api-token>
SSH_PUBLIC_KEY=<paste-contents-of-ansible_id.pub>
EOF

  # ── tofu/providers.tf ───────────────────────────────────────────
  echo "25|Writing OpenTofu providers.tf"
  cat > "$WORK/tofu/providers.tf" << EOF
terraform {
  required_version = ">= 1.6"
  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = "~> 0.50"
    }
  }

  backend "http" {
    address        = "http://${FORGEJO_IP}:${FORGEJO_PORT}/api/v1/repos/${FORGEJO_ADMIN}/tofu-state/contents/state.tfstate"
    lock_address   = "http://${FORGEJO_IP}:${FORGEJO_PORT}/api/v1/repos/${FORGEJO_ADMIN}/tofu-state/contents/state.tfstate"
    unlock_address = "http://${FORGEJO_IP}:${FORGEJO_PORT}/api/v1/repos/${FORGEJO_ADMIN}/tofu-state/contents/state.tfstate"
  }
}

provider "proxmox" {
  endpoint  = var.proxmox_url
  api_token = var.proxmox_token
  insecure  = true
}
EOF

  # ── tofu/variables.tf ───────────────────────────────────────────
  echo "30|Writing variables.tf"
  cat > "$WORK/tofu/variables.tf" << 'EOF'
variable "proxmox_url"     { type = string }
variable "proxmox_token"   { type = string; sensitive = true }
variable "ssh_public_key"  { type = string }
variable "node_name"       { type = string; default = "pve1" }
EOF

  # ── tofu/main.tf ────────────────────────────────────────────────
  echo "35|Writing main.tf"
  cat > "$WORK/tofu/main.tf" << 'EOF'
# Download Ubuntu 22.04 cloud image (cached after first run)
resource "proxmox_virtual_environment_download_file" "ubuntu_2204" {
  content_type = "iso"
  datastore_id = "local"
  node_name    = var.node_name
  url          = "https://cloud-images.ubuntu.com/jammy/current/jammy-server-cloudimg-amd64.img"
}

# ── Add VMs below using the module ───────────────────────────────────────────
# module "my_vm" {
#   source         = "./modules/vm"
#   vm_name        = "my-vm-01"
#   vm_id          = 200
#   template_id    = proxmox_virtual_environment_download_file.ubuntu_2204.id
#   ip_address     = "10.10.10.100"
#   ssh_public_key = var.ssh_public_key
# }
EOF

  # ── tofu/modules/vm/main.tf ─────────────────────────────────────
  echo "40|Writing VM module"
  cat > "$WORK/tofu/modules/vm/main.tf" << EOF
resource "proxmox_virtual_environment_file" "cloud_config" {
  content_type = "snippets"
  datastore_id = "local"
  node_name    = var.node_name
  source_raw {
    data      = templatefile("\${path.module}/../../cloud-init/base.yaml", {
      ssh_public_key = var.ssh_public_key
    })
    file_name = "\${var.vm_name}-init.yaml"
  }
}

resource "proxmox_virtual_environment_vm" "vm" {
  name      = var.vm_name
  node_name = var.node_name
  vm_id     = var.vm_id
  agent  { enabled = true }
  cpu    { cores = var.cpu_cores; type = "x86-64-v2-AES" }
  memory { dedicated = var.memory_mb }

  disk {
    datastore_id = "local-lvm"
    file_id      = var.template_id
    interface    = "virtio0"
    size         = var.disk_gb
    discard      = "on"
  }

  network_device { bridge = "vmbr1"; model = "virtio" }

  initialization {
    ip_config {
      ipv4 { address = "\${var.ip_address}/24"; gateway = "${GATEWAY}" }
    }
    user_data_file_id = proxmox_virtual_environment_file.cloud_config.id
  }
}
EOF

  cat > "$WORK/tofu/modules/vm/variables.tf" << 'EOF'
variable "vm_name"        { type = string }
variable "vm_id"          { type = number }
variable "node_name"      { type = string; default = "pve1" }
variable "template_id"    { type = string }
variable "cpu_cores"      { type = number; default = 2 }
variable "memory_mb"      { type = number; default = 2048 }
variable "disk_gb"        { type = number; default = 20 }
variable "ip_address"     { type = string }
variable "ssh_public_key" { type = string }
EOF

  # ── cloud-init/base.yaml ────────────────────────────────────────
  echo "50|Writing cloud-init template"
  cat > "$WORK/cloud-init/base.yaml" << 'EOF'
#cloud-config
users:
  - name: admin
    groups: sudo
    shell: /bin/bash
    sudo: ALL=(ALL) NOPASSWD:ALL
    ssh_authorized_keys:
      - ${ssh_public_key}
disable_root: true
packages: [curl, git, vim, qemu-guest-agent]
runcmd:
  - systemctl enable --now qemu-guest-agent
  - apt-get update -q && apt-get upgrade -yq
timezone: Europe/London
EOF

  # ── Ansible playbook ────────────────────────────────────────────
  echo "55|Writing Ansible base playbook"
  cat > "$WORK/ansible/playbooks/base.yml" << 'EOF'
---
- name: Base hardening
  hosts: all
  become: true
  tasks:
    - name: Install security packages
      apt:
        name: [fail2ban, ufw, unattended-upgrades]
        state: present
        update_cache: yes

    - name: UFW default deny inbound
      ufw: { state: enabled, policy: deny, direction: incoming }

    - name: Allow SSH
      ufw: { rule: allow, port: '22', proto: tcp }

    - name: Enable unattended upgrades
      copy:
        dest: /etc/apt/apt.conf.d/20auto-upgrades
        content: |
          APT::Periodic::Update-Package-Lists "1";
          APT::Periodic::Unattended-Upgrade "1";
EOF

  # ── Forgejo Actions pipeline ────────────────────────────────────
  echo "65|Writing Forgejo Actions pipeline"
  cat > "$WORK/.forgejo/workflows/tofu.yml" << EOF
name: OpenTofu

on:
  push:
    branches: [main]
    paths: ['tofu/**', 'cloud-init/**', 'secrets.enc.env']
  pull_request:
    branches: [main]
    paths: ['tofu/**', 'cloud-init/**']

jobs:
  tofu:
    runs-on: native
    steps:
      - uses: actions/checkout@v4

      - name: Decrypt secrets
        run: |
          # age private key is at /root/.config/sops/age/keys.txt on the runner
          # SOPS finds it automatically via the default key file path
          sops --decrypt secrets.enc.env > /tmp/secrets.env
          set -a && source /tmp/secrets.env && set +a
          rm -f /tmp/secrets.env

          echo "TF_VAR_proxmox_url=\${PROXMOX_URL}"          >> \$GITHUB_ENV
          echo "TF_VAR_proxmox_token=\${PROXMOX_API_TOKEN}"  >> \$GITHUB_ENV
          echo "TF_VAR_ssh_public_key=\${SSH_PUBLIC_KEY}"    >> \$GITHUB_ENV
          echo "TF_HTTP_USERNAME=${FORGEJO_ADMIN}"            >> \$GITHUB_ENV
          echo "TF_HTTP_PASSWORD=\${FORGEJO_TOKEN}"           >> \$GITHUB_ENV

      - name: OpenTofu Init
        working-directory: tofu/
        run: tofu init

      - name: OpenTofu Plan
        working-directory: tofu/
        run: tofu plan -out=tfplan

      - name: OpenTofu Apply
        if: github.ref == 'refs/heads/main' && github.event_name == 'push'
        working-directory: tofu/
        run: tofu apply -auto-approve tfplan
EOF

  # ── Bitwarden sync helper ───────────────────────────────────────
  echo "75|Writing Bitwarden sync script"
  cat > "$WORK/scripts/sync-to-bitwarden.sh" << 'EOF'
#!/usr/bin/env bash
# sync-to-bitwarden.sh
# Optional: syncs secrets from sops to your Bitwarden vault
# Requires: bw CLI (https://bitwarden.com/help/cli/) + sops on this machine
set -euo pipefail

command -v bw   &>/dev/null || { echo "bw CLI not found"; exit 1; }
command -v sops &>/dev/null || { echo "sops not found"; exit 1; }
[[ -f secrets.enc.env ]] || { echo "secrets.enc.env not found — run from repo root"; exit 1; }

echo "Decrypting secrets..."
sops --decrypt secrets.enc.env > /tmp/iac-bw-secrets.env
source /tmp/iac-bw-secrets.env
rm -f /tmp/iac-bw-secrets.env

BW_SESSION=$(bw unlock --raw 2>/dev/null || bw login --raw)
export BW_SESSION

FOLDER="proxmox-iac"
FID=$(bw list folders --session "$BW_SESSION" \
  | python3 -c "import sys,json; items=json.load(sys.stdin); \
    print(next((i['id'] for i in items if i['name']=='$FOLDER'), ''))" 2>/dev/null)

[[ -z "$FID" ]] && FID=$(bw create folder --session "$BW_SESSION" \
  "$(echo "{\"name\":\"$FOLDER\"}" | bw encode)" | python3 -c "import sys,json; print(json.load(sys.stdin)['id'])")

sync_secret() {
  local name="$1" val="$2"
  local tmpl existing_id
  tmpl=$(bw get template item.login | python3 -c "
import sys, json, os
t = json.load(sys.stdin)
t['name'] = os.environ['NAME']
t['login']['password'] = os.environ['VAL']
t['folderId'] = os.environ['FID']
t['type'] = 2
print(json.dumps(t))" NAME="$name" VAL="$val" FID="$FID")

  existing_id=$(bw list items --session "$BW_SESSION" --search "$name" \
    | python3 -c "import sys,json; items=json.load(sys.stdin); \
      print(next((i['id'] for i in items if i['name']=='$name'), ''))" 2>/dev/null)

  if [[ -n "$existing_id" ]]; then
    echo "  Updating: $name"
    echo "$tmpl" | bw encode | bw edit item "$existing_id" --session "$BW_SESSION" &>/dev/null
  else
    echo "  Creating: $name"
    echo "$tmpl" | bw encode | bw create item --session "$BW_SESSION" &>/dev/null
  fi
}

echo "Syncing to Bitwarden folder: $FOLDER"
sync_secret "PROXMOX_URL"       "${PROXMOX_URL:-}"
sync_secret "PROXMOX_API_TOKEN" "${PROXMOX_API_TOKEN:-}"
sync_secret "FORGEJO_TOKEN"     "${FORGEJO_TOKEN:-}"
sync_secret "SSH_PUBLIC_KEY"    "${SSH_PUBLIC_KEY:-}"

bw sync --session "$BW_SESSION" &>/dev/null
echo "Done."
EOF
  chmod +x "$WORK/scripts/sync-to-bitwarden.sh"

  # ── README ──────────────────────────────────────────────────────
  echo "85|Writing README"
  cat > "$WORK/README.md" << EOF
# proxmox-iac

Infrastructure as Code for Proxmox — managed via OpenTofu, Forgejo, SOPS.

## Quick Start

### Secrets (first time only)
\`\`\`bash
cp secrets.env.example secrets.env
nano secrets.env          # fill in values from /root/proxmox-iac-secrets.txt on Proxmox host
sops --encrypt secrets.env > secrets.enc.env
git add secrets.enc.env && git commit -m 'secrets: initial'
git push && rm secrets.env
\`\`\`

### Add a VM
In \`tofu/main.tf\`, uncomment and edit the module block, then push to main.

### Rotate a secret
\`\`\`bash
sops --decrypt secrets.enc.env > secrets.env
nano secrets.env
sops --encrypt secrets.env > secrets.enc.env
git add secrets.enc.env && git commit -m 'secrets: rotate' && git push
rm secrets.env
\`\`\`

### Sync to Bitwarden (optional)
\`\`\`bash
bash scripts/sync-to-bitwarden.sh
\`\`\`

## Before first pipeline run
Proxmox UI → Datacenter → Storage → local → Edit → tick **Snippets**
EOF

  echo "90|Pushing scaffold to Forgejo"
  command -v git &>/dev/null || apt-get install -y -qq git &>/dev/null

  local PUSH_WORK
  PUSH_WORK=$(mktemp -d)
  git clone \
    "http://${FORGEJO_ADMIN}:${FORGEJO_PASS}@${FORGEJO_IP}:${FORGEJO_PORT}/${FORGEJO_ADMIN}/proxmox-iac.git" \
    "$PUSH_WORK" --quiet 2>/dev/null || true

  cp -r "$WORK/." "$PUSH_WORK/"
  cd "$PUSH_WORK"
  git config user.email "${FORGEJO_EMAIL:-admin@lan}"
  git config user.name  "$FORGEJO_ADMIN"
  git add -A
  git commit -m "feat: initial IaC scaffold" --quiet 2>/dev/null || true
  git push origin main --quiet 2>/dev/null \
    || echo "PUSH_FAILED" > /tmp/iac-push-status.txt
  cd /root
  rm -rf "$PUSH_WORK"

  echo "100|Done"
  sleep 1
}

run_with_gauge "Scaffold Repository" \
  "Building proxmox-iac repo and pushing to Forgejo..." \
  do_scaffold

# Check push status
if [[ -f /tmp/iac-push-status.txt ]]; then
  rm -f /tmp/iac-push-status.txt
  msg_warn "Could not push to Forgejo automatically"
  msg_warn "Clone and push manually:"
  msg_warn "  git clone http://${FORGEJO_IP}:${FORGEJO_PORT}/${FORGEJO_ADMIN}/proxmox-iac.git"
else
  msg_ok "Scaffold pushed → http://${FORGEJO_IP}:${FORGEJO_PORT}/${FORGEJO_ADMIN}/proxmox-iac"
fi

msg_ok "tofu-state backend ready → http://${FORGEJO_IP}:${FORGEJO_PORT}/${FORGEJO_ADMIN}/tofu-state"
