#!/usr/bin/env bash
# fetch-screenshot.cgi — Proxies a screenshot request to a specific client.
# Called by the dashboard with ?host=<client_name>
# Returns the JPEG image directly (or JSON error).

CONFIG="/etc/church-monitoring/server-config.json"
CERT="/etc/church-monitoring/ssl/server.crt"
KEY="/etc/church-monitoring/ssl/server.key"
CA="/etc/church-monitoring/ca/ca.crt"

# Parse host from query string
TARGET=$(echo "$QUERY_STRING" | tr '&' '\n' | grep "^host=" | cut -d= -f2- | head -1)

json_error() {
    echo "Content-Type: application/json"
    echo ""
    echo "{\"error\":\"$1\"}"
    exit 0
}

if [ -z "$TARGET" ]; then
    json_error "missing host parameter"
fi

TARGET_CLEAN=$(echo "$TARGET" | tr -cd 'a-zA-Z0-9._-')
if [ "$TARGET_CLEAN" != "$TARGET" ]; then
    json_error "invalid host parameter"
fi

if [ ! -f "$CONFIG" ]; then
    json_error "server-config.json not found"
fi

CLIENT=$(jq -c --arg name "$TARGET_CLEAN" '.clients[] | select(.name == $name)' "$CONFIG" 2>/dev/null)
if [ -z "$CLIENT" ]; then
    json_error "unknown client"
fi

HOST=$(echo "$CLIENT" | jq -r '.host')
PORT=$(echo "$CLIENT" | jq -r '.port')

TMPFILE="/tmp/church-monitoring-proxy-screenshot-$$.jpg"

HTTP_CODE=$(curl -s --connect-timeout 5 --max-time 15 \
    --cert "$CERT" --key "$KEY" --cacert "$CA" -k \
    -o "$TMPFILE" -w "%{http_code}" \
    "https://${HOST}:${PORT}/cgi-bin/screenshot.cgi" 2>/dev/null) || true

if [ "$HTTP_CODE" != "200" ] || [ ! -s "$TMPFILE" ]; then
    rm -f "$TMPFILE"
    json_error "screenshot unavailable"
fi

# Check if we got JSON error instead of image
if head -c 1 "$TMPFILE" | grep -q '{'; then
    echo "Content-Type: application/json"
    echo ""
    cat "$TMPFILE"
    rm -f "$TMPFILE"
    exit 0
fi

echo "Content-Type: image/jpeg"
echo "Cache-Control: no-cache"
echo ""
cat "$TMPFILE"
rm -f "$TMPFILE"
