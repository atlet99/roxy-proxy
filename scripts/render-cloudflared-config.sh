#!/usr/bin/env bash
set -euo pipefail

: "${TUNNEL_ID:?TUNNEL_ID is required}"
: "${TUNNEL_HOSTNAME:?TUNNEL_HOSTNAME is required}"

sed \
  -e "s|__TUNNEL_ID__|${TUNNEL_ID}|g" \
  -e "s|__TUNNEL_HOSTNAME__|${TUNNEL_HOSTNAME}|g" \
  cloudflared/config.yml.tpl > cloudflared/config.yml

echo "Rendered cloudflared/config.yml"
