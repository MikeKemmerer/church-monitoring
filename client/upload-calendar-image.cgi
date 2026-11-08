#!/usr/bin/env bash
# upload-calendar-image.cgi - Uploads a new calendar image.
# Expects a POST body: {"filename":"YYYY-MM-DD Description.ext","data_base64":"...",
#   "mode":"persistent|scheduled","show_from":"YYYY-MM-DD","remove_after":"YYYY-MM-DD",
#   "auto_archive":true}
# The mode has no default: the operator must choose. Persistent filenames carry a
# 2099+ date; scheduled ones carry the remove_after date and, if auto_archive, an
# "[auto-archive]" marker before the extension.
#
# The filename must already carry the removal-date prefix (the dashboard
# prepends the date the operator picked before sending) -- enforced here too,
# since client-side formatting is never trusted alone. Writing the file and
# regenerating optimized/thumbnail derivatives happens as the church-calendar
# owner via a sudo helper (mirrors church-screenshot.sh's pattern).

CONFIG="/etc/church-monitoring/client-config.json"
MAX_BYTES=10485760   # 10 MB

json_error() {
    echo "Content-Type: application/json"
    echo ""
    echo "{\"error\":\"$1\"}"
    exit 0
}

if [ "${REQUEST_METHOD:-}" != "POST" ]; then
    json_error "must be POST"
fi

IMAGES_DIR=""
if [ -f "$CONFIG" ]; then
    IMAGES_DIR=$(jq -r '.calendar_images_path // empty' "$CONFIG" 2>/dev/null || echo "")
fi
[ -z "$IMAGES_DIR" ] && IMAGES_DIR="/var/www/html/church-calendar/images"

if ! [[ "${CONTENT_LENGTH:-}" =~ ^[0-9]+$ ]] || [ "${CONTENT_LENGTH:-0}" -le 0 ]; then
    json_error "empty or invalid request body"
fi

BODY=$(head -c "$CONTENT_LENGTH")

FILENAME=$(echo "$BODY" | jq -r '.filename // empty' 2>/dev/null)
DATA_B64=$(echo "$BODY" | jq -r '.data_base64 // empty' 2>/dev/null)

[ -z "$FILENAME" ] && json_error "missing filename"
[ -z "$DATA_B64" ] && json_error "missing data_base64"

# Enforce the YYYY-MM-DD removal-date prefix, basename-only, allowed extension.
if ! echo "$FILENAME" | grep -qP '^\d{4}-\d{2}-\d{2} [^/\\]+\.(jpe?g|png|gif|webp)$'; then
    json_error "filename must be 'YYYY-MM-DD Description.ext' (jpg/jpeg/png/gif/webp)"
fi

SAFE_NAME=$(basename "$FILENAME")
if [ "$SAFE_NAME" != "$FILENAME" ]; then
    json_error "invalid filename"
fi

MODE=$(echo "$BODY" | jq -r '.mode // empty' 2>/dev/null)
SHOW_FROM=$(echo "$BODY" | jq -r '.show_from // empty' 2>/dev/null)
REMOVE_AFTER=$(echo "$BODY" | jq -r '.remove_after // empty' 2>/dev/null)
AUTO_ARCHIVE=$(echo "$BODY" | jq -r 'if .auto_archive == true then "1" else "0" end' 2>/dev/null)
NAME_DATE="${FILENAME:0:10}"

for DAY in "$SHOW_FROM" "$REMOVE_AFTER"; do
    if [ -n "$DAY" ] && ! [[ "$DAY" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
        json_error "dates must be YYYY-MM-DD"
    fi
done
HELPER_ARGS=()
case "$MODE" in
    persistent)
        [ $((10#${NAME_DATE:0:4})) -ge 2099 ] || json_error "a persistent image filename must start with a 2099 date"
        HELPER_ARGS=(--mode persistent)
        ;;
    scheduled)
        [ -n "$REMOVE_AFTER" ] || json_error "a scheduled image needs an end date"
        [ "$REMOVE_AFTER" = "$NAME_DATE" ] || json_error "filename date must match the end date"
        HAS_MARKER=0
        [[ "$FILENAME" == *" [auto-archive]."* ]] && HAS_MARKER=1
        [ "$HAS_MARKER" = "$AUTO_ARCHIVE" ] || json_error "auto-archive marker must match the auto-archive choice"
        HELPER_ARGS=(--mode scheduled --remove-after "$REMOVE_AFTER")
        [ -z "$SHOW_FROM" ] || HELPER_ARGS+=(--show-from "$SHOW_FROM")
        [ "$AUTO_ARCHIVE" != "1" ] || HELPER_ARGS+=(--auto-archive)
        ;;
    *)
        json_error "mode must be persistent or scheduled"
        ;;
esac

# Rough decoded-size check (base64 inflates ~33%) before we even decode.
B64_LEN=${#DATA_B64}
APPROX_BYTES=$(( B64_LEN * 3 / 4 ))
if [ "$APPROX_BYTES" -gt "$MAX_BYTES" ]; then
    json_error "image too large (max 10MB)"
fi

HELPER="/usr/local/bin/church-monitoring-write-calendar-image"
if [ ! -x "$HELPER" ]; then
    json_error "upload helper not installed"
fi

RESULT=$(echo "$DATA_B64" | sudo -u pi "$HELPER" "$IMAGES_DIR" "$SAFE_NAME" "${HELPER_ARGS[@]}" 2>&1)
RC=$?

TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

echo "Content-Type: application/json"
echo ""
if [ $RC -eq 0 ]; then
    echo "{\"result\":\"uploaded\",\"filename\":$(echo "$SAFE_NAME" | jq -Rs .),\"timestamp\":\"$TIMESTAMP\"}"
else
    echo "{\"result\":\"failed\",\"error\":$(echo "$RESULT" | jq -Rs .),\"timestamp\":\"$TIMESTAMP\"}"
fi
