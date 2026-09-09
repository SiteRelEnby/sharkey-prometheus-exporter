# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

Nothing has been tagged yet. The first tagged release will pick up everything
under Unreleased; the dated section below describes the state people have
been running from `main` since March.

## [Unreleased]

### Added

- Container image, published to `ghcr.io/siterelenby/sharkey-prometheus-exporter`
  on every push to `main` and every `v*` tag. It polls the instance on an interval
  and serves the result at `/metrics` on port 10054, so Prometheus can scrape it
  directly with no cron or textfile collector. Built for `linux/amd64` and
  `linux/arm64`, with build provenance attestations. Runs as an unprivileged user.
  Container arguments pass straight through to the exporter, so the opt-in metric
  flags work unchanged. Docker packaging contributed by
  [Bea](https://github.com/disastercurl), adopted from
  [The Argo's fork](https://github.com/ArgoIV/sharkey-prometheus-exporter).
- `SHARKEYEX_INSTANCE`, `SHARKEYEX_OUTPUT` and `SHARKEYEX_DOMAIN` environment
  variables, so every flag has an env var equivalent and the exporter can run
  with no arguments at all.
- Docker sections in the README and deployment guide, including a compose example.
- Port 10054 is registered on the Prometheus default port allocations wiki.

### Changed

- Token environment variables are now `SHARKEYEX_TOKEN` and `SHARKEYEX_TOKEN_FILE`.
  Resolution order is unchanged: `--token`, then `--token-file`, then
  `SHARKEYEX_TOKEN`, then `SHARKEYEX_TOKEN_FILE`.

### Deprecated

- `SHARKEY_TOKEN` and `SHARKEY_TOKEN_FILE`. Both still work but print a warning
  pointing at the prefixed name. They will be removed in a future release.

## 2026-03-12 (untagged)

### Added

- Bash, curl and jq exporter that polls the Sharkey API and writes Prometheus
  textfile metrics, intended to run from cron.
- Public API metrics: notes, users, reactions, federation, active users, drive
  usage, AP delivery counts.
- Admin API metrics with a token: server info, job queues, database table stats.
- Opt-in flags for higher cardinality metrics: `--charts-notes`, `--charts-users`,
  `--charts-drive`, `--extended-queue-stats`, `--delayed-hosts`.
- Token via `--token`, `--token-file`, `SHARKEY_TOKEN` or `SHARKEY_TOKEN_FILE`,
  passed to curl through jq rather than shell interpolation.
- `--create-token` prints the exact permissions to tick when creating the token
  in the Sharkey web UI.
- `domain` label on every metric, auto-detected from the instance or set with
  `--domain`, for multi-instance dashboards.
- Grafana dashboard template with datasource and instance selectors.

### Removed

- Queue `completed` and `failed` metrics. BullMQ caps retention on those, so
  they were never real counters.
