#!/bin/sh
set -e

mkdir -p /srv

# Any container args are passed straight to the exporter, so opt-in flags
# work as e.g. `docker run ... ghcr.io/.../sharkey-prometheus-exporter --charts-notes`

# Run once immediately so /metrics is populated before Caddy starts
/usr/local/bin/sharkey-exporter.sh "$@" || true

# Polling loop in background
(
    while true; do
        sleep "${SHARKEYEX_POLLING_INTERVAL:-60}"
        /usr/local/bin/sharkey-exporter.sh "$@" || true
    done
) &

exec caddy run --config /etc/caddy/Caddyfile --adapter caddyfile
