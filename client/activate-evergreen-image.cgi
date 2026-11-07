#!/usr/bin/env bash
# activate-evergreen-image.cgi - Moves a calendar image from the
# images/evergreen/ reserve pool back into the live images/ folder,
# putting it back into rotation.
# Accepts ?filename=X&mode=persistent|scheduled[&show_from=D][&remove_after=D][&auto_archive=1]
# (basename only). The mode has no default: the operator must choose.

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

query_param() {
    url_decode "$(echo "$QUERY_STRING" | tr '&' '\n' | grep "^$1=" | cut -d= -f2- | head -1)"
}
MODE=$(query_param mode)
SHOW_FROM=$(query_param show_from)
REMOVE_AFTER=$(query_param remove_after)
AUTO_ARCHIVE=$(query_param auto_archive)
case "$MODE" in
    persistent|scheduled) ;;
    *) json_error "mode must be persistent or scheduled" ;;
esac
for DAY in "$SHOW_FROM" "$REMOVE_AFTER"; do
    if [ -n "$DAY" ] && ! [[ "$DAY" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
        json_error "dates must be YYYY-MM-DD"
    fi
done
HELPER_ARGS=(--mode "$MODE")
if [ "$MODE" = "scheduled" ]; then
    [ -n "$REMOVE_AFTER" ] || json_error "a scheduled image needs an end date"
    HELPER_ARGS+=(--remove-after "$REMOVE_AFTER")
    [ -z "$SHOW_FROM" ] || HELPER_ARGS+=(--show-from "$SHOW_FROM")
    [ "$AUTO_ARCHIVE" != "1" ] || HELPER_ARGS+=(--auto-archive)
fi

HELPER="/usr/local/bin/church-monitoring-activate-evergreen-image"
if [ ! -x "$HELPER" ]; then
    json_error "evergreen activate helper not installed"
fi

RESULT=$(sudo -u pi "$HELPER" "$IMAGES_DIR" "$SAFE_NAME" "${HELPER_ARGS[@]}" 2>&1)
RC=$?

TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

echo "Content-Type: application/json"
echo ""
if [ $RC -eq 0 ]; then
    echo "{\"result\":\"activated\",\"filename\":$(echo "$SAFE_NAME" | jq -Rs .),\"timestamp\":\"$TIMESTAMP\"}"
else
    echo "{\"result\":\"failed\",\"error\":$(echo "$RESULT" | jq -Rs .),\"timestamp\":\"$TIMESTAMP\"}"
fi
