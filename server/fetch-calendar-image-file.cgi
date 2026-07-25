#!/usr/bin/env bash
# fetch-calendar-image-file.cgi — Proxies a single full-size calendar image
# from a client (binary passthrough). Called with ?host=<client_name>&filename=<name>

source /usr/local/lib/church-monitoring/auth-lib.sh
require_role user

CONFIG="/etc/church-monitoring/server-config.json"
CERT="/etc/church-monitoring/ssl/server.crt"
KEY="/etc/church-monitoring/ssl/server.key"
CA="/etc/church-monitoring/ca/ca.crt"

json_error() {
    echo "Content-Type: application/json"
    echo ""
    echo "{\"error\":\"$1\"}"
    exit 0
}

TARGET=$(echo "$QUERY_STRING" | tr '&' '\n' | grep "^host=" | cut -d= -f2- | head -1)
[ -z "$TARGET" ] && json_error "missing host parameter"

TARGET_CLEAN=$(echo "$TARGET" | tr -cd 'a-zA-Z0-9._-')
[ "$TARGET_CLEAN" != "$TARGET" ] && json_error "invalid host parameter"

RAW_FILENAME=$(echo "$QUERY_STRING" | tr '&' '\n' | grep "^filename=" | cut -d= -f2- | head -1)
[ -z "$RAW_FILENAME" ] && json_error "missing filename parameter"

ARCHIVED=$(echo "$QUERY_STRING" | tr '&' '\n' | grep "^archived=" | cut -d= -f2- | head -1)
ARCHIVED_QS=""
[ "$ARCHIVED" = "1" ] && ARCHIVED_QS="&archived=1"

EVERGREEN=$(echo "$QUERY_STRING" | tr '&' '\n' | grep "^evergreen=" | cut -d= -f2- | head -1)
EVERGREEN_QS=""
[ "$EVERGREEN" = "1" ] && EVERGREEN_QS="&evergreen=1"

[ ! -f "$CONFIG" ] && json_error "server-config.json not found"

CLIENT=$(jq -c --arg name "$TARGET_CLEAN" '.clients[] | select(.name == $name)' "$CONFIG" 2>/dev/null)
[ -z "$CLIENT" ] && json_error "unknown client"

HOST=$(echo "$CLIENT" | jq -r '.host')
PORT=$(echo "$CLIENT" | jq -r '.port')

TMPFILE=$(mktemp /tmp/church-monitoring-proxy-calimg-XXXXXX)

HTTP_CODE=$(curl -s --connect-timeout 5 --max-time 15 \
    --cert "$CERT" --key "$KEY" --cacert "$CA" -k \
    -o "$TMPFILE" -w "%{http_code}" \
    "https://${HOST}:${PORT}/cgi-bin/fetch-calendar-image.cgi?filename=${RAW_FILENAME}${ARCHIVED_QS}${EVERGREEN_QS}" 2>/dev/null) || true

if [ "$HTTP_CODE" != "200" ] || [ ! -s "$TMPFILE" ]; then
    rm -f "$TMPFILE"
    json_error "image unavailable"
fi

# Check if we got JSON error instead of image
if head -c 1 "$TMPFILE" | grep -q '{'; then
    echo "Content-Type: application/json"
    echo ""
    cat "$TMPFILE"
    rm -f "$TMPFILE"
    exit 0
fi

case "$RAW_FILENAME" in
    *.jpg|*.jpeg|*.JPG|*.JPEG) CT="image/jpeg" ;;
    *.png|*.PNG) CT="image/png" ;;
    *.gif|*.GIF) CT="image/gif" ;;
    *.webp|*.WEBP) CT="image/webp" ;;
    *) CT="application/octet-stream" ;;
esac

echo "Content-Type: $CT"
echo ""
cat "$TMPFILE"
rm -f "$TMPFILE"
