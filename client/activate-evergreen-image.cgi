#!/usr/bin/env bash
# activate-evergreen-image.cgi - Moves a calendar image from the
# images/evergreen/ reserve pool back into the live images/ folder,
# putting it back into rotation. Accepts ?filename=X (basename only).

CONFIG="/etc/church-monitoring/client-config.json"

json_error() {
    echo "Content-Type: application/json"
    echo ""
    echo "{\"error\":\"$1\"}"
    exit 0
}

IMAGES_DIR=""
if [ -f "$CONFIG" ]; then
    IMAGES_DIR=$(jq -r '.calendar_images_path // empty' "$CONFIG" 2>/dev/null || echo "")
fi
[ -z "$IMAGES_DIR" ] && IMAGES_DIR="/var/www/html/church-calendar/images"

RAW_FILENAME=$(echo "$QUERY_STRING" | tr '&' '\n' | grep "^filename=" | cut -d= -f2- | head -1)
[ -z "$RAW_FILENAME" ] && json_error "missing filename parameter"

url_decode() {
    local val="$1"
    val="${val//+/ }"
    printf '%b' "${val//%/\\x}"
}
FILENAME=$(url_decode "$RAW_FILENAME")

SAFE_NAME=$(basename "$FILENAME")
if [ "$SAFE_NAME" != "$FILENAME" ]; then
    json_error "invalid filename"
fi

if [ ! -f "$IMAGES_DIR/evergreen/$SAFE_NAME" ]; then
    json_error "evergreen image not found"
fi

HELPER="/usr/local/bin/church-monitoring-activate-evergreen-image"
if [ ! -x "$HELPER" ]; then
    json_error "evergreen activate helper not installed"
fi

RESULT=$(sudo -u pi "$HELPER" "$IMAGES_DIR" "$SAFE_NAME" 2>&1)
RC=$?

TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

echo "Content-Type: application/json"
echo ""
if [ $RC -eq 0 ]; then
    echo "{\"result\":\"activated\",\"filename\":$(echo "$SAFE_NAME" | jq -Rs .),\"timestamp\":\"$TIMESTAMP\"}"
else
    echo "{\"result\":\"failed\",\"error\":$(echo "$RESULT" | jq -Rs .),\"timestamp\":\"$TIMESTAMP\"}"
fi
