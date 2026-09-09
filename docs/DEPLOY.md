# Deployment Guide

## Prerequisites

- A running Sharkey/Misskey instance
- `bash`, `curl`, `jq` on the host
- One of:
  - Prometheus with node_exporter (textfile collector enabled)
  - Grafana Alloy with `prometheus.exporter.unix` textfile support

## Install

```bash
# Clone the repo
git clone https://github.com/SiteRelEnby/sharkey-prometheus-exporter.git
cd sharkey-prometheus-exporter

# Copy exporter to a system location
cp sharkey-exporter.sh /usr/local/bin/
chmod +x /usr/local/bin/sharkey-exporter.sh

# Create output directory
mkdir -p /var/lib/prometheus-textfile
```

## Configure cron

### Basic metrics (no auth)

```bash
# Add to crontab
(crontab -l 2>/dev/null; echo '* * * * * /usr/local/bin/sharkey-exporter.sh --output /var/lib/prometheus-textfile/sharkey.prom') | crontab -
```

### With admin metrics

```bash
# First, see exactly which permissions to enable:
sharkey-exporter.sh --create-token

# Then create the token in your Sharkey web UI (Settings > API > Generate Access Token)
# and save it to a file:
mkdir -p /etc/sharkey-exporter
echo 'YOUR_TOKEN_HERE' > /etc/sharkey-exporter/token
chmod 600 /etc/sharkey-exporter/token

(crontab -l 2>/dev/null; echo '* * * * * /usr/local/bin/sharkey-exporter.sh --token-file /etc/sharkey-exporter/token --output /var/lib/prometheus-textfile/sharkey.prom') | crontab -
```

Note: Sharkey's token creation API is restricted to browser sessions, so token
creation can't be automated from the CLI. The `--create-token` flag prints which
permissions to tick — only 4 read-only scopes are needed.

### Custom instance URL

If the exporter runs on a different host, or Sharkey listens on a non-default port:

```bash
sharkey-exporter.sh --instance https://your.instance.tld --output /var/lib/prometheus-textfile/sharkey.prom
```

## Docker

If you'd rather not install anything on the host, the container image polls the
instance itself and serves `/metrics` over HTTP on port 10054. No cron and no
textfile collector needed; point Prometheus or Alloy at it as a normal scrape target.

```bash
mkdir -p /etc/sharkey-exporter
echo 'YOUR_TOKEN_HERE' > /etc/sharkey-exporter/token
chmod 600 /etc/sharkey-exporter/token

docker run -d --name sharkey-exporter --restart unless-stopped \
  -e SHARKEYEX_INSTANCE=https://your.instance.tld \
  -e SHARKEYEX_TOKEN_FILE=/run/secrets/sharkey_token \
  -v /etc/sharkey-exporter/token:/run/secrets/sharkey_token:ro \
  -p 127.0.0.1:10054:10054 \
  ghcr.io/siterelenby/sharkey-prometheus-exporter:latest
```

Or with compose:

```yaml
services:
  sharkey-exporter:
    image: ghcr.io/siterelenby/sharkey-prometheus-exporter:latest
    restart: unless-stopped
    environment:
      SHARKEYEX_INSTANCE: https://your.instance.tld
      SHARKEYEX_TOKEN_FILE: /run/secrets/sharkey_token
      SHARKEYEX_POLLING_INTERVAL: "60"
    secrets:
      - sharkey_token
    ports:
      - "127.0.0.1:10054:10054"
    # Opt-in metrics go here, they're passed through to the exporter:
    # command: ["--charts-notes", "--charts-users"]

secrets:
  sharkey_token:
    file: /etc/sharkey-exporter/token
```

Environment variables: `SHARKEYEX_INSTANCE`, `SHARKEYEX_TOKEN`, `SHARKEYEX_TOKEN_FILE`,
`SHARKEYEX_DOMAIN`, `SHARKEYEX_POLLING_INTERVAL`. Prefer `SHARKEYEX_TOKEN_FILE` with a
mounted secret over `SHARKEYEX_TOKEN`, since environment variables show up in
`docker inspect`.

The default `SHARKEYEX_INSTANCE` of `http://127.0.0.1:3000` only reaches Sharkey when
the container runs with `--network=host`. Otherwise set it to the public URL, or to the
Sharkey service name if both are on the same compose network.

Pin to a release tag (`vX.Y.Z`) rather than `latest` if you want control over upgrades.

## Grafana Alloy setup

Add to your Alloy config:

```alloy
// Sharkey metrics via textfile collector
prometheus.exporter.unix "sharkey_textfile" {
  textfile {
    directory = "/var/lib/prometheus-textfile"
  }
  disable_collectors = ["arp","bcache","bonding","btrfs","conntrack","cpu","cpufreq",
    "diskstats","dmi","edac","entropy","fibrechannel","filefd","filesystem","hwmon",
    "infiniband","ipvs","loadavg","mdadm","meminfo","netclass","netdev","netstat",
    "nfs","nfsd","nvme","os","powersupplyclass","pressure","rapl","schedstat",
    "selinux","sockstat","softnet","stat","tapestats","thermal_zone","time",
    "timex","udp_queues","uname","vmstat","watchdog","xfs","zfs"]
}

prometheus.scrape "sharkey_metrics" {
  targets         = prometheus.exporter.unix.sharkey_textfile.targets
  forward_to      = [prometheus.relabel.sharkey_labels.receiver]
  scrape_interval = "60s"
}

prometheus.relabel "sharkey_labels" {
  forward_to = [prometheus.remote_write.your_endpoint.receiver]

  rule {
    target_label = "job"
    replacement  = "sharkey"
  }

  rule {
    target_label = "instance"
    replacement  = "your.instance.tld"
  }
}
```

## Prometheus node_exporter setup

Enable the textfile collector:

```bash
node_exporter --collector.textfile.directory=/var/lib/prometheus-textfile
```

## Verify

```bash
# Run manually
sharkey-exporter.sh --output /tmp/test.prom
cat /tmp/test.prom

# Check for valid Prometheus format
promtool check metrics < /tmp/test.prom
```
