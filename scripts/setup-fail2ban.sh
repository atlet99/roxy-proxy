#!/usr/bin/env bash
set -euo pipefail

if ! command -v fail2ban-client >/dev/null 2>&1; then
  echo "fail2ban is not installed. Run: make setup-deps"
  exit 1
fi

FILTER_PATH=/etc/fail2ban/filter.d/nginx-http-probe.conf
JAIL_PATH=/etc/fail2ban/jail.d/roxy-proxy.local

sudo tee "$FILTER_PATH" >/dev/null <<'FILTER'
[Definition]
failregex = ^<HOST> - - \[.*\] ".*" (400|401|403|404|405|429|444|500|502|503|504) .*$
ignoreregex =
FILTER

sudo tee "$JAIL_PATH" >/dev/null <<'JAIL'
[sshd]
enabled = true
port = ssh
maxretry = 5
findtime = 10m
bantime = 1h

[nginx-http-probe]
enabled = true
filter = nginx-http-probe
port = http,https
logpath = /var/log/nginx/http-access.log
maxretry = 30
findtime = 10m
bantime = 1h
JAIL

sudo systemctl enable fail2ban
sudo systemctl restart fail2ban

echo "Installed: $FILTER_PATH"
echo "Installed: $JAIL_PATH"
sudo fail2ban-client status
