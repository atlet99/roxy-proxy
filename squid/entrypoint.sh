#!/usr/bin/env bash
set -euo pipefail

: "${PROXY_USER:?PROXY_USER is required}"
: "${PROXY_PASSWORD:?PROXY_PASSWORD is required}"
: "${ALLOWED_HOSTS:?ALLOWED_HOSTS is required}"

mkdir -p /etc/squid /var/log/squid /var/cache/squid

htpasswd -bc /etc/squid/passwd "$PROXY_USER" "$PROXY_PASSWORD" >/dev/null 2>&1

ALLOWED_FILE=/etc/squid/allowed_domains.txt
: > "$ALLOWED_FILE"

IFS=',' read -r -a HOSTS <<< "$ALLOWED_HOSTS"
for host in "${HOSTS[@]}"; do
  host="$(echo "$host" | xargs)"
  [ -z "$host" ] && continue

  if [[ "$host" == \*.* ]]; then
    # Squid wildcard format: .example.com
    echo ".${host#*.}" >> "$ALLOWED_FILE"
  else
    echo "$host" >> "$ALLOWED_FILE"
  fi
done

cat > /etc/squid/squid.conf <<'CONF'
auth_param basic program /usr/lib/squid/basic_ncsa_auth /etc/squid/passwd
auth_param basic realm Proxy
auth_param basic credentialsttl 2 hours
acl authenticated proxy_auth REQUIRED

acl allowed_domains dstdomain "/etc/squid/allowed_domains.txt"
acl manager proto cache_object

acl SSL_ports port 443
acl Safe_ports port 80
acl Safe_ports port 443
acl CONNECT method CONNECT

http_access deny !Safe_ports
http_access deny CONNECT !SSL_ports
http_access allow localhost manager
http_access deny manager
http_access deny to_localhost
http_access deny to_linklocal
http_access allow authenticated allowed_domains
http_access deny all

http_port 3128

cache deny all
cache_mem 32 MB
maximum_object_size 4 MB

via off
forwarded_for delete

access_log stdio:/dev/stdout
cache_log stdio:/dev/stderr
pid_filename /tmp/squid.pid
coredump_dir /tmp
CONF

exec squid -N -f /etc/squid/squid.conf
