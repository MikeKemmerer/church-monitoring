#!/usr/bin/env bash
# upload-calendar-image.cgi - Uploads a new calendar image.
# Expects a POST body: {"filename":"YYYY-MM-DD Description.ext","data_base64":"..."}
#
# The filename must already carry the removal-date prefix (the dashboard
# prepends the date the operator picked before sending) -- enforced here too,
# since client-side formatting is never trusted alone. Alternatively, a
# filename prefixed "EVERGREEN " instead of a date marks an image that
# should never be treated as stale/removable (see list-calendar-images.cgi's
# evergreen field). Writing the file and regenerating optimized/thumbnail
# derivatives happens as the church-calendar owner via a sudo helper
# (mirrors church-screenshot.sh's pattern).

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

# Enforce the YYYY-MM-DD removal-date prefix (or the EVERGREEN marker),
# basename-only, allowed extension.
if ! echo "$FILENAME" | grep -qP '^(\d{4}-\d{2}-\d{2}|EVERGREEN) [^/\\]+\.(jpe?g|png|gif|webp)$'; then
    json_error "filename must be 'YYYY-MM-DD Description.ext' or 'EVERGREEN Description.ext' (jpg/jpeg/png/gif/webp)"
fi

SAFE_NAME=$(basename "$FILENAME")
if [ "$SAFE_NAME" != "$FILENAME" ]; then
    json_error "invalid filename"
fi

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

RESULT=$(echo "$DATA_B64" | sudo -u pi "$HELPER" "$IMAGES_DIR" "$SAFE_NAME" 2>&1)
RC=$?

TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

echo "Content-Type: application/json"
echo ""
if [ $RC -eq 0 ]; then
    echo "{\"result\":\"uploaded\",\"filename\":$(echo "$SAFE_NAME" | jq -Rs .),\"timestamp\":\"$TIMESTAMP\"}"
else
    echo "{\"result\":\"failed\",\"error\":$(echo "$RESULT" | jq -Rs .),\"timestamp\":\"$TIMESTAMP\"}"
fi
