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

get_hosts_ip() {
    local hostname="$1"
    awk -v host="$hostname" '
        $1 !~ /^#/ {
            for (i = 2; i <= NF; i++) {
                if ($i == host) {
                    print $1
                    exit
                }
            }
        }
    ' /etc/hosts 2>/dev/null
}

get_mac_for_ip() {
    local ip="$1"
    local mac=""

    if command -v ip >/dev/null 2>&1; then
        mac=$(ip neigh show "$ip" 2>/dev/null | awk '{for (i = 1; i <= NF; i++) if ($i == "lladdr") {print $(i+1); exit}}')
    fi

    if [ -z "$mac" ] && command -v arp >/dev/null 2>&1; then
        mac=$(arp -n "$ip" 2>/dev/null | awk '/ at / {for (i = 1; i <= NF; i++) if ($i == "at") {print $(i+1); exit}}')
    fi

    echo "$mac" | tr 'A-F' 'a-f'
}

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

# Parse query string for refresh flag
FORCE_REFRESH=0
echo "$QUERY_STRING" | tr '&' '\n' | grep -q '^refresh=1$' && FORCE_REFRESH=1

# Return cached result if fresh enough
if [ "$FORCE_REFRESH" -eq 0 ] && [ -f "$CACHE_FILE" ]; then
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
    EXPECTED_MAC=$(echo "$device" | jq -r '.expected_mac // empty' | tr 'A-F' 'a-f')

    [ -z "$CHECK" ] && continue

    STATUS="offline"

    # Optional identity check: verify the resolved host IP maps to the expected MAC.
    if [ -n "$EXPECTED_MAC" ]; then
        RESOLVED_IP=""
        if [[ "$HOST" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            RESOLVED_IP="$HOST"
        else
            RESOLVED_IP=$(get_hosts_ip "$HOST")
        fi

        if [ -z "$RESOLVED_IP" ]; then
            RESULT=$(echo "$RESULT" | jq --arg name "$NAME" --arg status "offline" '. + {($name): $status}')
            continue
        fi

        ping -c 1 -W 1 "$RESOLVED_IP" >/dev/null 2>&1 || true
        RESOLVED_MAC=$(get_mac_for_ip "$RESOLVED_IP")
        if [ "$RESOLVED_MAC" != "$EXPECTED_MAC" ]; then
            RESULT=$(echo "$RESULT" | jq --arg name "$NAME" --arg status "offline" '. + {($name): $status}')
            continue
        fi
    fi

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
