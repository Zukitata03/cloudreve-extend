# Custom Caddy image with the Alibaba Cloud DNS (alidns) plugin.
# Required for DNS-01 certificate challenges when the server is not
# publicly reachable on port 80 (e.g. behind a private/LAN IP or Tailscale).
FROM caddy:2-builder AS builder

RUN xcaddy build \
    --with github.com/caddy-dns/alidns

FROM caddy:2

COPY --from=builder /usr/bin/caddy /usr/bin/caddy
