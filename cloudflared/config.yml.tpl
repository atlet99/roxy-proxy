tunnel: __TUNNEL_ID__
credentials-file: /etc/cloudflared/credentials.json

ingress:
  - hostname: __TUNNEL_HOSTNAME__
    service: https://nginx:8443
    originRequest:
      originServerName: __TUNNEL_HOSTNAME__
      noTLSVerify: false
  - service: http_status:404
