FROM caddy:alpine

RUN apk add --no-cache bash curl jq

COPY sharkey-exporter.sh /usr/local/bin/sharkey-exporter.sh
COPY Caddyfile /etc/caddy/Caddyfile
COPY entrypoint.sh /entrypoint.sh

RUN chmod +x /usr/local/bin/sharkey-exporter.sh /entrypoint.sh

ENV SHARKEYEX_INSTANCE=http://127.0.0.1:3000
ENV SHARKEYEX_OUTPUT=/srv/sharkey.prom
ENV SHARKEYEX_POLLING_INTERVAL=60

EXPOSE 3000

ENTRYPOINT ["/entrypoint.sh"]
