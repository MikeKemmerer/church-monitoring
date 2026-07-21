#!/usr/bin/env bash
# list-archived-calendar-images.cgi - Lists images sitting in the
# images/archive/ subfolder (created by archive-calendar-image.cgi instead
# of deleting outright). Read-only; no sudo required.
#
# Deliberately does NOT generate/embed base64 thumbnails the way
# list-calendar-images.cgi does for the active image list -- the archive
# view is much lower-traffic, and image_optimizer.py's own
# optimized/thumbnails derivatives get cleaned up once a file leaves
# images/ root, so there's nothing readily reusable to embed anyway. The
# dashboard instead points <img> tags directly at
# fetch-calendar-image.cgi?archived=1 and lets the browser scale it.

echo "Content-Type: application/json"
echo ""

CONFIG="/etc/church-monitoring/client-config.json"

IMAGES_DIR=""
if [ -f "$CONFIG" ]; then
    IMAGES_DIR=$(jq -r '.calendar_images_path // empty' "$CONFIG" 2>/dev/null || echo "")
fi
[ -z "$IMAGES_DIR" ] && IMAGES_DIR="/var/www/html/church-calendar/images"

ARCHIVE_DIR="$IMAGES_DIR/archive"

if [ ! -d "$ARCHIVE_DIR" ]; then
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
    FILE_DATE=$(echo "$BASENAME" | grep -oP '^\d{4}-\d{2}-\d{2}' || echo "")

    jq -n \
        --arg filename "$BASENAME" \
        --argjson size "$SIZE" \
        --arg mtime "$MTIME" \
        --arg event_date "$FILE_DATE" \
        '{filename:$filename, size:$size, mtime:$mtime,
          event_date: (if $event_date == "" then null else $event_date end)}' \
        >> "$ENTRIES_FILE"
done < <(find "$ARCHIVE_DIR" -maxdepth 1 -type f \( -iname "*.jpg" -o -iname "*.jpeg" -o -iname "*.png" -o -iname "*.gif" -o -iname "*.webp" \) 2>/dev/null | sort)

jq -n --slurpfile images "$ENTRIES_FILE" '{images: $images, total: ($images | length)}'
