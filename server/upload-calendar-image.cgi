#!/usr/bin/env bash
# upload-calendar-image.cgi — Proxies a calendar image upload to a client.
# Called with ?host=<client_name>; the POST body is forwarded as-is (JSON:
# {"filename":"...","data_base64":"..."}).

echo "Content-Type: application/json"
echo ""

CONFIG="/etc/church-monitoring/server-config.json"
CERT="/etc/church-monitoring/ssl/server.crt"
KEY="/etc/church-monitoring/ssl/server.key"
CA="/etc/church-monitoring/ca/ca.crt"

TARGET=$(echo "$QUERY_STRING" | tr '&' '\n' | grep "^host=" | cut -d= -f2- | head -1)
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

CLIENT=$(jq -c --arg name "$TARGET_CLEAN" '.clients[] | select(.name == $name)' "$CONFIG" 2>/dev/null)
if [ -z "$CLIENT" ]; then
    echo '{"error":"unknown client"}'
    exit 0
fi

HOST=$(echo "$CLIENT" | jq -r '.host')
PORT=$(echo "$CLIENT" | jq -r '.port')

if ! [[ "${CONTENT_LENGTH:-}" =~ ^[0-9]+$ ]] || [ "${CONTENT_LENGTH:-0}" -le 0 ]; then
    echo '{"error":"empty request body"}'
    exit 0
fi

TMPFILE=$(mktemp /tmp/church-monitoring-upload-body-XXXXXX)
head -c "$CONTENT_LENGTH" > "$TMPFILE"

DATA=$(curl -s --connect-timeout 5 --max-time 60 \
    --cert "$CERT" --key "$KEY" --cacert "$CA" -k \
    -X POST -H "Content-Type: application/json" --data-binary "@$TMPFILE" \
    "https://${HOST}:${PORT}/cgi-bin/upload-calendar-image.cgi" 2>/dev/null) || true

rm -f "$TMPFILE"

if [ -z "$DATA" ] || ! echo "$DATA" | jq . &>/dev/null; then
    echo '{"error":"upload failed or timed out"}'
    exit 0
fi

echo "$DATA"
