# Roxy Proxy

[![ko-fi](https://ko-fi.com/img/githubbutton_sm.svg)](https://ko-fi.com/I2I81X6E3R)

Dockerized forward proxy stack with Cloudflare Tunnel (remote-managed API mode), `squid` v7-style ACLs, `nginx` TLS hop, and `sops`-managed secrets.

## Architecture

```text
Browser (SwitchyOmega)
  -> proxy.example.com:443
  -> Cloudflare edge (proxied DNS)
  -> cloudflared (token-based remote tunnel)
  -> nginx:8443 (TLS with CF-valid origin cert)
  -> squid:3128 (basic auth + dstdomain allowlist)
  -> target hosts
```

## Why this Squid config

Current config follows Squid v7 baseline directives:
- `auth_param basic ...` for proxy auth.
- `acl allowed_domains dstdomain ...` for allowlist.
- `http_access deny !Safe_ports` and `http_access deny CONNECT !SSL_ports`.
- protection ACLs: `manager`, `to_localhost`, `to_linklocal`.
- explicit `http_access deny all` as final rule.

## Prerequisites

- Docker + Docker Compose
- `make`, `jq`, `curl`
- `sops`, `age`
- Cloudflare account with zone in proxied mode

## Quick Start (one-shot)

1. Initialize:

```bash
make init
```

2. Fill `.env`:

```dotenv
TUNNEL_HOSTNAME=proxy.example.com
TUNNEL_NAME=roxy-proxy
CLOUDFLARE_ACCOUNT_ID=...
CLOUDFLARE_ZONE_ID=...
ORIGIN_SERVICE=https://nginx:8443
ORIGIN_SERVER_NAME=proxy.example.com
PROXY_USER=youruser
PROXY_PASSWORD=YourStrongPassword
ALLOWED_HOSTS=target-site.com,*.target-site.com
```

3. Cloudflare API token (encrypted with sops):

```bash
make sops-dec-cf-api
# edit secrets/cloudflare.api.env if needed
make sops-enc-cf-api
make sops-clean-cf-api
```

4. Full bootstrap:

```bash
make bootstrap
```

## Resumable stages

If something fails, fix and rerun only that stage:

1. `make stage-prepare`
2. `make stage-cloudflare`
3. `make stage-secrets`
4. `make stage-start`
5. `make stage-hardening`
6. `make stage-verify`

## Diagnostics

Run full Cloudflare diagnostics with encrypted API token:

```bash
make diagnose-cf-sops
```

Or with already decrypted secret file:

```bash
make diagnose-cf
```

## Cloudflare API behavior

`make stage-cloudflare` does:
- creates tunnel by name if missing,
- applies remote ingress config,
- upserts proxied CNAME to `<tunnel-id>.cfargotunnel.com`,
- fetches tunnel run token,
- writes `TUNNEL_ID` and `TUNNEL_TOKEN` into `.env`,
- decrypts API secret only for the step and then removes plaintext file.

## Secrets via SOPS

- Encrypted certs: `certs/enc.crt.pem`, `certs/enc.crt.key`
- Encrypted Cloudflare API env: `secrets/enc.cloudflare.api.env`
- Decrypted runtime files are ignored by git.

## Start/Stop and logs

```bash
make up
make ps
make logs
make down
```

## SwitchyOmega

Proxy profile:
- Protocol: `HTTPS`
- Server: `TUNNEL_HOSTNAME`
- Port: `443`
- Username: `PROXY_USER`
- Password: `PROXY_PASSWORD`

Switch profile:
- `*.target-site.com` -> Proxy
- `target-site.com` -> Proxy
- Default -> Direct
