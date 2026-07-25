#!/usr/bin/env bash
# list-evergreen-images.cgi - Lists images sitting in the images/evergreen/
# reserve pool (a reusable stock of extra images, distinct from
# images/archive/'s "retired" images -- these are meant to be toggled back
# into active rotation at will). Read-only; no sudo required.
#
# Deliberately does NOT generate/embed base64 thumbnails, same reasoning as
# list-archived-calendar-images.cgi: this is a lower-traffic view, and the
# dashboard instead points <img> tags directly at
# fetch-calendar-image.cgi?evergreen=1 and lets the browser scale it.

echo "Content-Type: application/json"
echo ""

CONFIG="/etc/church-monitoring/client-config.json"

IMAGES_DIR=""
if [ -f "$CONFIG" ]; then
    IMAGES_DIR=$(jq -r '.calendar_images_path // empty' "$CONFIG" 2>/dev/null || echo "")
fi
[ -z "$IMAGES_DIR" ] && IMAGES_DIR="/var/www/html/church-calendar/images"

EVERGREEN_DIR="$IMAGES_DIR/evergreen"

if [ ! -d "$EVERGREEN_DIR" ]; then
    echo '{"images":[],"total":0}'
    exit 0
fi

ENTRIES_FILE=$(mktemp)
trap 'rm -f "$ENTRIES_FILE"' EXIT

while IFS= read -r f; do
    BASENAME=$(basename "$f")
    SIZE=$(stat -c '%s' "$f" 2>/dev/null || echo 0)
    MTIME_EPOCH=$(stat -c '%Y' "$f" 2>/dev/null || echo 0)
    MTIME=$(date -u -d "@${MTIME_EPOCH}" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || echo "")

    jq -n \
        --arg filename "$BASENAME" \
        --argjson size "$SIZE" \
        --arg mtime "$MTIME" \
        '{filename:$filename, size:$size, mtime:$mtime}' \
        >> "$ENTRIES_FILE"
done < <(find "$EVERGREEN_DIR" -maxdepth 1 -type f \( -iname "*.jpg" -o -iname "*.jpeg" -o -iname "*.png" -o -iname "*.gif" -o -iname "*.webp" \) 2>/dev/null | sort)

jq -n --slurpfile images "$ENTRIES_FILE" '{images: $images, total: ($images | length)}'
