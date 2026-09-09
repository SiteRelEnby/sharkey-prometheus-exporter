FROM caddy:2.11.4-alpine

RUN apk add --no-cache bash curl jq \
    && adduser -D -H -u 10001 exporter \
    && mkdir -p /srv \
    && chown exporter /srv /config /data

COPY sharkey-exporter.sh /usr/local/bin/sharkey-exporter.sh
COPY Caddyfile /etc/caddy/Caddyfile
COPY entrypoint.sh /entrypoint.sh

RUN chmod +x /usr/local/bin/sharkey-exporter.sh /entrypoint.sh

# Point at your instance; the default only works with --network=host.
ENV SHARKEYEX_INSTANCE=http://127.0.0.1:3000
ENV SHARKEYEX_OUTPUT=/srv/sharkey.prom
ENV SHARKEYEX_POLLING_INTERVAL=60

USER exporter
EXPOSE 10054

HEALTHCHECK --interval=60s --timeout=5s --start-period=30s \
    CMD wget -qO- http://127.0.0.1:10054/metrics >/dev/null || exit 1

ENTRYPOINT ["/entrypoint.sh"]
