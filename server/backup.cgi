#!/usr/bin/env bash
# backup.cgi — Proxies a backup-trigger request to a specific client.
# Called by the dashboard with ?host=<client_name>
# Returns the client's JSON backup summary (or a JSON error).

echo "Content-Type: application/json"
echo ""

CONFIG="/etc/church-monitoring/server-config.json"
CERT="/etc/church-monitoring/ssl/server.crt"
KEY="/etc/church-monitoring/ssl/server.key"
CA="/etc/church-monitoring/ca/ca.crt"

TARGET=$(echo "$QUERY_STRING" | tr '&;' '\n' | grep "^host=" | cut -d= -f2- | head -1)

if [ -z "$TARGET" ]; then
    echo '{"error":"missing host parameter"}'
    exit 0
fi

TARGET_CLEAN=$(echo "$TARGET" | tr -cd 'a-zA-Z0-9._-')
if [ "$TARGET_CLEAN" != "$TARGET" ]; then
    echo '{"error":"invalid host parameter"}'
    exit 0
fi

if [ ! -f "$CONFIG" ]; then
    echo '{"error":"server-config.json not found"}'
    exit 0
fi

CLIENT=$(jq -c --arg name "$TARGET_CLEAN" '.clients[] | select(.name == $name)' "$CONFIG" 2>/dev/null | head -1)
if [ -z "$CLIENT" ]; then
    echo '{"error":"unknown client"}'
    exit 0
fi

HOST=$(echo "$CLIENT" | jq -r '.host')
PORT=$(echo "$CLIENT" | jq -r '.port')

# Backups can take a little while (copying configs + tar); allow a longer budget.
DATA=$(curl -s --connect-timeout 5 --max-time 120 \
    --cert "$CERT" --key "$KEY" --cacert "$CA" -k \
    "https://${HOST}:${PORT}/cgi-bin/backup.cgi" 2>/dev/null) || true

if [ -z "$DATA" ]; then
    echo '{"error":"request to client timed out or failed"}'
    exit 0
fi

if ! echo "$DATA" | jq . &>/dev/null; then
    SNIP=$(echo "$DATA" | tr '\n\r' ' ' | cut -c1-180)
    echo "{\"error\":\"client returned non-JSON\",\"detail\":$(echo "$SNIP" | jq -Rs .)}"
    exit 0
fi

echo "$DATA"
