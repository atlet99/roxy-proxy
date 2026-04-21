#!/usr/bin/env bash
set -euo pipefail

: "${PROXY_USER:?PROXY_USER is required}"
: "${PROXY_PASSWORD:?PROXY_PASSWORD is required}"
: "${ALLOWED_HOSTS:?ALLOWED_HOSTS is required}"

CFG=/etc/3proxy/3proxy.cfg
mkdir -p /etc/3proxy

echo "log /dev/stdout D" > "$CFG"
echo 'logformat "- +_L%t.%. %N.%p %E %U %C:%c %R:%r %O %I %h %T"' >> "$CFG"
echo "nserver 1.1.1.1" >> "$CFG"
echo "nserver 1.0.0.1" >> "$CFG"
echo "nscache 65536" >> "$CFG"
echo "timeouts 1 5 30 60 180 1800 15 60" >> "$CFG"
echo "auth strong" >> "$CFG"
echo "users ${PROXY_USER}:CL:${PROXY_PASSWORD}" >> "$CFG"

awk -v user="$PROXY_USER" -v hosts="$ALLOWED_HOSTS" 'BEGIN {
  n=split(hosts, a, ",");
  for (i=1; i<=n; i++) {
    gsub(/^[ \t]+|[ \t]+$/, "", a[i]);
    if (length(a[i]) > 0) {
      printf("allow %s * %s\n", user, a[i]);
    }
  }
}' >> "$CFG"

echo "deny *" >> "$CFG"
echo "proxy -p3128 -i0.0.0.0" >> "$CFG"

exec 3proxy "$CFG"
