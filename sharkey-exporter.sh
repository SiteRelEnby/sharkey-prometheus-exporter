#!/usr/bin/env bash
#
# sharkey-prometheus-exporter
#
# Polls a Sharkey/Misskey instance API and writes Prometheus textfile metrics.
# Run via cron every 30-60s.
#
# Usage:
#   sharkey-exporter.sh [--instance <url>] [--output <path>] [--token <api-token>]
#                       [--token-file <path>] [--charts-notes] [--charts-users]
#                       [--charts-drive] [--extended-queue-stats] [--delayed-hosts]
#
# Token resolution order: --token flag > --token-file flag > SHARKEYEX_TOKEN env var
#                         > SHARKEYEX_TOKEN_FILE env var
#
# Without a token, only public API metrics are collected.
# With a token, admin metrics (queues, server info, DB stats) are also collected.
#
# Optional flags enable additional metrics that are less commonly needed or
# produce higher cardinality output — intended for larger instances with
# more monitoring infrastructure.
#
# Note: set -e is intentionally omitted — we want to collect as many metrics as
# possible even if individual API calls fail.
set -uo pipefail

INSTANCE="${SHARKEYEX_INSTANCE:-http://127.0.0.1:3000}"
INSTANCE="${INSTANCE%/}"
OUTPUT="${SHARKEYEX_OUTPUT:-/var/lib/prometheus-textfile/sharkey.prom}"
TOKEN="${SHARKEYEX_TOKEN:-}"
TOKEN_FILE="${SHARKEYEX_TOKEN_FILE:-}"
DOMAIN="${SHARKEYEX_DOMAIN:-}"
OPT_CREATE_TOKEN=false
OPT_CHARTS_NOTES=false
OPT_CHARTS_USERS=false
OPT_CHARTS_DRIVE=false
OPT_EXTENDED_QUEUES=false
OPT_DELAYED_HOSTS=false

# ---- dependency check ----
for cmd in curl jq; do
    if ! command -v "$cmd" &>/dev/null; then
        echo "Error: required command '$cmd' not found. Please install it." >&2
        exit 2
    fi
done

# ---- argument parsing ----
while [[ $# -gt 0 ]]; do
    case "$1" in
        --instance)              INSTANCE="${2%/}"; shift 2 ;;
        --output)                OUTPUT="$2"; shift 2 ;;
        --token)                 TOKEN="$2"; shift 2 ;;
        --token-file)            TOKEN_FILE="$2"; shift 2 ;;
        --domain)                DOMAIN="$2"; shift 2 ;;
        --create-token)          OPT_CREATE_TOKEN=true; shift ;;
        --charts-notes)          OPT_CHARTS_NOTES=true; shift ;;
        --charts-users)          OPT_CHARTS_USERS=true; shift ;;
        --charts-drive)          OPT_CHARTS_DRIVE=true; shift ;;
        --extended-queue-stats)  OPT_EXTENDED_QUEUES=true; shift ;;
        --delayed-hosts)         OPT_DELAYED_HOSTS=true; shift ;;
        -h|--help)
            cat <<'USAGE'
Usage: sharkey-exporter.sh [OPTIONS]

Options:
  --instance <url>     Sharkey instance URL (default: http://127.0.0.1:3000)
  --output <path>      Output .prom file path (default: /var/lib/prometheus-textfile/sharkey.prom)
  --token <token>      API token for admin metrics
  --token-file <path>  Read API token from a file
  --domain <name>      Override domain label (default: auto-detected from instance)
  --create-token       Print the minimum permissions needed to create an API
                       token for this exporter, then exit.
  -h, --help           Show this help

Extended metrics (opt-in):
  --charts-notes           Note creation/deletion rate breakdown
  --charts-users           User registration/deletion rate breakdown
  --charts-drive           Drive file count/size change rates
  --extended-queue-stats   All queues (system, webhooks, etc.) via admin/queue/queues
                           (requires token)
  --delayed-hosts          Per-domain delayed delivery/inbox counts — high cardinality
                           (requires token)

Environment variables:
  SHARKEYEX_INSTANCE    Instance URL (default: http://127.0.0.1:3000)
  SHARKEYEX_OUTPUT      Output .prom file path (default: /var/lib/prometheus-textfile/sharkey.prom)
  SHARKEYEX_TOKEN       API token (used if --token is not set)
  SHARKEYEX_TOKEN_FILE  Token file path (used if --token-file is not set)
  SHARKEYEX_DOMAIN      Domain label override (used if --domain is not set)

Token priority: --token > --token-file > SHARKEYEX_TOKEN > SHARKEYEX_TOKEN_FILE
USAGE
            exit 0
            ;;
        *)
            echo "Error: unknown option '$1'" >&2
            echo "Run '$0 --help' for usage." >&2
            exit 1
            ;;
    esac
done

# ---- token resolution ----
if [[ -z "$TOKEN" && -n "$TOKEN_FILE" ]]; then
    if [[ ! -r "$TOKEN_FILE" ]]; then
        echo "Error: cannot read token file '$TOKEN_FILE'" >&2
        exit 1
    fi
    TOKEN="$(<"$TOKEN_FILE")"
fi

TOKEN="${TOKEN%%$'\n'}"  # strip trailing newline from file reads
TOKEN="${TOKEN## }"     # strip leading/trailing whitespace
TOKEN="${TOKEN%% }"

# Warn if a token source was specified but resolved to empty
if [[ -z "$TOKEN" && -n "$TOKEN_FILE" ]]; then
    echo "Warning: token file exists but is empty — admin metrics will be skipped" >&2
fi

# ---- helpers ----
TMP="${OUTPUT}.tmp.$$"
trap 'rm -f "$TMP"' EXIT

api_post() {
    local endpoint="$1"
    local data
    data="${2-"{}"}"
    curl -s --max-time 10 -X POST "$INSTANCE/api/$endpoint" \
        -H 'Content-Type: application/json' \
        -d "$data"
}

api_post_auth() {
    local endpoint="$1"
    api_post "$endpoint" "$(jq -nc --arg token "$TOKEN" '{i: $token}')"
}

# Check an API response for errors. Returns 0 (success) if the response is
# non-empty and does not contain an error object.
api_ok() {
    [[ -n "$1" ]] && ! echo "$1" | jq -e '.error' &>/dev/null
}

# =========================================================================
# --create-token: print the minimum permissions needed and exit
# =========================================================================

if [[ "$OPT_CREATE_TOKEN" == true ]]; then
    cat <<'TOKENHELP'
To create a minimal-permission token for this exporter:

1. Open your Sharkey instance in a browser
2. Go to Settings > API > Generate Access Token
3. Name it something like "prometheus-exporter"
4. Enable ONLY these permissions (GUI names in quotes):

   [x] "View server info"         (read:admin:server-info — CPU cores, memory, filesystem)
   [x] "View job queue info"      (read:admin:queue — queue stats, extended queues, delayed hosts)
   [x] "View database table stats" (read:admin:table-stats — DB table row counts and sizes)
   [x] "View emoji"               (read:admin:emoji — needed for admin/queue/stats due to
                                    an upstream bug; this endpoint checks the wrong permission)

5. Save the token to a file:

   mkdir -p /etc/sharkey-exporter
   echo 'YOUR_TOKEN_HERE' > /etc/sharkey-exporter/token
   chmod 600 /etc/sharkey-exporter/token

6. Use it:

   sharkey-exporter.sh --token-file /etc/sharkey-exporter/token --output /var/lib/prometheus-textfile/sharkey.prom

Note: Sharkey's token creation API (miauth/gen-token) is restricted to
browser sessions only, so this cannot be automated from the command line.
TOKENHELP
    exit 0
fi

# =========================================================================
# Public API metrics (no auth required)
# =========================================================================

stats="$(api_post stats)"

if ! api_ok "$stats"; then
    cat > "$TMP" <<'EOF'
# HELP sharkey_up Instance is reachable
# TYPE sharkey_up gauge
sharkey_up 0
EOF
    # Inject domain label if available (--domain was set even though instance is down)
    if [[ -n "$DOMAIN" ]]; then
        sed -i -E "s/^(sharkey_[a-zA-Z_]+) /\1{domain=\"${DOMAIN}\"} /" "$TMP"
    fi
    mv "$TMP" "$OUTPUT"
    exit 1
fi

# Auto-detect domain from instance metadata if not overridden
if [[ -z "$DOMAIN" ]]; then
    meta="$(api_post meta)"
    if api_ok "$meta"; then
        DOMAIN="$(echo "$meta" | jq -r '.uri // empty' | sed 's|^https\?://||')"
    fi
fi

# Parse all public stats in a single jq call
read -r notes notes_local users users_local reactions instances drive_local drive_remote < <(
    echo "$stats" | jq -r '[
        .notesCount // 0,
        .originalNotesCount // 0,
        .usersCount // 0,
        .originalUsersCount // 0,
        .reactionsCount // 0,
        .instances // 0,
        .driveUsageLocal // 0,
        .driveUsageRemote // 0
    ] | @tsv'
)

cat > "$TMP" <<EOF
# HELP sharkey_up Instance is reachable
# TYPE sharkey_up gauge
sharkey_up 1

# HELP sharkey_notes_total Total notes on this instance (local + remote)
# TYPE sharkey_notes_total gauge
sharkey_notes_total $notes

# HELP sharkey_notes_local_total Local notes count
# TYPE sharkey_notes_local_total gauge
sharkey_notes_local_total $notes_local

# HELP sharkey_users_total Total users seen (local + remote)
# TYPE sharkey_users_total gauge
sharkey_users_total $users

# HELP sharkey_users_local_total Local user count
# TYPE sharkey_users_local_total gauge
sharkey_users_local_total $users_local

# HELP sharkey_reactions_total Total reactions
# TYPE sharkey_reactions_total gauge
sharkey_reactions_total $reactions

# HELP sharkey_instances_total Federated instances count
# TYPE sharkey_instances_total gauge
sharkey_instances_total $instances

# HELP sharkey_drive_usage_local_bytes Local drive usage in bytes (may be 0 in some Sharkey versions)
# TYPE sharkey_drive_usage_local_bytes gauge
sharkey_drive_usage_local_bytes $drive_local

# HELP sharkey_drive_usage_remote_bytes Remote drive usage in bytes (may be 0 in some Sharkey versions)
# TYPE sharkey_drive_usage_remote_bytes gauge
sharkey_drive_usage_remote_bytes $drive_remote
EOF

# Online users (public, no auth)
online="$(api_post get-online-users-count)"
if api_ok "$online"; then
    read -r online_local online_network < <(
        echo "$online" | jq -r '[.count // 0, .countAcrossNetwork // 0] | @tsv'
    )

    cat >> "$TMP" <<EOF

# HELP sharkey_users_online Current online local users
# TYPE sharkey_users_online gauge
sharkey_users_online $online_local

# HELP sharkey_users_online_network Current online users across the network (local + remote)
# TYPE sharkey_users_online_network gauge
sharkey_users_online_network $online_network
EOF
fi

# Charts: federation (public, no auth) — gives accumulated totals
fed_chart="$(api_post charts/federation '{"span":"hour","limit":1}')"
if api_ok "$fed_chart"; then
    read -r fed_sub fed_pub fed_pubsub fed_sub_active fed_pub_active fed_stalled \
         fed_delivered fed_inbox < <(
        echo "$fed_chart" | jq -r '[
            .sub[0] // 0,
            .pub[0] // 0,
            .pubsub[0] // 0,
            .subActive[0] // 0,
            .pubActive[0] // 0,
            .stalled[0] // 0,
            (.deliveredInstances[0] // 0),
            (.inboxInstances[0] // 0)
        ] | @tsv'
    )

    cat >> "$TMP" <<EOF

# HELP sharkey_federation_subscribing_total Instances subscribing to this instance
# TYPE sharkey_federation_subscribing_total gauge
sharkey_federation_subscribing_total $fed_sub

# HELP sharkey_federation_publishing_total Instances this instance publishes to
# TYPE sharkey_federation_publishing_total gauge
sharkey_federation_publishing_total $fed_pub

# HELP sharkey_federation_bidirectional_total Instances with bidirectional federation
# TYPE sharkey_federation_bidirectional_total gauge
sharkey_federation_bidirectional_total $fed_pubsub

# HELP sharkey_federation_subscribing_active Active subscribing instances
# TYPE sharkey_federation_subscribing_active gauge
sharkey_federation_subscribing_active $fed_sub_active

# HELP sharkey_federation_publishing_active Active publishing instances
# TYPE sharkey_federation_publishing_active gauge
sharkey_federation_publishing_active $fed_pub_active

# HELP sharkey_federation_stalled Stalled/unreachable instances
# TYPE sharkey_federation_stalled gauge
sharkey_federation_stalled $fed_stalled

# HELP sharkey_federation_delivered_instances Instances successfully delivered to (last hour)
# TYPE sharkey_federation_delivered_instances gauge
sharkey_federation_delivered_instances $fed_delivered

# HELP sharkey_federation_inbox_instances Instances received from (last hour)
# TYPE sharkey_federation_inbox_instances gauge
sharkey_federation_inbox_instances $fed_inbox
EOF
fi

# Charts: active users (public, no auth)
active_users="$(api_post charts/active-users '{"span":"day","limit":1}')"
if api_ok "$active_users"; then
    read -r au_readwrite au_read au_write < <(
        echo "$active_users" | jq -r '[
            .readWrite[0] // 0,
            .read[0] // 0,
            .write[0] // 0
        ] | @tsv'
    )

    cat >> "$TMP" <<EOF

# HELP sharkey_active_users_readwrite Users who both read and wrote today
# TYPE sharkey_active_users_readwrite gauge
sharkey_active_users_readwrite $au_readwrite

# HELP sharkey_active_users_read Users who read today
# TYPE sharkey_active_users_read gauge
sharkey_active_users_read $au_read

# HELP sharkey_active_users_write Users who wrote today
# TYPE sharkey_active_users_write gauge
sharkey_active_users_write $au_write
EOF
fi

# Charts: AP request stats (public, no auth)
ap_requests="$(api_post charts/ap-request '{"span":"hour","limit":1}')"
if api_ok "$ap_requests"; then
    read -r ap_deliver_ok ap_deliver_fail ap_inbox < <(
        echo "$ap_requests" | jq -r '[
            .deliverSucceeded[0] // 0,
            .deliverFailed[0] // 0,
            .inboxReceived[0] // 0
        ] | @tsv'
    )

    cat >> "$TMP" <<EOF

# HELP sharkey_ap_deliver_succeeded ActivityPub deliveries succeeded (last hour)
# TYPE sharkey_ap_deliver_succeeded gauge
sharkey_ap_deliver_succeeded $ap_deliver_ok

# HELP sharkey_ap_deliver_failed ActivityPub deliveries failed (last hour)
# TYPE sharkey_ap_deliver_failed gauge
sharkey_ap_deliver_failed $ap_deliver_fail

# HELP sharkey_ap_inbox_received ActivityPub inbox messages received (last hour)
# TYPE sharkey_ap_inbox_received gauge
sharkey_ap_inbox_received $ap_inbox
EOF
fi

# =========================================================================
# Optional public chart metrics (opt-in flags)
# =========================================================================

if [[ "$OPT_CHARTS_NOTES" == true ]]; then
    charts_notes="$(api_post charts/notes '{"span":"hour","limit":1}')"
    if api_ok "$charts_notes"; then
        read -r cn_local_total cn_local_inc cn_local_dec \
             cn_remote_total cn_remote_inc cn_remote_dec < <(
            echo "$charts_notes" | jq -r '[
                .local.total[0] // 0,
                .local.inc[0] // 0,
                .local.dec[0] // 0,
                .remote.total[0] // 0,
                .remote.inc[0] // 0,
                .remote.dec[0] // 0
            ] | @tsv'
        )

        cat >> "$TMP" <<EOF

# HELP sharkey_chart_notes_local_total Local notes total (chart)
# TYPE sharkey_chart_notes_local_total gauge
sharkey_chart_notes_local_total $cn_local_total

# HELP sharkey_chart_notes_local_inc Local notes created (last hour)
# TYPE sharkey_chart_notes_local_inc gauge
sharkey_chart_notes_local_inc $cn_local_inc

# HELP sharkey_chart_notes_local_dec Local notes deleted (last hour)
# TYPE sharkey_chart_notes_local_dec gauge
sharkey_chart_notes_local_dec $cn_local_dec

# HELP sharkey_chart_notes_remote_total Remote notes total (chart)
# TYPE sharkey_chart_notes_remote_total gauge
sharkey_chart_notes_remote_total $cn_remote_total

# HELP sharkey_chart_notes_remote_inc Remote notes created (last hour)
# TYPE sharkey_chart_notes_remote_inc gauge
sharkey_chart_notes_remote_inc $cn_remote_inc

# HELP sharkey_chart_notes_remote_dec Remote notes deleted (last hour)
# TYPE sharkey_chart_notes_remote_dec gauge
sharkey_chart_notes_remote_dec $cn_remote_dec
EOF
    fi
fi

if [[ "$OPT_CHARTS_USERS" == true ]]; then
    charts_users="$(api_post charts/users '{"span":"day","limit":1}')"
    if api_ok "$charts_users"; then
        read -r cu_local_total cu_local_inc cu_local_dec \
             cu_remote_total cu_remote_inc cu_remote_dec < <(
            echo "$charts_users" | jq -r '[
                .local.total[0] // 0,
                .local.inc[0] // 0,
                .local.dec[0] // 0,
                .remote.total[0] // 0,
                .remote.inc[0] // 0,
                .remote.dec[0] // 0
            ] | @tsv'
        )

        cat >> "$TMP" <<EOF

# HELP sharkey_chart_users_local_total Local users total (chart)
# TYPE sharkey_chart_users_local_total gauge
sharkey_chart_users_local_total $cu_local_total

# HELP sharkey_chart_users_local_inc Local user registrations (last day)
# TYPE sharkey_chart_users_local_inc gauge
sharkey_chart_users_local_inc $cu_local_inc

# HELP sharkey_chart_users_local_dec Local user deletions (last day)
# TYPE sharkey_chart_users_local_dec gauge
sharkey_chart_users_local_dec $cu_local_dec

# HELP sharkey_chart_users_remote_total Remote users total (chart)
# TYPE sharkey_chart_users_remote_total gauge
sharkey_chart_users_remote_total $cu_remote_total

# HELP sharkey_chart_users_remote_inc Remote users added (last day)
# TYPE sharkey_chart_users_remote_inc gauge
sharkey_chart_users_remote_inc $cu_remote_inc

# HELP sharkey_chart_users_remote_dec Remote users removed (last day)
# TYPE sharkey_chart_users_remote_dec gauge
sharkey_chart_users_remote_dec $cu_remote_dec
EOF
    fi
fi

if [[ "$OPT_CHARTS_DRIVE" == true ]]; then
    charts_drive="$(api_post charts/drive '{"span":"hour","limit":1}')"
    if api_ok "$charts_drive"; then
        read -r cd_local_inc_count cd_local_inc_size cd_local_dec_count cd_local_dec_size \
             cd_remote_inc_count cd_remote_inc_size cd_remote_dec_count cd_remote_dec_size < <(
            echo "$charts_drive" | jq -r '[
                .local.incCount[0] // 0,
                .local.incSize[0] // 0,
                .local.decCount[0] // 0,
                .local.decSize[0] // 0,
                .remote.incCount[0] // 0,
                .remote.incSize[0] // 0,
                .remote.decCount[0] // 0,
                .remote.decSize[0] // 0
            ] | @tsv'
        )

        cat >> "$TMP" <<EOF

# HELP sharkey_chart_drive_local_inc_files Local files added (last hour)
# TYPE sharkey_chart_drive_local_inc_files gauge
sharkey_chart_drive_local_inc_files $cd_local_inc_count

# HELP sharkey_chart_drive_local_inc_bytes Local bytes added (last hour)
# TYPE sharkey_chart_drive_local_inc_bytes gauge
sharkey_chart_drive_local_inc_bytes $cd_local_inc_size

# HELP sharkey_chart_drive_local_dec_files Local files removed (last hour)
# TYPE sharkey_chart_drive_local_dec_files gauge
sharkey_chart_drive_local_dec_files $cd_local_dec_count

# HELP sharkey_chart_drive_local_dec_bytes Local bytes removed (last hour)
# TYPE sharkey_chart_drive_local_dec_bytes gauge
sharkey_chart_drive_local_dec_bytes $cd_local_dec_size

# HELP sharkey_chart_drive_remote_inc_files Remote files added (last hour)
# TYPE sharkey_chart_drive_remote_inc_files gauge
sharkey_chart_drive_remote_inc_files $cd_remote_inc_count

# HELP sharkey_chart_drive_remote_inc_bytes Remote bytes added (last hour)
# TYPE sharkey_chart_drive_remote_inc_bytes gauge
sharkey_chart_drive_remote_inc_bytes $cd_remote_inc_size

# HELP sharkey_chart_drive_remote_dec_files Remote files removed (last hour)
# TYPE sharkey_chart_drive_remote_dec_files gauge
sharkey_chart_drive_remote_dec_files $cd_remote_dec_count

# HELP sharkey_chart_drive_remote_dec_bytes Remote bytes removed (last hour)
# TYPE sharkey_chart_drive_remote_dec_bytes gauge
sharkey_chart_drive_remote_dec_bytes $cd_remote_dec_size
EOF
    fi
fi

# =========================================================================
# Admin API metrics (requires token)
# =========================================================================

if [[ -z "$TOKEN" ]]; then
    # Warn about any token-requiring flags that were requested but won't run
    token_flags=()
    [[ "$OPT_EXTENDED_QUEUES" == true ]] && token_flags+=("--extended-queue-stats")
    [[ "$OPT_DELAYED_HOSTS" == true ]]   && token_flags+=("--delayed-hosts")
    if [[ ${#token_flags[@]} -gt 0 ]]; then
        echo "Warning: token required for ${token_flags[*]} — skipping (no token provided)" >&2
    fi
fi

if [[ -n "$TOKEN" ]]; then
    # Server info
    server_info="$(api_post_auth admin/server-info)"

    if api_ok "$server_info"; then
        read -r cpu_cores mem_total fs_total fs_used < <(
            echo "$server_info" | jq -r '[
                .cpu.cores // 0,
                .mem.total // 0,
                .fs.total // 0,
                .fs.used // 0
            ] | @tsv'
        )

        cat >> "$TMP" <<EOF

# HELP sharkey_server_cpu_cores CPU core count
# TYPE sharkey_server_cpu_cores gauge
sharkey_server_cpu_cores $cpu_cores

# HELP sharkey_server_mem_total_bytes Total memory in bytes
# TYPE sharkey_server_mem_total_bytes gauge
sharkey_server_mem_total_bytes $mem_total

# HELP sharkey_server_fs_total_bytes Total filesystem in bytes
# TYPE sharkey_server_fs_total_bytes gauge
sharkey_server_fs_total_bytes $fs_total

# HELP sharkey_server_fs_used_bytes Used filesystem in bytes
# TYPE sharkey_server_fs_used_bytes gauge
sharkey_server_fs_used_bytes $fs_used
EOF
    fi

    # Queue stats — default: deliver, inbox, db, objectStorage from admin/queue/stats
    queue_stats="$(api_post_auth admin/queue/stats)"

    if api_ok "$queue_stats"; then
        # Extract all 4 default queues — waiting, active, delayed only.
        # Note: "completed" and "failed" are omitted — BullMQ retains only
        # ~10 completed and ~30 failed jobs per type (removeOnComplete/removeOnFail),
        # so those counts reflect retention limits, not real totals.
        queue_metrics="$(echo "$queue_stats" | jq -r '
            to_entries[] |
            "# HELP sharkey_queue_\(.key)_waiting Waiting jobs in \(.key) queue\n# TYPE sharkey_queue_\(.key)_waiting gauge\nsharkey_queue_\(.key)_waiting \(.value.waiting // 0)\n# HELP sharkey_queue_\(.key)_active Active jobs in \(.key) queue\n# TYPE sharkey_queue_\(.key)_active gauge\nsharkey_queue_\(.key)_active \(.value.active // 0)\n# HELP sharkey_queue_\(.key)_delayed Delayed jobs in \(.key) queue\n# TYPE sharkey_queue_\(.key)_delayed gauge\nsharkey_queue_\(.key)_delayed \(.value.delayed // 0)"
        ' 2>/dev/null)"

        if [[ -n "$queue_metrics" ]]; then
            printf '\n%s\n' "$queue_metrics" >> "$TMP"
        fi
    fi

    # Database table stats — row counts and sizes for key tables
    table_stats="$(api_post_auth admin/get-table-stats)"

    if api_ok "$table_stats"; then
        table_metrics="$(echo "$table_stats" | jq -r '
            ["note", "user", "user_profile", "drive_file", "following", "instance",
             "notification", "antenna", "clip", "poll"] as $tables |
            to_entries[] |
            select(.key as $k | $tables | any(. == $k)) |
            "# HELP sharkey_db_\(.key)_rows Estimated row count for \(.key) table\n# TYPE sharkey_db_\(.key)_rows gauge\nsharkey_db_\(.key)_rows \(.value.count)\n# HELP sharkey_db_\(.key)_size_bytes Size of \(.key) table in bytes\n# TYPE sharkey_db_\(.key)_size_bytes gauge\nsharkey_db_\(.key)_size_bytes \(.value.size)"
        ' 2>/dev/null)"

        if [[ -n "$table_metrics" ]]; then
            printf '\n%s\n' "$table_metrics" >> "$TMP"
        fi
    fi

    # =====================================================================
    # Optional admin metrics (opt-in flags)
    # =====================================================================

    # Extended queue stats — all queues via admin/queue/queues
    if [[ "$OPT_EXTENDED_QUEUES" == true ]]; then
        ext_queues="$(api_post_auth admin/queue/queues)"

        if api_ok "$ext_queues"; then
            ext_queue_metrics="$(echo "$ext_queues" | jq -r '
                .[] |
                .name as $name |
                .counts // {} |
                "# HELP sharkey_extqueue_\($name)_waiting Waiting jobs in \($name) queue\n# TYPE sharkey_extqueue_\($name)_waiting gauge\nsharkey_extqueue_\($name)_waiting \(.waiting // 0)\n# HELP sharkey_extqueue_\($name)_active Active jobs in \($name) queue\n# TYPE sharkey_extqueue_\($name)_active gauge\nsharkey_extqueue_\($name)_active \(.active // 0)\n# HELP sharkey_extqueue_\($name)_delayed Delayed jobs in \($name) queue\n# TYPE sharkey_extqueue_\($name)_delayed gauge\nsharkey_extqueue_\($name)_delayed \(.delayed // 0)"
            ' 2>/dev/null)"

            if [[ -n "$ext_queue_metrics" ]]; then
                printf '\n%s\n' "$ext_queue_metrics" >> "$TMP"
            fi
        fi
    fi

    # Per-domain delayed delivery/inbox counts (high cardinality)
    if [[ "$OPT_DELAYED_HOSTS" == true ]]; then
        deliver_delayed="$(api_post_auth admin/queue/deliver-delayed)"
        if api_ok "$deliver_delayed"; then
            delayed_metrics="$(echo "$deliver_delayed" | jq -r '
                .[] | "# HELP sharkey_delayed_deliver Per-host delayed outbound delivery count\n# TYPE sharkey_delayed_deliver gauge\nsharkey_delayed_deliver{host=\"\(.[0])\"} \(.[1])"
            ' 2>/dev/null)"
            if [[ -n "$delayed_metrics" ]]; then
                printf '\n%s\n' "$delayed_metrics" >> "$TMP"
            fi
        fi

        inbox_delayed="$(api_post_auth admin/queue/inbox-delayed)"
        if api_ok "$inbox_delayed"; then
            inbox_delayed_metrics="$(echo "$inbox_delayed" | jq -r '
                .[] | "# HELP sharkey_delayed_inbox Per-host delayed inbound count\n# TYPE sharkey_delayed_inbox gauge\nsharkey_delayed_inbox{host=\"\(.[0])\"} \(.[1])"
            ' 2>/dev/null)"
            if [[ -n "$inbox_delayed_metrics" ]]; then
                printf '\n%s\n' "$inbox_delayed_metrics" >> "$TMP"
            fi
        fi
    fi
fi

# Inject domain label into all metrics
if [[ -n "$DOMAIN" ]]; then
    sed -i -E \
        -e "s/^(sharkey_[a-zA-Z_]+)\{/\1{domain=\"${DOMAIN}\",/" \
        -e "s/^(sharkey_[a-zA-Z_]+) /\1{domain=\"${DOMAIN}\"} /" \
        "$TMP"
fi

mv "$TMP" "$OUTPUT"
