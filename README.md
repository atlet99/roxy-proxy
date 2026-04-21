# Roxy Proxy

Dockerized forward proxy stack with Cloudflare Tunnel, `squid`, `nginx` TLS hop, and `sops`-managed certificates.

## Architecture

```text
Browser (SwitchyOmega)
  -> proxy.example.com:443
  -> Cloudflare edge (orange cloud)
  -> cloudflared (outbound tunnel only)
  -> nginx:8443 (TLS with CF-valid origin cert)
  -> squid:3128 (auth + hostname whitelist)
  -> target hosts
```

No inbound ports are required for proxy itself. Server keeps only standard perimeter ports for SSH/HTTP/HTTPS according to firewall policy.

## Prerequisites

- Docker + Docker Compose
- `make`
- `sops` + `age`
- Cloudflare tunnel created
- DNS record in Cloudflare (`proxy` -> `<tunnel-id>.cfargotunnel.com`, proxied)

## Real Config: how to fill `.env`

1. Initialize files:

```bash
make init
```

2. Create tunnel and DNS route (one-time):

```bash
cloudflared tunnel login
cloudflared tunnel create my-proxy
cloudflared tunnel route dns my-proxy proxy.example.com
```

3. Copy tunnel credentials JSON into `cloudflared/`.

4. Open `.env` and set real values:

```dotenv
TUNNEL_HOSTNAME=proxy.example.com
TUNNEL_ID=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
TUNNEL_CREDENTIALS_FILE=./cloudflared/xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx.json
PROXY_USER=youruser
PROXY_PASSWORD=YourStrongPassword
ALLOWED_HOSTS=target-site.com,*.target-site.com
SOPS_KEY_FILE=$HOME/.sops/key.txt
```

Notes:
- `TUNNEL_ID` must match both tunnel UUID and credentials filename.
- `ALLOWED_HOSTS` is a comma-separated whitelist used by Squid `dstdomain` ACL.
- `*.example.com` in `.env` is converted to Squid format `.example.com` automatically.
- Keep `PROXY_PASSWORD` strong and unique.

## Certificates + SOPS

Decrypt runtime certs:

```bash
make sops-dec
```

Encrypt certs back:

```bash
make sops-enc
```

Generate AGE key if needed:

```bash
make sops-init
```

## Start / Stop

```bash
make up
make ps
make logs
```

Stop:

```bash
make down
```

## Security Hardening

Install dependencies:

```bash
make setup-deps
```

Apply firewall rules:

```bash
make setup-ufw
```

Configure fail2ban:

```bash
make setup-fail2ban
```

Install logrotate policy for nginx logs:

```bash
make setup-logrotate
make logrotate-check
```

## SwitchyOmega

Proxy profile:

- Protocol: `HTTPS`
- Server: `TUNNEL_HOSTNAME`
- Port: `443`
- Username: `PROXY_USER`
- Password: `PROXY_PASSWORD`

Switch profile:

- `*.target-site.com` -> Proxy profile
- `target-site.com` -> Proxy profile
- Default -> Direct

## Make targets

```bash
make help
```

Main flow:

1. `make bootstrap`
2. If something fails, fix and rerun only the failed stage (for example `make stage-hardening`)
