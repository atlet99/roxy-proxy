#!/usr/bin/env bash
set -euo pipefail

if ! command -v ufw >/dev/null 2>&1; then
  echo "ufw is not installed. Run: make setup-deps"
  exit 1
fi

SSH_PORT=$(ss -tlnp 2>/dev/null | awk '/sshd/ {print $4}' | awk -F: '{print $NF}' | head -1)
if [ -z "${SSH_PORT:-}" ] && [ -f /etc/ssh/sshd_config ]; then
  SSH_PORT=$(awk '/^Port / {print $2}' /etc/ssh/sshd_config | head -1)
fi
SSH_PORT=${SSH_PORT:-22}

DEFAULT_IFACE=$(ip route show default | awk '/default/ {print $5}' | head -1)
ALLOW_WEB_PORTS="${UFW_ALLOW_WEB_PORTS:-0}"

echo "Detected SSH port:      ${SSH_PORT}"
echo "Detected interface:     ${DEFAULT_IFACE:-unknown}"
echo
echo "Rules to apply:"
echo "- default deny incoming"
echo "- default allow outgoing"
echo "- allow SSH ${SSH_PORT}/tcp (limited)"
if [ "$ALLOW_WEB_PORTS" = "1" ]; then
  echo "- allow 80/tcp and 443/tcp"
else
  echo "- do not open 80/443 (tunnel-only mode)"
fi

echo
if [ "${UFW_AUTO_CONFIRM:-0}" = "1" ]; then
  echo "UFW_AUTO_CONFIRM=1, applying rules without interactive prompt."
else
  read -r -p "Apply UFW rules now? [y/N] " confirm
  if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
    echo "Aborted"
    exit 0
  fi
fi

sudo ufw --force reset
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw default deny routed

sudo ufw limit "${SSH_PORT}"/tcp
if [ "$ALLOW_WEB_PORTS" = "1" ]; then
  sudo ufw allow 80/tcp
  sudo ufw allow 443/tcp
fi

sudo ufw --force enable

sudo ufw status verbose
