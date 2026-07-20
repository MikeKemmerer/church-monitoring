#!/usr/bin/env bash
# list-calendar-images.cgi - Lists church-calendar's image folder for the
# dashboard's image management panel. Read-only; no sudo required.
#
# Returns each image's filename, size, mtime, the parsed removal date (from
# the "YYYY-MM-DD Description.ext" filename convention, if present) with a
# stale flag when that date is in the past, and an inline base64 preview
# data URL. Prefers the "optimized" WebP (up to 800x600 @ quality 85) that
# church-calendar's image_optimizer.py already generates for its own
# slideshow, falling back to the much smaller 50x50 thumbnail if that's
# unavailable.
#
# Uses the same calendar_images_path config + default fallback as collect.sh
# so the button only appears (data.calendar_images) when this will work.

echo "Content-Type: application/json"
echo ""

CONFIG="/etc/church-monitoring/client-config.json"

IMAGES_DIR=""
if [ -f "$CONFIG" ]; then
    IMAGES_DIR=$(jq -r '.calendar_images_path // empty' "$CONFIG" 2>/dev/null || echo "")
fi
[ -z "$IMAGES_DIR" ] && IMAGES_DIR="/var/www/html/church-calendar/images"

if [ ! -d "$IMAGES_DIR" ]; then
    echo '{"error":"calendar image folder not found on this host"}'
    exit 0
fi

OPTIMIZED_DIR="$IMAGES_DIR/optimized"
THUMB_DIR="$IMAGES_DIR/thumbnails"
TODAY=$(date +%Y-%m-%d)

ENTRIES="[]"
while IFS= read -r f; do
    BASENAME=$(basename "$f")
    SIZE=$(stat -c '%s' "$f" 2>/dev/null || echo 0)
    MTIME_EPOCH=$(stat -c '%Y' "$f" 2>/dev/null || echo 0)
    MTIME=$(date -u -d "@${MTIME_EPOCH}" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || echo "")
    FILE_DATE=$(echo "$BASENAME" | grep -oP '^\d{4}-\d{2}-\d{2}' || echo "")
    STALE="false"
    if [ -n "$FILE_DATE" ] && [[ "$FILE_DATE" < "$TODAY" ]]; then
        STALE="true"
    fi

    # Prefer the larger 'optimized' WebP (up to 800x600 @ quality 85, already
    # generated for the calendar's own slideshow) over the tiny 50x50 thumbnail
    # so previews in the dashboard aren't blurry.
    THUMB_DATA_URL=""
    PREVIEW_FILE="$OPTIMIZED_DIR/${BASENAME}.webp"
    [ -f "$PREVIEW_FILE" ] || PREVIEW_FILE="$THUMB_DIR/${BASENAME}.webp"
    if [ -f "$PREVIEW_FILE" ]; then
        THUMB_B64=$(base64 -w0 "$PREVIEW_FILE" 2>/dev/null || echo "")
        [ -n "$THUMB_B64" ] && THUMB_DATA_URL="data:image/webp;base64,${THUMB_B64}"
    fi

    ENTRY=$(jq -n \
        --arg filename "$BASENAME" \
        --argjson size "$SIZE" \
        --arg mtime "$MTIME" \
        --arg event_date "$FILE_DATE" \
        --argjson stale "$STALE" \
        --arg thumb "$THUMB_DATA_URL" \
        '{filename:$filename, size:$size, mtime:$mtime,
          event_date: (if $event_date == "" then null else $event_date end),
          stale:$stale,
          thumbnail: (if $thumb == "" then null else $thumb end)}')

    ENTRIES=$(echo "$ENTRIES" | jq --argjson e "$ENTRY" '. + [$e]')
done < <(find "$IMAGES_DIR" -maxdepth 1 -type f \( -iname "*.jpg" -o -iname "*.jpeg" -o -iname "*.png" -o -iname "*.gif" -o -iname "*.webp" \) 2>/dev/null | sort)

STALE_COUNT=$(echo "$ENTRIES" | jq '[.[] | select(.stale == true)] | length')
TOTAL_COUNT=$(echo "$ENTRIES" | jq 'length')

jq -n --argjson images "$ENTRIES" --argjson total "$TOTAL_COUNT" --argjson stale "$STALE_COUNT" \
    '{images:$images, total:$total, stale:$stale}'
