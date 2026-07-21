#!/usr/bin/env bash
# cec-control.cgi — Proxies CEC control commands to a specific client.
# Called by the dashboard with ?host=<client_name>&action=on|standby|active

source /usr/local/lib/church-monitoring/auth-lib.sh
require_role contributor

echo "Content-Type: application/json"
echo ""

CONFIG="/etc/church-monitoring/server-config.json"
CERT="/etc/church-monitoring/ssl/server.crt"
KEY="/etc/church-monitoring/ssl/server.key"
CA="/etc/church-monitoring/ca/ca.crt"

# Parse query string
parse_qs() { echo "$QUERY_STRING" | tr '&' '\n' | grep "^$1=" | cut -d= -f2- | head -1; }

TARGET=$(parse_qs "host")
ACTION=$(parse_qs "action")

if [ -z "$TARGET" ]; then
    echo '{"error":"missing host parameter"}'
    exit 0
fi

if [ -z "$ACTION" ]; then
    echo '{"error":"missing action parameter"}'
    exit 0
fi

# Sanitize host
TARGET_CLEAN=$(echo "$TARGET" | tr -cd 'a-zA-Z0-9._-')
if [ "$TARGET_CLEAN" != "$TARGET" ]; then
    echo '{"error":"invalid host parameter"}'
    exit 0
fi

# Sanitize action
case "$ACTION" in
    on|standby|active) ;;
    *)
        echo '{"error":"invalid action, use: on, standby, active"}'
        exit 0
        ;;
esac

if [ ! -f "$CONFIG" ]; then
    echo '{"error":"server-config.json not found"}'
    exit 0
fi

# Look up client
CLIENT=$(jq -c --arg name "$TARGET_CLEAN" '.clients[] | select(.name == $name)' "$CONFIG" 2>/dev/null)
if [ -z "$CLIENT" ]; then
    echo '{"error":"unknown client"}'
    exit 0
fi

HOST=$(echo "$CLIENT" | jq -r '.host')
PORT=$(echo "$CLIENT" | jq -r '.port')

DATA=$(curl -s --connect-timeout 5 --max-time 20 \
    --cert "$CERT" --key "$KEY" --cacert "$CA" -k \
    "https://${HOST}:${PORT}/cgi-bin/cec-control.cgi?action=${ACTION}" 2>/dev/null) || true

if [ -z "$DATA" ] || ! echo "$DATA" | jq . &>/dev/null; then
    echo '{"error":"CEC control failed or timed out"}'
    exit 0
fi

echo "$DATA"
