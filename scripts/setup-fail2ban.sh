#!/usr/bin/env bash
set -euo pipefail

if ! command -v fail2ban-client >/dev/null 2>&1; then
  echo "fail2ban is not installed. Run: make setup-deps"
  exit 1
fi

JAIL_PATH=/etc/fail2ban/jail.d/roxy-proxy.local

sudo tee "$JAIL_PATH" >/dev/null <<'JAIL'
[sshd]
enabled = true
port = ssh
maxretry = 5
findtime = 10m
bantime = 1h
JAIL

sudo systemctl enable fail2ban
sudo systemctl restart fail2ban

echo "Installed: $JAIL_PATH"
echo "Nginx jail is intentionally disabled in tunnel-only mode."
sudo fail2ban-client status
