#!/bin/bash
set -Eeuo pipefail

SCRIPT_DIR="$(git rev-parse --show-toplevel)"
cd "$SCRIPT_DIR"

echo "==> Installing Ansible collections and roles..."
ansible-galaxy collection install -r requirements.yml
ansible-galaxy role install -r requirements.yml

# If 1Password CLI is available and signed in, use it for vault password
# Otherwise fall back to manual prompt
if op account list &>/dev/null; then
  echo "==> Using 1Password for vault password"
  ansible-playbook \
    --vault-password-file <(op read "op://Ansible/workstations/password") \
    --ask-become-pass \
    "$@" \
    local.yml
else
  echo "==> 1Password CLI not available, will prompt for vault password"
  ansible-playbook \
    --ask-vault-pass \
    --ask-become-pass \
    "$@" \
    local.yml
fi
