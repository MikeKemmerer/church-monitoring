#!/usr/bin/env bash
# device-status.cgi — Checks reachability of standalone devices.
# Reads the "devices" array from server-config.json (NOT "clients").
# Each device has a "check" field:
#   "tcp:PORT"   — TCP port probe
#   "http:PORT"  — HTTP GET probe
# Results are cached for 60 seconds.

echo "Content-Type: application/json"
echo ""

CONFIG="/etc/church-monitoring/server-config.json"
CACHE_DIR="/var/cache/church-monitoring"
CACHE_FILE="$CACHE_DIR/device-status.json"
CACHE_MAX_AGE=60

if [ ! -f "$CONFIG" ]; then
    echo '{}'
    exit 0
fi

# No devices configured — return empty
DEVICE_COUNT=$(jq '.devices | length' "$CONFIG" 2>/dev/null)
if [ -z "$DEVICE_COUNT" ] || [ "$DEVICE_COUNT" = "0" ] || [ "$DEVICE_COUNT" = "null" ]; then
    echo '{}'
    exit 0
fi

# Return cached result if fresh enough
if [ -f "$CACHE_FILE" ]; then
    AGE=$(( $(date +%s) - $(stat -c %Y "$CACHE_FILE") ))
    if [ "$AGE" -lt "$CACHE_MAX_AGE" ]; then
        cat "$CACHE_FILE"
        exit 0
    fi
fi

mkdir -p "$CACHE_DIR" 2>/dev/null
chgrp www-data "$CACHE_DIR" 2>/dev/null
chmod 775 "$CACHE_DIR" 2>/dev/null

RESULT="{}"

while IFS= read -r device; do
    NAME=$(echo "$device" | jq -r '.name')
    HOST=$(echo "$device" | jq -r '.host')
    CHECK=$(echo "$device" | jq -r '.check // empty')

    [ -z "$CHECK" ] && continue

    STATUS="offline"

    case "$CHECK" in
        tcp:*)
            PROBE_PORT="${CHECK#tcp:}"
            if [[ "$PROBE_PORT" =~ ^[0-9]+$ ]]; then
                if timeout 3 bash -c "echo >/dev/tcp/$HOST/$PROBE_PORT" 2>/dev/null; then
                    STATUS="online"
                fi
            fi
            ;;
        http:*)
            PORT="${CHECK#http:}"
            if [[ "$PORT" =~ ^[0-9]+$ ]]; then
                if curl -s -k --connect-timeout 3 --max-time 5 -o /dev/null \
                    "http://${HOST}:${PORT}/" 2>/dev/null; then
                    STATUS="online"
                fi
            fi
            ;;
    esac

    RESULT=$(echo "$RESULT" | jq --arg name "$NAME" --arg status "$STATUS" \
        '. + {($name): $status}')
done < <(jq -c '.devices[]' "$CONFIG" 2>/dev/null)

echo "$RESULT" | jq . > "$CACHE_FILE" 2>/dev/null || true
cat "$CACHE_FILE" 2>/dev/null || echo "$RESULT"
