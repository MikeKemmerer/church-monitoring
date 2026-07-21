#!/usr/bin/env bash
# archive-calendar-image.cgi - Archives a calendar image (moves it into
# images/archive/ instead of deleting it outright). The sudo helper also
# re-runs church-calendar's image_optimizer.py, which cleans up the now-
# orphaned optimized/thumbnail derivatives automatically. The archived file
# is preserved and can be brought back via restore-calendar-image.cgi.
# Accepts ?filename=X (basename only).

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

if [ ! -f "$IMAGES_DIR/$SAFE_NAME" ]; then
    json_error "image not found"
fi

HELPER="/usr/local/bin/church-monitoring-archive-calendar-image"
if [ ! -x "$HELPER" ]; then
    json_error "archive helper not installed"
fi

RESULT=$(sudo -u pi "$HELPER" "$IMAGES_DIR" "$SAFE_NAME" 2>&1)
RC=$?

TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

echo "Content-Type: application/json"
echo ""
if [ $RC -eq 0 ]; then
    echo "{\"result\":\"archived\",\"filename\":$(echo "$SAFE_NAME" | jq -Rs .),\"timestamp\":\"$TIMESTAMP\"}"
else
    echo "{\"result\":\"failed\",\"error\":$(echo "$RESULT" | jq -Rs .),\"timestamp\":\"$TIMESTAMP\"}"
fi
