#!/usr/bin/env bash
# collect.sh — Collects system metrics and service status, writes cache JSON.
# Run by cron every 5 minutes on each monitored host.

set -euo pipefail

CONFIG="/etc/church-monitoring/client-config.json"
CACHE="/var/cache/church-monitoring/status.json"
CACHE_DIR="/var/cache/church-monitoring"
LOCK="/var/run/church-monitoring-collect.lock"

# Ensure cache directory exists
mkdir -p "$CACHE_DIR"

# Prevent overlapping runs
exec 200>"$LOCK"
flock -n 200 || exit 0

# --- System Metrics ---

UPTIME_SEC=$(awk '{print int($1)}' /proc/uptime)
LOAD_1=$(awk '{print $1}' /proc/loadavg)
LOAD_5=$(awk '{print $2}' /proc/loadavg)
LOAD_15=$(awk '{print $3}' /proc/loadavg)

# Memory (MB)
MEM_TOTAL=$(awk '/MemTotal/{printf "%d", $2/1024}' /proc/meminfo)
MEM_AVAIL=$(awk '/MemAvailable/{printf "%d", $2/1024}' /proc/meminfo)
MEM_USED=$((MEM_TOTAL - MEM_AVAIL))

# Disk (MB, root partition)
read -r DISK_TOTAL DISK_USED DISK_AVAIL <<< \
    "$(df -BM --output=size,used,avail / | tail -1 | tr -d 'M')"

# CPU temperature
TEMP="null"
if command -v vcgencmd &>/dev/null; then
    RAW=$(vcgencmd measure_temp 2>/dev/null | grep -oP '[0-9.]+' || echo "")
    [ -n "$RAW" ] && TEMP="$RAW"
elif [ -f /sys/class/thermal/thermal_zone0/temp ]; then
    RAW=$(cat /sys/class/thermal/thermal_zone0/temp 2>/dev/null || echo "0")
    TEMP=$(awk "BEGIN{printf \"%.1f\", $RAW/1000}")
fi

# --- Service/Process Checks ---

SERVICES="[]"
if [ -f "$CONFIG" ]; then
    while IFS= read -r line; do
        NAME=$(echo "$line" | jq -r '.name')
        TYPE=$(echo "$line" | jq -r '.type')
        STATUS="unknown"

        if [ "$TYPE" = "systemd" ]; then
            STATUS=$(systemctl is-active "$NAME" 2>/dev/null || echo "inactive")
        elif [ "$TYPE" = "process" ]; then
            MATCH=$(echo "$line" | jq -r '.match // empty')
            if [ -n "$MATCH" ]; then
                # Substring match against full ps -ef output
                COUNT=$(ps -ef 2>/dev/null | grep -F "$MATCH" | grep -vc grep) || COUNT=0
            else
                COUNT=$(pgrep -xc "$NAME" 2>/dev/null) || COUNT=0
            fi
            if [ "$COUNT" -gt "0" ]; then
                STATUS="running ($COUNT)"
            else
                STATUS="not running"
            fi
        fi

        SERVICES=$(echo "$SERVICES" | jq \
            --arg n "$NAME" --arg t "$TYPE" --arg s "$STATUS" \
            '. + [{"name":$n,"type":$t,"status":$s}]')
    done < <(jq -c '.monitors[]' "$CONFIG" 2>/dev/null || true)
fi

# --- Build Output ---

HOSTNAME_VAL=$(jq -r '.hostname // empty' "$CONFIG" 2>/dev/null || hostname)
[ -z "$HOSTNAME_VAL" ] && HOSTNAME_VAL=$(hostname)
CEC_ENABLED=$(jq -r '.cec_enabled // false' "$CONFIG" 2>/dev/null || echo "false")
TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

jq -n \
    --arg hostname "$HOSTNAME_VAL" \
    --arg timestamp "$TIMESTAMP" \
    --argjson uptime "$UPTIME_SEC" \
    --argjson load1 "$LOAD_1" \
    --argjson load5 "$LOAD_5" \
    --argjson load15 "$LOAD_15" \
    --argjson mem_total "$MEM_TOTAL" \
    --argjson mem_used "$MEM_USED" \
    --argjson mem_avail "$MEM_AVAIL" \
    --argjson disk_total "${DISK_TOTAL## }" \
    --argjson disk_used "${DISK_USED## }" \
    --argjson disk_avail "${DISK_AVAIL## }" \
    --argjson temp "$TEMP" \
    --argjson services "$SERVICES" \
    --argjson cec "$CEC_ENABLED" \
    '{
        hostname: $hostname,
        timestamp: $timestamp,
        uptime_seconds: $uptime,
        load: {avg_1: $load1, avg_5: $load5, avg_15: $load15},
        memory: {total_mb: $mem_total, used_mb: $mem_used, available_mb: $mem_avail},
        disk: {total_mb: $disk_total, used_mb: $disk_used, available_mb: $disk_avail},
        temperature_c: $temp,
        services: $services,
        cec_enabled: $cec
    }' > "${CACHE}.tmp"

mv "${CACHE}.tmp" "$CACHE"
chmod 644 "$CACHE"
