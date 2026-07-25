#!/usr/bin/env bash
# fetch-calendar-image.cgi - Serves one original calendar image as binary.
# Accepts ?filename=X (basename only, must exist in the configured images
# folder) and optionally &archived=1 or &evergreen=1 to serve from
# images/archive/ or images/evergreen/ instead. Used for "view full size"
# from the dashboard's image panel, and directly as the archive/evergreen
# panels' thumbnail <img> src (no separate preview generated for those).

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

ARCHIVED=$(echo "$QUERY_STRING" | tr '&' '\n' | grep "^archived=" | cut -d= -f2- | head -1)
EVERGREEN=$(echo "$QUERY_STRING" | tr '&' '\n' | grep "^evergreen=" | cut -d= -f2- | head -1)

# Basename only -- reject any path traversal attempt outright.
SAFE_NAME=$(basename "$FILENAME")
if [ "$SAFE_NAME" != "$FILENAME" ]; then
    json_error "invalid filename"
fi

if [ "$ARCHIVED" = "1" ]; then
    TARGET="$IMAGES_DIR/archive/$SAFE_NAME"
elif [ "$EVERGREEN" = "1" ]; then
    TARGET="$IMAGES_DIR/evergreen/$SAFE_NAME"
else
    TARGET="$IMAGES_DIR/$SAFE_NAME"
fi
if [ ! -f "$TARGET" ]; then
    json_error "image not found"
fi

case "$SAFE_NAME" in
    *.jpg|*.jpeg|*.JPG|*.JPEG) CT="image/jpeg" ;;
    *.png|*.PNG) CT="image/png" ;;
    *.gif|*.GIF) CT="image/gif" ;;
    *.webp|*.WEBP) CT="image/webp" ;;
    *) json_error "unsupported file type" ;;
esac

echo "Content-Type: $CT"
echo ""
cat "$TARGET"
