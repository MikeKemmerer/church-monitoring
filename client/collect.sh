#!/usr/bin/env bash
# collect.sh — Collects system metrics and service status, writes cache JSON.
# Run by cron every 5 minutes on each monitored host.

set -euo pipefail

CONFIG="/etc/church-monitoring/client-config.json"
CACHE="/var/cache/church-monitoring/status.json"
CACHE_DIR="/var/cache/church-monitoring"
LOCK="$CACHE_DIR/.collect.lock"

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

# Disk percentage
DISK_PCT=0
DISK_TOTAL_NUM="${DISK_TOTAL## }"
DISK_USED_NUM="${DISK_USED## }"
if [[ "$DISK_TOTAL_NUM" =~ ^[0-9]+$ ]] && [ "$DISK_TOTAL_NUM" -gt 0 ]; then
    DISK_PCT=$(awk "BEGIN{printf \"%.1f\", $DISK_USED_NUM * 100 / $DISK_TOTAL_NUM}")
fi

# Pi throttle state (hex string; empty if unavailable)
THROTTLE_HEX=""
if command -v vcgencmd &>/dev/null; then
    THROTTLE_HEX=$(vcgencmd get_throttled 2>/dev/null | grep -oP '0x[0-9a-fA-F]+' || echo "")
fi

# HDMI/display connection state
HDMI_STATE=""
HDMI_SOURCE=""
HDMI_RAW=""
if command -v tvservice &>/dev/null; then
    TVRAW=$(tvservice -s 2>/dev/null || echo "")
    if [ -n "$TVRAW" ]; then
        HDMI_SOURCE="tvservice"
        HDMI_RAW="$TVRAW"
        if echo "$TVRAW" | grep -qiE 'HDMI CEA|HDMI DMT|DVI'; then
            HDMI_STATE="connected"
        elif echo "$TVRAW" | grep -qi 'off\|no device\|TV is off'; then
            HDMI_STATE="disconnected"
        else
            HDMI_STATE="unknown"
        fi
    fi
fi

if [ -z "$HDMI_STATE" ]; then
    SYSFS_RAW=$(grep -H . /sys/class/drm/*/status 2>/dev/null || true)
    if [ -n "$SYSFS_RAW" ]; then
        HDMI_SOURCE="sysfs"
        # Ignore non-display virtual connectors (e.g., Writeback) for state and hover details.
        SYSFS_DISPLAY=$(echo "$SYSFS_RAW" | grep -E '/(card[0-9]+-(HDMI|DVI|DP|eDP)-[^/]+)/status:' || true)
        [ -z "$SYSFS_DISPLAY" ] && SYSFS_DISPLAY="$SYSFS_RAW"

        HDMI_RAW=$(echo "$SYSFS_DISPLAY" | \
            sed -E 's|/sys/class/drm/||; s|/status:|:|g' | tr '\n' ';' | sed 's/;$//')

        if echo "$SYSFS_DISPLAY" | grep -q ':connected'; then
            HDMI_STATE="connected"
        elif echo "$SYSFS_DISPLAY" | grep -q ':disconnected'; then
            HDMI_STATE="disconnected"
        else
            HDMI_STATE="unknown"
        fi
    fi
fi

if [ -z "$HDMI_STATE" ] && command -v xrandr &>/dev/null; then
    XRRAW=$(xrandr --query 2>/dev/null || echo "")
    if [ -n "$XRRAW" ]; then
        HDMI_SOURCE="xrandr"
        HDMI_RAW=$(echo "$XRRAW" | tr '\n' ';' | sed 's/;$//' | cut -c1-220)
        if echo "$XRRAW" | grep -q ' connected'; then
            HDMI_STATE="connected"
        else
            HDMI_STATE="disconnected"
        fi
    fi
fi

[ -z "$HDMI_STATE" ] && HDMI_STATE="unknown"

# TLS certificate expiry (days remaining; -1 = unavailable)
CERT_DAYS=-1
CERT_EXPIRY_UTC=""
CERT_PATH="/etc/church-monitoring/ssl/agent.crt"
if [ -f "$CERT_PATH" ]; then
    EXP_RAW=$(openssl x509 -enddate -noout -in "$CERT_PATH" 2>/dev/null | cut -d= -f2 || echo "")
    if [ -n "$EXP_RAW" ]; then
        CERT_EXPIRY_UTC=$(date -u -d "$EXP_RAW" +"%Y-%m-%d %H:%M:%S UTC" 2>/dev/null || echo "")
        EXP_EPOCH=$(date -d "$EXP_RAW" +%s 2>/dev/null || echo "0")
        NOW_EPOCH=$(date +%s)
        CERT_DAYS=$(( (EXP_EPOCH - NOW_EPOCH) / 86400 ))
    fi
fi

# Church-calendar image folder check (configurable via .calendar_images_path in client-config.json)
CAL_IMG_TOTAL=-1
CAL_IMG_STALE=-1
CAL_IMG_DIR=$(jq -r '.calendar_images_path // empty' "$CONFIG" 2>/dev/null || echo "")
[ -z "$CAL_IMG_DIR" ] && CAL_IMG_DIR="/var/www/html/church-calendar/images"
if [ -d "$CAL_IMG_DIR" ]; then
    TODAY=$(date +%Y-%m-%d)
    CAL_IMG_TOTAL=0
    CAL_IMG_STALE=0
    while IFS= read -r f; do
        CAL_IMG_TOTAL=$((CAL_IMG_TOTAL + 1))
        BASENAME=$(basename "$f")
        FILE_DATE=$(echo "$BASENAME" | grep -oP '^\d{4}-\d{2}-\d{2}' || echo "")
        if [ -n "$FILE_DATE" ] && [[ "$FILE_DATE" < "$TODAY" ]]; then
            CAL_IMG_STALE=$((CAL_IMG_STALE + 1))
        fi
    done < <(find "$CAL_IMG_DIR" -maxdepth 1 -type f 2>/dev/null || true)
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
                # Regex match against full ps -ef output
                COUNT=$(ps -ef 2>/dev/null | grep -E "$MATCH" | grep -vc grep) || COUNT=0
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
    --argjson disk_pct "$DISK_PCT" \
    --arg throttle_hex "$THROTTLE_HEX" \
    --arg hdmi "$HDMI_STATE" \
    --arg hdmi_source "$HDMI_SOURCE" \
    --arg hdmi_raw "$HDMI_RAW" \
    --argjson cert_days "$CERT_DAYS" \
    --arg cert_expiry_utc "$CERT_EXPIRY_UTC" \
    --argjson cal_img_total "$CAL_IMG_TOTAL" \
    --argjson cal_img_stale "$CAL_IMG_STALE" \
    --argjson temp "$TEMP" \
    --argjson services "$SERVICES" \
    --argjson cec "$CEC_ENABLED" \
    '{
        hostname: $hostname,
        timestamp: $timestamp,
        uptime_seconds: $uptime,
        load: {avg_1: $load1, avg_5: $load5, avg_15: $load15},
        memory: {total_mb: $mem_total, used_mb: $mem_used, available_mb: $mem_avail},
        disk: {total_mb: $disk_total, used_mb: $disk_used, available_mb: $disk_avail, pct: $disk_pct},
        temperature_c: $temp,
        throttle_hex: (if $throttle_hex == "" then null else $throttle_hex end),
        hdmi: (if $hdmi == "" then null else $hdmi end),
        hdmi_source: (if $hdmi_source == "" then null else $hdmi_source end),
        hdmi_raw: (if $hdmi_raw == "" then null else $hdmi_raw end),
        cert_days: (if $cert_days == -1 then null else $cert_days end),
        cert_expires_utc: (if $cert_expiry_utc == "" then null else $cert_expiry_utc end),
        calendar_images: (if $cal_img_total == -1 then null else {total: $cal_img_total, stale: $cal_img_stale} end),
        services: $services,
        cec_enabled: $cec
    }' > "${CACHE}.tmp"

mv "${CACHE}.tmp" "$CACHE"
chgrp www-data "$CACHE" 2>/dev/null || true
chmod 664 "$CACHE"
