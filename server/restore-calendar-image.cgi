#!/usr/bin/env bash
# restore-calendar-image.cgi — Proxies a calendar image restore request to a
# client (moves the image from images/archive/ back into images/ on the
# client). Called with ?host=<client_name>&filename=<name>&mode=persistent|scheduled
# [&show_from=D][&remove_after=D][&auto_archive=1]

source /usr/local/lib/church-monitoring/auth-lib.sh
require_role contributor

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

RAW_FILENAME=$(echo "$QUERY_STRING" | tr '&' '\n' | grep "^filename=" | cut -d= -f2- | head -1)
if [ -z "$RAW_FILENAME" ]; then
    echo '{"error":"missing filename parameter"}'
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

# Schedule choices are re-validated by the client; here they are only restricted to safe characters.
SCHEDULE_QS=""
for PARAM in mode show_from remove_after auto_archive; do
    VALUE=$(echo "$QUERY_STRING" | tr '&' '\n' | grep "^${PARAM}=" | cut -d= -f2- | head -1 | tr -cd 'a-z0-9-')
    [ -z "$VALUE" ] || SCHEDULE_QS="${SCHEDULE_QS}&${PARAM}=${VALUE}"
done

# The client's certificate is checked against its configured name; HOST may be an address or alias.
DATA=$(curl -s --connect-timeout 5 --max-time 45 \
    --cert "$CERT" --key "$KEY" --cacert "$CA" \
    --connect-to "${TARGET_CLEAN}:${PORT}:${HOST}:${PORT}" \
    "https://${TARGET_CLEAN}:${PORT}/cgi-bin/restore-calendar-image.cgi?filename=${RAW_FILENAME}${SCHEDULE_QS}" 2>/dev/null) || true

if [ -z "$DATA" ] || ! echo "$DATA" | jq . &>/dev/null; then
    echo '{"error":"restore failed or timed out"}'
    exit 0
fi

echo "$DATA"
