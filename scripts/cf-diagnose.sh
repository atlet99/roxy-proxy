#!/usr/bin/env bash
set -euo pipefail

PASS=0
WARN=0
FAIL=0

say_pass() { echo "[PASS] $*"; PASS=$((PASS+1)); }
say_warn() { echo "[WARN] $*"; WARN=$((WARN+1)); }
say_fail() { echo "[FAIL] $*"; FAIL=$((FAIL+1)); }

require_var() {
  local key="$1"
  local val="${!key:-}"
  if [ -z "$val" ]; then
    say_fail "Missing required variable: $key"
    return 1
  fi
  say_pass "$key is set"
  return 0
}

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

echo "== Cloudflare Tunnel Diagnostics =="

require_var CLOUDFLARE_API_TOKEN || true
require_var CLOUDFLARE_ACCOUNT_ID || true
require_var CLOUDFLARE_ZONE_ID || true
require_var TUNNEL_HOSTNAME || true
require_var TUNNEL_ID || true
require_var TUNNEL_TOKEN || true

EXPECTED_ORIGIN_SERVICE="${ORIGIN_SERVICE:-https://nginx:8443}"

if [ "$FAIL" -gt 0 ]; then
  echo
  echo "Summary: PASS=$PASS WARN=$WARN FAIL=$FAIL"
  exit 1
fi

echo

echo "-- Checking tunnel by ID --"
tunnel_info=$(api GET "/accounts/${CLOUDFLARE_ACCOUNT_ID}/cfd_tunnel/${TUNNEL_ID}") || {
  say_fail "Tunnel lookup API call failed"
  echo "Summary: PASS=$PASS WARN=$WARN FAIL=$FAIL"
  exit 1
}

success=$(echo "$tunnel_info" | jq -r '.success // false')
if [ "$success" != "true" ]; then
  say_fail "Tunnel lookup returned API error"
  echo "$tunnel_info" | jq -r '.errors // .'
else
  say_pass "Tunnel ${TUNNEL_ID} exists"
  tname=$(echo "$tunnel_info" | jq -r '.result.name // empty')
  tstatus=$(echo "$tunnel_info" | jq -r '.result.status // empty')
  [ -n "$tname" ] && say_pass "Tunnel name: $tname"
  if [ "$tstatus" = "healthy" ] || [ "$tstatus" = "active" ]; then
    say_pass "Tunnel status: $tstatus"
  elif [ -n "$tstatus" ]; then
    say_warn "Tunnel status: $tstatus"
  else
    say_warn "Tunnel status not provided by API response"
  fi
fi

echo

echo "-- Checking tunnel ingress config --"
config_info=$(api GET "/accounts/${CLOUDFLARE_ACCOUNT_ID}/cfd_tunnel/${TUNNEL_ID}/configurations") || {
  say_fail "Tunnel config API call failed"
  echo "Summary: PASS=$PASS WARN=$WARN FAIL=$FAIL"
  exit 1
}

success=$(echo "$config_info" | jq -r '.success // false')
if [ "$success" != "true" ]; then
  say_fail "Tunnel config returned API error"
  echo "$config_info" | jq -r '.errors // .'
else
  ingress_host=$(echo "$config_info" | jq -r '.result.config.ingress[0].hostname // empty')
  ingress_service=$(echo "$config_info" | jq -r '.result.config.ingress[0].service // empty')
  ingress_sni=$(echo "$config_info" | jq -r '.result.config.ingress[0].originRequest.originServerName // empty')
  ingress_no_tls_verify=$(echo "$config_info" | jq -r '.result.config.ingress[0].originRequest.noTLSVerify // empty')
  if [ "$ingress_host" = "$TUNNEL_HOSTNAME" ]; then
    say_pass "Ingress hostname matches TUNNEL_HOSTNAME"
  else
    say_fail "Ingress hostname mismatch: expected '$TUNNEL_HOSTNAME', got '$ingress_host'"
  fi
  if [ "$ingress_service" = "$EXPECTED_ORIGIN_SERVICE" ]; then
    say_pass "Ingress service matches expected: $EXPECTED_ORIGIN_SERVICE"
  elif [ -n "$ingress_service" ]; then
    say_warn "Ingress service is '$ingress_service' (expected '$EXPECTED_ORIGIN_SERVICE')"
  else
    say_fail "Ingress service is empty"
  fi
  if [ "$ingress_sni" = "$TUNNEL_HOSTNAME" ]; then
    say_pass "originServerName matches TUNNEL_HOSTNAME"
  elif [ -n "$ingress_sni" ]; then
    say_warn "originServerName is '$ingress_sni' (expected '$TUNNEL_HOSTNAME')"
  else
    say_warn "originServerName is empty"
  fi
  if [ "$ingress_no_tls_verify" = "true" ]; then
    say_warn "noTLSVerify=true (acceptable for internal Docker origin; less strict TLS validation)"
  elif [ "$ingress_no_tls_verify" = "false" ]; then
    say_pass "noTLSVerify=false (strict TLS validation to origin)"
  else
    say_warn "noTLSVerify is not explicitly set"
  fi
fi

echo

echo "-- Checking DNS CNAME record --"
dns_info=$(api GET "/zones/${CLOUDFLARE_ZONE_ID}/dns_records?type=CNAME&name=${TUNNEL_HOSTNAME}") || {
  say_fail "DNS API call failed"
  echo "Summary: PASS=$PASS WARN=$WARN FAIL=$FAIL"
  exit 1
}

success=$(echo "$dns_info" | jq -r '.success // false')
if [ "$success" != "true" ]; then
  say_fail "DNS lookup returned API error"
  echo "$dns_info" | jq -r '.errors // .'
else
  record_count=$(echo "$dns_info" | jq -r '.result | length')
  if [ "$record_count" -lt 1 ]; then
    say_fail "No CNAME record found for $TUNNEL_HOSTNAME"
  else
    content=$(echo "$dns_info" | jq -r '.result[0].content // empty')
    proxied=$(echo "$dns_info" | jq -r '.result[0].proxied // false')
    expected="${TUNNEL_ID}.cfargotunnel.com"
    if [ "$content" = "$expected" ]; then
      say_pass "CNAME target matches tunnel id"
    else
      say_fail "CNAME target mismatch: expected '$expected', got '$content'"
    fi
    if [ "$proxied" = "true" ]; then
      say_pass "DNS record is proxied"
    else
      say_fail "DNS record is not proxied"
    fi
  fi
fi

echo

echo "-- Checking local runtime --"
if command -v docker >/dev/null 2>&1; then
  if docker compose ps --status running cloudflared >/dev/null 2>&1; then
    running_count=$(docker compose ps --status running cloudflared | awk 'NR>1 {count++} END {print count+0}')
    if [ "$running_count" -gt 0 ]; then
      say_pass "cloudflared container is running"
    else
      say_warn "cloudflared container is not running"
    fi
  else
    say_warn "docker compose state unavailable (stack may be down)"
  fi
else
  say_warn "docker is not installed in current environment"
fi

echo

echo "Summary: PASS=$PASS WARN=$WARN FAIL=$FAIL"
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
