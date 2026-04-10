#!/usr/bin/env bash
# device-status.cgi — Checks reachability of devices defined in client config.
# Each client object may have a "check" field:
#   "ping"       → ICMP ping
#   "http:PORT"  → HTTP probe on given port
#   (missing)    → skip
# Results are cached for 60 seconds.

echo "Content-Type: application/json"
echo ""

CONFIG="/etc/church-monitoring/server-config.json"
CACHE_DIR="/var/cache/church-monitoring"
CACHE_FILE="$CACHE_DIR/device-status.json"
CACHE_MAX_AGE=60

if [ ! -f "$CONFIG" ]; then
    echo '{"error":"server-config.json not found"}'
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

mkdir -p "$CACHE_DIR"

RESULT="{}"

while IFS= read -r client; do
    NAME=$(echo "$client" | jq -r '.name')
    HOST=$(echo "$client" | jq -r '.host')
    CHECK=$(echo "$client" | jq -r '.check // empty')
    CLIENT_PORT=$(echo "$client" | jq -r '.port // empty')

    [ -z "$CHECK" ] && continue

    STATUS="offline"

    case "$CHECK" in
        ping)
            # TCP port probe — ICMP ping requires cap_net_raw which www-data lacks
            if [ -n "$CLIENT_PORT" ]; then
                if timeout 2 bash -c "echo >/dev/tcp/$HOST/$CLIENT_PORT" 2>/dev/null; then
                    STATUS="online"
                fi
            fi
            ;;
        http:*)
            PORT="${CHECK#http:}"
            # Validate port is numeric
            if [[ "$PORT" =~ ^[0-9]+$ ]]; then
                if curl -s --connect-timeout 3 --max-time 5 -o /dev/null \
                    "http://${HOST}:${PORT}/" 2>/dev/null; then
                    STATUS="online"
                fi
            fi
            ;;
    esac

    RESULT=$(echo "$RESULT" | jq --arg name "$NAME" --arg status "$STATUS" \
        '. + {($name): $status}')
done < <(jq -c '.clients[]' "$CONFIG" 2>/dev/null)

echo "$RESULT" | jq . > "$CACHE_FILE" 2>/dev/null || true
cat "$CACHE_FILE" 2>/dev/null || echo "$RESULT"
