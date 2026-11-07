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

# church-calendar's image schedule is the source of truth for start/end dates; read-only
# because this runs as the web user. Older calendars without it fall back to filename dates.
SCHEDULER="$(dirname "$IMAGES_DIR")/image_schedule.py"
SCHEDULE_JSON='{"images":[]}'
if [ -f "$SCHEDULER" ]; then
    SCHEDULE_JSON=$(python3 "$SCHEDULER" --images-dir "$IMAGES_DIR" list --read-only 2>/dev/null) || SCHEDULE_JSON='{"images":[]}'
    [ -n "$SCHEDULE_JSON" ] || SCHEDULE_JSON='{"images":[]}'
fi

# Entries are appended as compact JSON lines to a temp file and combined
# with `jq -s` at the end, rather than round-tripped through jq --argjson
# on every iteration. Preview data is passed to jq via --rawfile (reads the
# file directly) instead of as a base64 string on the command line — large
# base64 blobs (now up to ~800x600 WebP previews, not just 50x50 thumbnails)
# blow past the kernel's ARG_MAX and fail with "jq: Argument list too long"
# if passed as an argument/--arg.
ENTRIES_FILE=$(mktemp)
THUMB_B64_FILE=$(mktemp)
trap 'rm -f "$ENTRIES_FILE" "$THUMB_B64_FILE"' EXIT

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
    STATE=""
    SHOW_FROM=""
    AUTO_ARCHIVE="false"
    ROW=$(echo "$SCHEDULE_JSON" | jq -c --arg f "$BASENAME" '[.images[] | select(.filename == $f)][0] // empty' 2>/dev/null || echo "")
    if [ -n "$ROW" ]; then
        STATE=$(echo "$ROW" | jq -r '.state')
        FILE_DATE=$(echo "$ROW" | jq -r '.remove_after // ""')
        SHOW_FROM=$(echo "$ROW" | jq -r '.show_from // ""')
        AUTO_ARCHIVE=$(echo "$ROW" | jq -r '.auto_archive')
        STALE="false"
        [ "$STATE" = "expired" ] && STALE="true"
    fi

    # Prefer the larger 'optimized' WebP (up to 800x600 @ quality 85, already
    # generated for the calendar's own slideshow) over the tiny 50x50 thumbnail
    # so previews in the dashboard aren't blurry.
    PREVIEW_FILE="$OPTIMIZED_DIR/${BASENAME}.webp"
    [ -f "$PREVIEW_FILE" ] || PREVIEW_FILE="$THUMB_DIR/${BASENAME}.webp"

    HAS_THUMB="false"
    : > "$THUMB_B64_FILE"
    if [ -f "$PREVIEW_FILE" ]; then
        base64 -w0 "$PREVIEW_FILE" 2>/dev/null | tr -d '\n' > "$THUMB_B64_FILE"
        [ -s "$THUMB_B64_FILE" ] && HAS_THUMB="true"
    fi

    jq -n \
        --arg filename "$BASENAME" \
        --argjson size "$SIZE" \
        --arg mtime "$MTIME" \
        --arg event_date "$FILE_DATE" \
        --arg state "$STATE" \
        --arg show_from "$SHOW_FROM" \
        --argjson auto_archive "$AUTO_ARCHIVE" \
        --argjson stale "$STALE" \
        --argjson has_thumb "$HAS_THUMB" \
        --rawfile thumb_b64 "$THUMB_B64_FILE" \
        '{filename:$filename, size:$size, mtime:$mtime,
          event_date: (if $event_date == "" then null else $event_date end),
          show_from: (if $show_from == "" then null else $show_from end),
          remove_after: (if $event_date == "" then null else $event_date end),
          auto_archive: $auto_archive,
          state: (if $state == "" then null else $state end),
          stale:$stale,
          thumbnail: (if $has_thumb then ("data:image/webp;base64," + $thumb_b64) else null end)}' \
        >> "$ENTRIES_FILE"
done < <(find "$IMAGES_DIR" -maxdepth 1 -type f \( -iname "*.jpg" -o -iname "*.jpeg" -o -iname "*.png" -o -iname "*.gif" -o -iname "*.webp" \) 2>/dev/null | sort)

# --slurpfile reads the NDJSON file directly (no argv/ARG_MAX involved),
# unlike --argjson which would pass the whole (potentially multi-MB) blob
# as a single command-line argument.
jq -n --slurpfile images "$ENTRIES_FILE" \
    '{images: $images, total: ($images | length), stale: ($images | map(select(.stale == true)) | length)}'
