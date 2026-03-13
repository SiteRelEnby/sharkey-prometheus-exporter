# sharkey-prometheus-exporter

A lightweight Prometheus metrics exporter for [Sharkey](https://joinsharkey.org/) (Misskey fork) instances.

Polls the Sharkey API and exposes metrics in Prometheus textfile format. Designed for small-to-medium instances — no heavy dependencies, just bash + curl + jq + cron.

By default, exports a useful set of metrics that covers most monitoring needs. Optional flags enable additional metrics for larger instances with more monitoring infrastructure.

All metrics include a `domain` label (auto-detected from the instance, or set via `--domain`) for multi-instance dashboards.

![Grafana dashboard](docs/dashboard.png)

## Metrics Exported

### Default: public API (no auth required)

| Metric | Description |
|--------|-------------|
| `sharkey_up` | Instance reachable (1/0) |
| `sharkey_notes_total` | Total notes (local + remote) |
| `sharkey_notes_local_total` | Local notes only |
| `sharkey_users_total` | Total users seen (local + remote) |
| `sharkey_users_local_total` | Local users only |
| `sharkey_reactions_total` | Total reactions |
| `sharkey_instances_total` | Federated instance count |
| `sharkey_drive_usage_local_bytes` | Local drive usage\* |
| `sharkey_drive_usage_remote_bytes` | Remote drive usage\* |
| `sharkey_users_online` | Current online local users |
| `sharkey_users_online_network` | Current online users (local + remote) |
| `sharkey_federation_subscribing_total` | Instances subscribing to this instance |
| `sharkey_federation_publishing_total` | Instances this instance publishes to |
| `sharkey_federation_bidirectional_total` | Bidirectional federation instances |
| `sharkey_federation_subscribing_active` | Active subscribing instances |
| `sharkey_federation_publishing_active` | Active publishing instances |
| `sharkey_federation_stalled` | Stalled/unreachable instances |
| `sharkey_federation_delivered_instances` | Instances successfully delivered to (last hour) |
| `sharkey_federation_inbox_instances` | Instances received from (last hour) |
| `sharkey_active_users_readwrite` | Users who both read and wrote today |
| `sharkey_active_users_read` | Users who read today |
| `sharkey_active_users_write` | Users who wrote today |
| `sharkey_ap_deliver_succeeded` | AP deliveries succeeded (last hour) |
| `sharkey_ap_deliver_failed` | AP deliveries failed (last hour) |
| `sharkey_ap_inbox_received` | AP inbox messages received (last hour) |

\* Drive usage may report 0 in some Sharkey versions, and some configurations (e.g. using object storage backends).

### Default: admin API (requires token)

| Metric | Description |
|--------|-------------|
| `sharkey_server_cpu_cores` | CPU core count |
| `sharkey_server_mem_total_bytes` | Total memory |
| `sharkey_server_fs_total_bytes` | Total filesystem space |
| `sharkey_server_fs_used_bytes` | Used filesystem space |
| `sharkey_queue_<name>_waiting` | Waiting jobs per queue (deliver, inbox, db, objectStorage) |
| `sharkey_queue_<name>_active` | Active jobs per queue |
| `sharkey_queue_<name>_delayed` | Delayed jobs per queue |
| `sharkey_db_<table>_rows` | Estimated row count per key DB table |
| `sharkey_db_<table>_size_bytes` | Size per key DB table (bytes) |

### Optional: extended metrics (opt-in flags)

These produce more metrics and/or higher cardinality output. Useful for larger instances.

| Flag | Metrics | Auth | Description |
|------|---------|------|-------------|
| `--charts-notes` | `sharkey_chart_notes_{local,remote}_{total,inc,dec}` | No | Note creation/deletion rates |
| `--charts-users` | `sharkey_chart_users_{local,remote}_{total,inc,dec}` | No | User registration/deletion rates |
| `--charts-drive` | `sharkey_chart_drive_{local,remote}_{inc,dec}_{files,bytes}` | No | Drive file/size change rates |
| `--extended-queue-stats` | `sharkey_extqueue_<name>_*` | Token | All 11 queues (system, webhooks, scheduled notes, etc.) |
| `--delayed-hosts` | `sharkey_delayed_{deliver,inbox}{host="..."}` | Token | Per-domain delayed job counts — **high cardinality** |

## Quick Start

```bash
# Copy the exporter script
cp sharkey-exporter.sh /usr/local/bin/
chmod +x /usr/local/bin/sharkey-exporter.sh

# Create output directory
mkdir -p /var/lib/prometheus-textfile

# Test it
sharkey-exporter.sh --output /var/lib/prometheus-textfile/sharkey.prom

# Add to cron (every minute)
echo '* * * * * /usr/local/bin/sharkey-exporter.sh --output /var/lib/prometheus-textfile/sharkey.prom' | crontab -

# For admin metrics, create a token in the Sharkey web UI.
# Run --create-token to see exactly which permissions to enable:
sharkey-exporter.sh --create-token

# Then use the token (any of these work — in priority order):
sharkey-exporter.sh --token YOUR_API_TOKEN --output /var/lib/prometheus-textfile/sharkey.prom
SHARKEYEX_TOKEN=YOUR_API_TOKEN sharkey-exporter.sh --output /var/lib/prometheus-textfile/sharkey.prom
SHARKEYEX_TOKEN_FILE=/etc/sharkey-exporter/token sharkey-exporter.sh --output /var/lib/prometheus-textfile/sharkey.prom
SHARKEYEX_INSTANCE=https://my-instance.example SHARKEYEX_TOKEN=YOUR_API_TOKEN sharkey-exporter.sh
```

## Prometheus / Grafana Alloy Configuration

### Prometheus textfile collector

```yaml
# prometheus.yml
scrape_configs:
  - job_name: sharkey
    static_configs:
      - targets: ['localhost:9100']
    # Assumes node_exporter with --collector.textfile.directory=/var/lib/prometheus-textfile
```

### Grafana Alloy

```alloy
prometheus.exporter.unix "sharkey_textfile" {
  textfile {
    directory = "/var/lib/prometheus-textfile"
  }
  // Disable all collectors except textfile
  disable_collectors = ["arp","bcache","bonding","btrfs","conntrack","cpu","cpufreq",
    "diskstats","dmi","edac","entropy","fibrechannel","filefd","filesystem","hwmon",
    "infiniband","ipvs","loadavg","mdadm","meminfo","netclass","netdev","netstat",
    "nfs","nfsd","nvme","os","powersupplyclass","pressure","rapl","schedstat",
    "selinux","sockstat","softnet","stat","tapestats","thermal_zone","time",
    "timex","udp_queues","uname","vmstat","watchdog","xfs","zfs"]
}

prometheus.scrape "sharkey_metrics" {
  targets         = prometheus.exporter.unix.sharkey_textfile.targets
  forward_to      = [prometheus.remote_write.<YOUR_ENDPOINT_HERE>.receiver]
  scrape_interval = "60s"
}
```

## Requirements

- bash, curl, jq
- A Sharkey/Misskey instance
- Prometheus with textfile collector, or Grafana Alloy

## Compatibility

Tested with Sharkey 2025.4.x. Should work with any Misskey-compatible fork that exposes `/api/stats` and the charts API.

## License

MIT
