#!/usr/bin/env bash
set -euo pipefail

if ! command -v apt >/dev/null 2>&1; then
  echo "This script supports Debian/Ubuntu only (apt is required)."
  exit 1
fi

sudo apt update
sudo apt install -y ufw fail2ban logrotate jq ca-certificates

echo "Dependencies installed: ufw fail2ban logrotate jq ca-certificates"
