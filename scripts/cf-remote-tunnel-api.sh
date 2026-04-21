#!/usr/bin/env bash
set -euo pipefail

: "${CLOUDFLARE_API_TOKEN:?CLOUDFLARE_API_TOKEN is required}"
: "${CLOUDFLARE_ACCOUNT_ID:?CLOUDFLARE_ACCOUNT_ID is required}"
: "${CLOUDFLARE_ZONE_ID:?CLOUDFLARE_ZONE_ID is required}"
: "${TUNNEL_HOSTNAME:?TUNNEL_HOSTNAME is required}"

TUNNEL_NAME="${TUNNEL_NAME:-roxy-proxy}"
ORIGIN_SERVICE="${ORIGIN_SERVICE:-https://nginx:8443}"
ORIGIN_SERVER_NAME="${ORIGIN_SERVER_NAME:-${TUNNEL_HOSTNAME}}"

api() {
  local method="$1"
  local endpoint="$2"
  local data="${3:-}"
  local url="https://api.cloudflare.com/client/v4${endpoint}"

  if [ -n "$data" ]; then
    curl -sS "$url" \
      --request "$method" \
      --header "Authorization: Bearer ${CLOUDFLARE_API_TOKEN}" \
      --header 'Content-Type: application/json' \
      --data "$data"
  else
    curl -sS "$url" \
      --request "$method" \
      --header "Authorization: Bearer ${CLOUDFLARE_API_TOKEN}" \
      --header 'Content-Type: application/json'
  fi
}

assert_success() {
  local payload="$1"
  local ctx="$2"
  local ok
  ok=$(echo "$payload" | jq -r '.success // false')
  if [ "$ok" != "true" ]; then
    echo "Cloudflare API error during: $ctx"
    echo "$payload" | jq -r '.errors // .'
    exit 1
  fi
}

echo "[1/4] Ensuring tunnel exists: ${TUNNEL_NAME}"
existing=$(api GET "/accounts/${CLOUDFLARE_ACCOUNT_ID}/cfd_tunnel?is_deleted=false")
assert_success "$existing" "list tunnels"

TUNNEL_ID=$(echo "$existing" | jq -r --arg n "$TUNNEL_NAME" '.result[]? | select(.name==$n) | .id' | head -1)

if [ -z "${TUNNEL_ID}" ] || [ "${TUNNEL_ID}" = "null" ]; then
  create_payload=$(jq -n --arg name "$TUNNEL_NAME" '{name:$name, config_src:"cloudflare"}')
  created=$(api POST "/accounts/${CLOUDFLARE_ACCOUNT_ID}/cfd_tunnel" "$create_payload")
  assert_success "$created" "create tunnel"
  TUNNEL_ID=$(echo "$created" | jq -r '.result.id')
  echo "Created tunnel: ${TUNNEL_ID}"
else
  echo "Tunnel already exists: ${TUNNEL_ID}"
fi

echo "[2/4] Applying remote tunnel ingress configuration"
config_payload=$(jq -n \
  --arg host "$TUNNEL_HOSTNAME" \
  --arg service "$ORIGIN_SERVICE" \
  --arg sni "$ORIGIN_SERVER_NAME" \
  '{config:{ingress:[{hostname:$host,service:$service,originRequest:{originServerName:$sni,noTLSVerify:false}},{service:"http_status:404"}]}}')

configured=$(api PUT "/accounts/${CLOUDFLARE_ACCOUNT_ID}/cfd_tunnel/${TUNNEL_ID}/configurations" "$config_payload")
assert_success "$configured" "put tunnel configuration"

echo "[3/4] Ensuring proxied DNS CNAME record"
record_name="$TUNNEL_HOSTNAME"
record_target="${TUNNEL_ID}.cfargotunnel.com"

list_dns=$(api GET "/zones/${CLOUDFLARE_ZONE_ID}/dns_records?type=CNAME&name=${record_name}")
assert_success "$list_dns" "list dns records"

record_id=$(echo "$list_dns" | jq -r '.result[0].id // empty')
record_payload=$(jq -n --arg name "$record_name" --arg content "$record_target" '{type:"CNAME",name:$name,content:$content,proxied:true,ttl:1}')

if [ -n "$record_id" ]; then
  updated=$(api PUT "/zones/${CLOUDFLARE_ZONE_ID}/dns_records/${record_id}" "$record_payload")
  assert_success "$updated" "update dns record"
  echo "Updated CNAME: ${record_name} -> ${record_target}"
else
  created_dns=$(api POST "/zones/${CLOUDFLARE_ZONE_ID}/dns_records" "$record_payload")
  assert_success "$created_dns" "create dns record"
  echo "Created CNAME: ${record_name} -> ${record_target}"
fi

echo "[4/4] Fetching tunnel run token"
token_resp=$(api GET "/accounts/${CLOUDFLARE_ACCOUNT_ID}/cfd_tunnel/${TUNNEL_ID}/token")
assert_success "$token_resp" "get tunnel token"
TUNNEL_TOKEN=$(echo "$token_resp" | jq -r '.result')

if [ -z "${TUNNEL_TOKEN}" ] || [ "${TUNNEL_TOKEN}" = "null" ]; then
  echo "Failed to get TUNNEL_TOKEN"
  exit 1
fi

if [ ! -f .env ]; then
  cp .env.example .env
fi

set_env() {
  local key="$1"
  local value="$2"
  if grep -qE "^${key}=" .env; then
    sed -i.bak "s|^${key}=.*|${key}=${value}|" .env
  else
    printf "%s=%s\n" "$key" "$value" >> .env
  fi
}

set_env "TUNNEL_ID" "$TUNNEL_ID"
set_env "TUNNEL_TOKEN" "$TUNNEL_TOKEN"
rm -f .env.bak

echo "Updated .env with TUNNEL_ID and TUNNEL_TOKEN"
